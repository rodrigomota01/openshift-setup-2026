# Documentacao de Upgrade OpenShift Container Platform - 4.16 para 4.20

**Cluster:** ocp.177.54.151.49.sslip.io  
**Data de execucao:** 20 de abril de 2026  
**Responsavel:** Rodrigo Mota  
**Versao inicial:** 4.16.51  
**Versao final:** 4.20.19  
**Caminho de upgrade:** 4.16.51 -> 4.17.52 -> 4.18.37 -> 4.19.28 -> 4.20.19

---

## 1. Estado Inicial do Cluster

| Recurso | Detalhes |
|---------|---------|
| Versao | 4.18.37 (ja havia sido atualizado de 4.16.51 para 4.17.52 e depois para 4.18.37) |
| Canal | stable-4.18 |
| Nodes | 7 (3 masters, 2 workers, 2 infra) |
| Kubernetes | v1.31.14 |
| Cluster Operators | Todos Available=True, Progressing=False, Degraded=False |

### Topologia dos Nodes

| Node | Role | Versao Inicial |
|------|------|---------------|
| master-0 | control-plane, master, worker | v1.31.14 |
| master-1 | control-plane, master, worker | v1.31.14 |
| master-2 | control-plane, master, worker | v1.31.14 |
| worker-0 | worker | v1.31.14 |
| worker-1 | worker | v1.31.14 |
| infra-0 | infra | v1.31.14 |
| infra-1 | infra | v1.31.14 |

---

## 2. Pre-requisitos e Bloqueadores Identificados (4.18 -> 4.19)

Ao verificar o status de upgrade com `oc adm upgrade`, tres bloqueadores foram identificados:

### 2.1 AdminAckRequired - Remocao de APIs Kubernetes 1.32

**Problema:** OpenShift 4.19 utiliza Kubernetes 1.32 que remove APIs que requerem reconhecimento do administrador.

**Solucao:**
```bash
oc -n openshift-config patch cm admin-acks \
  --patch '{"data":{"ack-4.18-kube-1.32-api-removals-in-4.19":"true"}}' \
  --type=merge
```

### 2.2 DNS Operator com managementState Unmanaged

**Problema:** O operador DNS estava com `managementState: Unmanaged`, impedindo o upgrade entre versoes minor.

**Motivo:** O cluster utilizava configuracao customizada do CoreDNS para tratar o problema de wildcard DNS do sslip.io. O CoreDNS tinha regras de template para retornar NXDOMAIN para queries sob o dominio `ocp.177.54.151.49.sslip.io`, evitando que o search domain do resolv.conf dos pods causasse resolucao incorreta via sslip.io.

**Solucao:**
```bash
oc patch dns.operator/default --type=merge \
  -p '{"spec":{"managementState":"Managed"}}'
```

**Impacto colateral:** Ao mudar para `Managed`, o DNS operator sobrescreveu a configuracao customizada do CoreDNS, removendo as regras de NXDOMAIN para o sslip.io. Isso causou problemas de resolucao DNS posteriormente (detalhado na secao de problemas).

### 2.3 Loki Operator Incompativel

**Problema:** O `loki-operator.v6.1.9` tinha `maxOCPVersion: 4.18`, bloqueando o upgrade para 4.19.

**Solucao:**
```bash
# Verificar canais disponiveis
oc get packagemanifest loki-operator -n openshift-marketplace \
  -o jsonpath='{.status.channels[*].name}'
# Resultado: stable-6.1 stable-6.2 stable-6.3 stable-6.4

# Atualizar para canal compativel
oc patch subscription loki-operator -n openshift-operators-redhat \
  --type=merge -p '{"spec":{"channel":"stable-6.2"}}'

# Verificar atualizacao
oc get csv -n openshift-operators-redhat | grep loki
# loki-operator.v6.2.9  Succeeded
```

---

## 3. Upgrade 4.18.37 -> 4.19.28

### 3.1 Mudanca de Canal e Inicio do Upgrade

O canal `stable-4.19` nao estava disponivel, sendo necessario usar `fast-4.19`:

```bash
# stable-4.19 nao estava nos canais disponiveis
oc adm upgrade channel fast-4.19
oc adm upgrade --to-latest=true
# Requested update to 4.19.28
```

### 3.2 Problema: Falha no Drain dos Nodes (PDB do Loki)

**Sintoma:** O MachineConfig operator ficou travado por mais de 1 hora tentando drenar os nodes `infra-0` e `worker-1`. Os MachineConfigPools `infra` e `worker` ficaram com `DEGRADED=True`.

**Causa raiz:** Os PodDisruptionBudgets (PDB) do Loki estavam com `ALLOWED DISRUPTIONS: 0`, impedindo a evicao dos pods durante o drain. Os seguintes pods bloquearam o drain:

- `infra-0`: `logging-loki-querier`, `logging-loki-ruler-0`
- `worker-1`: `logging-loki-distributor`

PDBs envolvidos:
- `logging-loki-querier` (minAvailable: 1, allowedDisruptions: 0)
- `logging-loki-ruler` (minAvailable: 1, allowedDisruptions: 0)
- `logging-loki-distributor` (minAvailable: 1, allowedDisruptions: 0)
- `logging-loki-ingester` (minAvailable: 1, allowedDisruptions: 0)

**Tentativa 1 - Patch dos PDBs:**
```bash
oc patch pdb logging-loki-querier -n openshift-logging \
  --type=merge -p '{"spec":{"minAvailable":0}}'
# Repetido para ruler, distributor, ingester
```
Resultado: O operador Loki restaurou os PDBs automaticamente.

**Solucao definitiva:**
```bash
# Deletar os PDBs
oc delete pdb logging-loki-querier logging-loki-ruler \
  logging-loki-distributor logging-loki-ingester \
  logging-loki-index-gateway -n openshift-logging

# Pausar o operador Loki para nao recriar os PDBs
oc scale deployment loki-operator-controller-manager \
  -n openshift-operators-redhat --replicas=0

# Forcar drain com --disable-eviction (ignora PDBs completamente)
oc adm drain infra-0 --ignore-daemonsets --delete-emptydir-data \
  --force --disable-eviction

oc adm drain worker-1 --ignore-daemonsets --delete-emptydir-data \
  --force --disable-eviction
```

**Resultado:** O drain completou, os nodes reiniciaram com o novo RHCOS e voltaram ao estado `Ready`.

### 3.3 Pos-Upgrade 4.19

Apos a conclusao do upgrade para 4.19.28, o operador Loki foi restaurado:
```bash
oc scale deployment loki-operator-controller-manager \
  -n openshift-operators-redhat --replicas=1
```

---

## 4. Upgrade 4.19.28 -> 4.20.19

### 4.1 AdminAck para APIs v1beta1

**Problema inicial:** A chave de ack utilizada estava incorreta.

```bash
# Chave INCORRETA (usada inicialmente):
ack-4.19-admissionregistration-v1beta1-removal-in-4.20

# Chave CORRETA (verificada no admin-gates):
ack-4.19-admissionregistration-v1beta1-api-removals-in-4.20
```

**Verificacao da chave correta:**
```bash
oc get cm admin-gates -n openshift-config-managed -o yaml
```

**Solucao:**
```bash
oc -n openshift-config patch cm admin-acks --type=merge \
  -p '{"data":{"ack-4.19-admissionregistration-v1beta1-api-removals-in-4.20":"true"}}'
```

**Licao aprendida:** Sempre verificar o configmap `admin-gates` em `openshift-config-managed` para obter a chave exata de ack necessaria.

### 4.2 Mudanca de Canal e Inicio do Upgrade

```bash
oc adm upgrade channel candidate-4.20
oc adm upgrade --to-latest=true
# Requested update to 4.20.19
```

### 4.3 Problema: Falha no Drain Novamente (PDBs do Loki)

O mesmo problema de PDB do Loki ocorreu durante o upgrade para 4.20, requerendo a mesma solucao:

```bash
oc delete pdb logging-loki-querier logging-loki-ruler \
  logging-loki-distributor logging-loki-ingester \
  logging-loki-index-gateway -n openshift-logging

oc scale deployment loki-operator-controller-manager \
  -n openshift-operators-redhat --replicas=0

oc adm drain infra-0 --ignore-daemonsets --delete-emptydir-data \
  --force --disable-eviction

oc adm drain worker-1 --ignore-daemonsets --delete-emptydir-data \
  --force --disable-eviction
```

### 4.4 Problema: Node infra-0 Travado em SchedulingDisabled

**Sintoma:** Apos o drain e reboot, `infra-0` ficou com status `Ready,SchedulingDisabled` mesmo ja estando na versao `v1.33.9`.

**Solucao:**
```bash
oc adm uncordon infra-0
```

### 4.5 Problema: LVMS Operator com Canal Desatualizado

**Sintoma:** Alerta no cluster: `no operators found in channel stable-4.18 of package lvms-operator`

**Solucao:**
```bash
oc patch subscription lvms-operator -n openshift-storage \
  --type=merge -p '{"spec":{"channel":"stable-4.20"}}'
```

### 4.6 Problema: Thin Pool LVM Cheio (100%)

**Sintoma:** O pod `logging-loki-ingester-0` nao conseguia montar volume no node `infra-1`:
```
MountVolume.SetUp failed: mount(2) system call failed: No space left on device
```

**Diagnostico:**
```bash
oc debug node/infra-1 -- chroot /host lvs
# thin-pool-1  vg1  twi-aotzD-  <44.95g  100.00  44.69
# Flag "D" = Degraded/Suspended
```

O thin pool estava 100% cheio. O VG tinha 50GB com um thin pool de ~45GB. Os volumes thin provisionados somavam 325GB (10+10+150+5+150 GB), e o WAL do ingester-0 (150GB com 29.78% de uso = ~44.7GB) sozinho preencheu o pool.

**Solucao imediata:**
```bash
# Adicionar 20GB ao disco sda de cada servidor infra (feito no hipervisor)
# Depois, expandir o PV e thin pool:
pvresize /dev/sda
lvextend -l +100%FREE vg1/thin-pool-1
lvchange --refresh vg1/thin-pool-1
```

**Licao aprendida:** Ao usar thin provisioning com LVMS/TopoLVM, monitorar o uso real do thin pool. Volumes WAL do Loki de 150Gi em um pool de 45GB sao desproporcionais.

### 4.7 Problema: CSI Driver TopoLVM Nao Registrado

**Sintoma:** Apos o reboot de `infra-0`, volumes nao conseguiam montar:
```
driver name topolvm.io not found in the list of registered CSI drivers
```

**Causa:** O LVMS operator estava no canal `stable-4.18` (sem pacotes disponiveis apos o upgrade).

**Solucao:** Resolvido com a atualizacao do LVMS operator para `stable-4.20` (item 4.5).

---

## 5. Problema Critico: Resolucao DNS Incorreta com sslip.io

### 5.1 Descricao do Problema

Apos concluir o upgrade dos nodes, todos os pods Loki falharam com dois tipos de erro:

**Erro 1 - S3 TLS:**
```
tls: failed to verify certificate: x509: certificate is valid for
*.apps.ocp.177.54.151.49.sslip.io, not atn-bucket-teste.s3.us-east-1.amazonaws.com
```

**Erro 2 - Memberlist/Gossip Ring:**
```
Failed to join 177.54.151.49:7946: dial tcp 177.54.151.49:7946: connection refused
```

### 5.2 Diagnostico

O `/etc/resolv.conf` dos pods continha:
```
search openshift-logging.svc.cluster.local svc.cluster.local cluster.local ocp.177.54.151.49.sslip.io
nameserver 172.30.0.10
options ndots:5
```

Com `ndots:5`, hostnames com menos de 5 dots sao resolvidos primeiro com search domains. Como `sslip.io` e um servico de wildcard DNS (qualquer subdomain contendo um IP resolve para esse IP), os seguintes nomes eram resolvidos incorretamente:

- `logging-loki-gossip-ring.openshift-logging.svc.cluster.local` (4 dots < ndots:5)
  - Tentava: `...svc.cluster.local.ocp.177.54.151.49.sslip.io` -> resolvia para `177.54.151.49`
  
- `atn-bucket-teste.s3.us-east-1.amazonaws.com` (4 dots < ndots:5)
  - Tentava: `...amazonaws.com.ocp.177.54.151.49.sslip.io` -> resolvia para `177.54.151.49`

### 5.3 Causa Raiz

A configuracao original do CoreDNS tinha regras de template para retornar `NXDOMAIN` para queries sob `ocp.177.54.151.49.sslip.io`, prevenindo o wildcard do sslip.io:

```
ocp.177.54.151.49.sslip.io:5353 {
    template IN ANY ocp.177.54.151.49.sslip.io {
        rcode NXDOMAIN
    }
}
```

Essas regras foram **perdidas** quando o DNS operator foi mudado para `Managed` (necessario para o upgrade). O operator sobrescreveu o configmap do CoreDNS com a configuracao padrao.

### 5.4 Solucao

```bash
# 1. Mudar DNS de volta para Unmanaged
oc patch dns.operator/default --type=merge \
  -p '{"spec":{"managementState":"Unmanaged"}}'

# 2. Aplicar configmap do CoreDNS com regras de NXDOMAIN para sslip.io
oc apply -f /tmp/coredns-fix.yaml
```

Conteudo do `coredns-fix.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dns-default
  namespace: openshift-dns
data:
  Corefile: |
    .:5353 {
        bufsize 1232
        errors
        log . {
            class error
        }
        health {
            lameduck 20s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
        }
        prometheus 127.0.0.1:9153
        forward . /etc/resolv.conf {
            policy sequential
        }
        cache 900 {
            denial 9984 30
        }
        reload
    }
    hostname.bind:5353 {
        chaos
    }
    ocp.177.54.151.49.sslip.io:5353 {
        template IN ANY ocp.177.54.151.49.sslip.io {
            rcode NXDOMAIN
        }
    }
    apps.ocp.177.54.151.49.sslip.io:5353 {
        forward . /etc/resolv.conf
    }
    api.ocp.177.54.151.49.sslip.io:5353 {
        forward . /etc/resolv.conf
    }
    api-int.ocp.177.54.151.49.sslip.io:5353 {
        forward . /etc/resolv.conf
    }
```

```bash
# 3. Reiniciar pods Loki para usar nova resolucao DNS
oc delete pods -n openshift-logging -l app.kubernetes.io/name=lokistack
```

**Resultado:** Apos a correcao do DNS, os pods Loki conseguiram resolver corretamente os servicos internos e o endpoint S3 da AWS.

---

## 6. Atualizacao dos Operadores Pos-Upgrade

### 6.1 Loki Operator

```bash
# De stable-6.2 para stable-6.3 (compativel com 4.21+)
oc patch subscription loki-operator -n openshift-operators-redhat \
  --type=merge -p '{"spec":{"channel":"stable-6.3"}}'
```

### 6.2 Cluster Logging Operator

```bash
# De stable-6.3 (v6.3.4) para stable-6.4 (compativel com 4.21+)
oc patch subscription cluster-logging -n openshift-logging \
  --type=merge -p '{"spec":{"channel":"stable-6.4"}}'
```

### 6.3 LVMS Operator

```bash
# De stable-4.18 para stable-4.20
oc patch subscription lvms-operator -n openshift-storage \
  --type=merge -p '{"spec":{"channel":"stable-4.20"}}'
```

### 6.4 Canal do ClusterVersion

```bash
oc adm upgrade channel stable-4.20 --allow-explicit-channel
```

---

## 7. Estado Final do Cluster

### ClusterVersion

| Campo | Valor |
|-------|-------|
| Versao | 4.20.19 |
| Canal | stable-4.20 |
| Available | True |
| Progressing | False |
| Failing | False |

### Nodes

| Node | Status | Versao |
|------|--------|--------|
| master-0 | Ready | v1.33.9 |
| master-1 | Ready | v1.33.9 |
| master-2 | Ready | v1.33.9 |
| worker-0 | Ready | v1.33.9 |
| worker-1 | Ready | v1.33.9 |
| infra-0 | Ready | v1.33.9 |
| infra-1 | Ready | v1.33.9 |

### MachineConfigPools

| Pool | Updated | Degraded |
|------|---------|----------|
| master | True | False |
| worker | True | False |
| infra | True | False |

### Cluster Operators

Todos os 35 Cluster Operators em versao 4.20.19 com `Available=True`, `Progressing=False`, `Degraded=False`.

---

## 8. Pendencias e Observacoes

### 8.1 DNS Operator em Unmanaged

O DNS operator esta em `managementState: Unmanaged` para preservar a configuracao customizada do CoreDNS (regras NXDOMAIN para sslip.io). **Antes do proximo upgrade minor, sera necessario:**

1. Mudar para `Managed`: `oc patch dns.operator/default --type=merge -p '{"spec":{"managementState":"Managed"}}'`
2. Realizar o upgrade
3. Reapliar a configuracao customizada do CoreDNS
4. Mudar de volta para `Unmanaged`

**Solucao permanente sugerida:** Migrar o cluster para um dominio real (nao sslip.io) para eliminar o problema de wildcard DNS.

### 8.2 Thin Provisioning do LVMS

O thin pool do LVM nos nodes infra foi expandido de 50GB para 70GB. O provisionamento total de volumes (325GB) excede significativamente o espaco fisico. Recomendacoes:

- Monitorar o uso do thin pool regularmente
- Considerar reduzir o tamanho dos volumes WAL do Loki (150Gi e desproporcional)
- Configurar alertas para uso do thin pool acima de 80%

### 8.3 Logging Stack

- O `index-gateway-1` do Loki pode ficar em `Pending` por falta de CPU/memoria nos nodes
- O ingester precisa de pelo menos 2 CPU e 8Gi de memoria
- O S3 bucket `atn-bucket-teste` deve funcionar corretamente com a correcao do DNS

### 8.4 ConsolePlugins

Tres ConsolePlugins estavam com status "Failed to get a valid plugin manifest" apos o upgrade:
- `monitoring-plugin`
- `networking-console-plugin`
- `logging-view-plugin`

Solucao: Reiniciar os pods do console e atualizar os operadores de logging para versoes compativeis com 4.20.

---

## 9. Resumo de Comandos Criticos Utilizados

### Verificacao de Status

```bash
oc get clusterversion
oc get co
oc get nodes
oc get mcp
oc adm upgrade
oc describe clusterversion version
```

### Admin Acks

```bash
# Verificar chaves necessarias
oc get cm admin-gates -n openshift-config-managed -o yaml

# Aplicar acks
oc -n openshift-config patch cm admin-acks --type=merge \
  -p '{"data":{"CHAVE":"true"}}'
```

### Drain Forcado (quando PDBs bloqueiam)

```bash
oc adm drain <NODE> --ignore-daemonsets --delete-emptydir-data \
  --force --disable-eviction
```

### Uncordon Manual

```bash
oc adm uncordon <NODE>
```

### Atualizacao de Operadores

```bash
# Ver canais disponiveis
oc get packagemanifest <OPERATOR> -n openshift-marketplace \
  -o jsonpath='{.status.channels[*].name}'

# Mudar canal
oc patch subscription <OPERATOR> -n <NAMESPACE> \
  --type=merge -p '{"spec":{"channel":"<CANAL>"}}'
```

### Diagnostico de LVM

```bash
oc debug node/<NODE> -- chroot /host vgs
oc debug node/<NODE> -- chroot /host lvs
```

---

## 10. Licoes Aprendidas

1. **Sempre verificar o configmap `admin-gates`** para obter a chave exata de ack. A chave incorreta bloqueia silenciosamente o upgrade.

2. **Clusters com sslip.io requerem atencao especial ao DNS.** O wildcard do sslip.io combinado com `ndots:5` causa resolucao incorreta de hostnames. Manter regras NXDOMAIN no CoreDNS e essencial.

3. **PDBs do Loki bloqueiam drains durante upgrades.** Em ambientes com recursos limitados e apenas 1 replica de cada componente Loki, os PDBs impedem o drain. Solucao: escalar o operador Loki para zero, deletar os PDBs e forcar o drain com `--disable-eviction`.

4. **Monitorar thin pools do LVM.** O thin provisioning permite alocar mais espaco virtual que fisico, mas se o uso real exceder o pool fisico, o pool fica suspenso (flag D) e os volumes ficam inacessiveis.

5. **Atualizar operadores de marketplace ANTES do upgrade** do cluster, garantindo que sejam compativeis com a versao alvo. Operadores desatualizados bloqueiam o upgrade e podem causar problemas no OLM.

6. **O upgrade entre versoes minor deve ser sequencial.** Nao e possivel pular versoes (4.18 -> 4.20 direto). O caminho obrigatorio e: 4.18 -> 4.19 -> 4.20.

7. **Canais `stable` podem nao estar disponiveis** para upgrades cross-version. Os canais `fast` ou `candidate` podem ser necessarios quando o `stable` nao contem o caminho de upgrade a partir da versao atual.
