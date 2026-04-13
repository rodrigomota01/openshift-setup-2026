# Guia de Instalação — OpenShift Container Platform (Do Zero)

**Topologia:** 3 masters · 2 workers · 2 infra  
**Método:** UPI (User Provisioned Infrastructure)  
**Objetivo:** Aprendizado — instalação completa e configuração pós-instalação  
**Data de criação:** 2026-04-13  

---

## Sumário

1. [Visão Geral da Arquitetura](#1-visão-geral-da-arquitetura)
2. [Requisitos de Infraestrutura](#2-requisitos-de-infraestrutura)
3. [Pré-Requisitos de Rede](#3-pré-requisitos-de-rede)
4. [Preparação do Bastion Host](#4-preparação-do-bastion-host)
5. [Configuração de DNS](#5-configuração-de-dns)
6. [Configuração do Load Balancer (HAProxy)](#6-configuração-do-load-balancer-haproxy)
7. [Geração dos Manifestos de Instalação](#7-geração-dos-manifestos-de-instalação)
8. [Bootstrap e Instalação do Cluster](#8-bootstrap-e-instalação-do-cluster)
9. [Configuração dos Nodes Infra](#9-configuração-dos-nodes-infra)
10. [Migração de Workloads de Infra](#10-migração-de-workloads-de-infra)
11. [Validação Final do Cluster](#11-validação-final-do-cluster)
12. [Comandos de Referência Rápida](#12-comandos-de-referência-rápida)

---

## 1. Visão Geral da Arquitetura

### 1.1 Topologia de Nodes

| Role    | Qtd | Hostname exemplo         | Função                                  |
|---------|-----|--------------------------|-----------------------------------------|
| master  | 3   | master-0/1/2             | etcd + API Server + Control Plane       |
| worker  | 2   | worker-0/1               | Workloads de aplicação                  |
| infra   | 2   | infra-0/1                | Router (Ingress) + Registry + Monitoring|
| bastion | 1   | bastion                  | Instalação, acesso SSH, oc CLI          |

> Os nodes **infra** são tecnicamente workers com um `MachineConfigPool` e `taint` dedicados.  
> Eles existem para isolar componentes da plataforma (Ingress, Registry, Monitoring) dos workloads de aplicação.

### 1.2 Diagrama de Rede (simplificado)

```
Internet / Rede Corporativa
         |
    [ Load Balancer ]
     /            \
  :6443          :443 / :80
(API)          (Ingress/Apps)
   |                  |
[masters x3]    [infra x2]
                      |
               [workers x2]
```

### 1.3 Portas necessárias

| Porta     | Protocolo | Origem        | Destino    | Função                  |
|-----------|-----------|---------------|------------|-------------------------|
| 6443      | TCP       | Externos/LB   | Masters    | Kubernetes API          |
| 22623     | TCP       | Bastion/LB    | Masters    | Machine Config Server   |
| 443/80    | TCP       | Externos/LB   | Infra      | Ingress Controller      |
| 2379-2380 | TCP       | Masters       | Masters    | etcd (cluster interno)  |
| 9000-9999 | TCP/UDP   | Todos nodes   | Todos      | Host services           |
| 10250     | TCP       | Masters       | Workers    | Kubelet                 |
| 4789/8472 | UDP       | Todos nodes   | Todos      | OVN-Kubernetes (SDN)    |

---

## 2. Requisitos de Infraestrutura

### 2.1 Especificações mínimas de recursos

| Node    | vCPU | RAM   | Disco OS | Disco extra |
|---------|------|-------|----------|-------------|
| bastion | 2    | 4 GB  | 50 GB    | —           |
| master  | 4    | 16 GB | 120 GB   | —           |
| worker  | 2    | 8 GB  | 120 GB   | —           |
| infra   | 4    | 16 GB | 120 GB   | —           |

> Para ambiente de laboratório, masters podem usar 4 vCPU / 8 GB, mas não é recomendado em produção.

### 2.2 Sistema Operacional

- **Bastion:** RHEL 8 ou 9 (ou CentOS Stream 9)
- **Todos os outros nodes:** RHCOS (Red Hat CoreOS) — provisionado automaticamente pelo instalador

### 2.3 Planejamento de IPs

Preencha antes de iniciar:

| Node       | IP            | Hostname FQDN                        |
|------------|---------------|--------------------------------------|
| bastion    | 192.168.1.10  | bastion.ocp.example.com              |
| bootstrap  | 192.168.1.20  | bootstrap.ocp.example.com            |
| master-0   | 192.168.1.21  | master-0.ocp.example.com             |
| master-1   | 192.168.1.22  | master-1.ocp.example.com             |
| master-2   | 192.168.1.23  | master-2.ocp.example.com             |
| worker-0   | 192.168.1.31  | worker-0.ocp.example.com             |
| worker-1   | 192.168.1.32  | worker-1.ocp.example.com             |
| infra-0    | 192.168.1.41  | infra-0.ocp.example.com              |
| infra-1    | 192.168.1.42  | infra-1.ocp.example.com              |
| LB API     | 192.168.1.100 | api.ocp.example.com                  |
| LB Ingress | 192.168.1.101 | *.apps.ocp.example.com               |

> Substitua `ocp.example.com` pelo seu domínio de cluster.  
> `cluster_name` = `ocp` | `base_domain` = `example.com`

---

## 3. Pré-Requisitos de Rede

### 3.1 Entradas DNS obrigatórias

O DNS é o requisito mais crítico. Sem ele correto, a instalação falha.

**Registros A (forward)**

```
api.ocp.example.com.          IN A  192.168.1.100   # VIP do LB — API
api-int.ocp.example.com.      IN A  192.168.1.100   # Interno (mesmo IP do api)
*.apps.ocp.example.com.       IN A  192.168.1.101   # Wildcard — Ingress

bootstrap.ocp.example.com.    IN A  192.168.1.20
master-0.ocp.example.com.     IN A  192.168.1.21
master-1.ocp.example.com.     IN A  192.168.1.22
master-2.ocp.example.com.     IN A  192.168.1.23
worker-0.ocp.example.com.     IN A  192.168.1.31
worker-1.ocp.example.com.     IN A  192.168.1.32
infra-0.ocp.example.com.      IN A  192.168.1.41
infra-1.ocp.example.com.      IN A  192.168.1.42
```

**Registros PTR (reverse)**

```
20.1.168.192.in-addr.arpa.   IN PTR bootstrap.ocp.example.com.
21.1.168.192.in-addr.arpa.   IN PTR master-0.ocp.example.com.
22.1.168.192.in-addr.arpa.   IN PTR master-1.ocp.example.com.
23.1.168.192.in-addr.arpa.   IN PTR master-2.ocp.example.com.
31.1.168.192.in-addr.arpa.   IN PTR worker-0.ocp.example.com.
32.1.168.192.in-addr.arpa.   IN PTR worker-1.ocp.example.com.
41.1.168.192.in-addr.arpa.   IN PTR infra-0.ocp.example.com.
42.1.168.192.in-addr.arpa.   IN PTR infra-1.ocp.example.com.
```

### 3.2 Validação do DNS (rodar do bastion)

```bash
# Testar resolução forward
dig api.ocp.example.com +short
dig api-int.ocp.example.com +short
dig test.apps.ocp.example.com +short

# Testar resolução reversa
dig -x 192.168.1.21 +short   # deve retornar master-0.ocp.example.com

# Testar todos os masters
for i in 21 22 23; do dig -x 192.168.1.$i +short; done
```

---

## 4. Preparação do Bastion Host

### 4.1 Instalação de ferramentas

```bash
# Baixar o OpenShift installer e oc CLI
# Obtenha o link em: https://console.redhat.com/openshift/install
# Selecione: Bare Metal > User-provisioned infrastructure

OCP_VERSION="4.16.x"   # substitua pela versão desejada

tar -xvf openshift-install-linux.tar.gz
tar -xvf openshift-client-linux.tar.gz

sudo mv oc kubectl openshift-install /usr/local/bin/
sudo chmod +x /usr/local/bin/{oc,kubectl,openshift-install}

# Verificar
oc version --client
openshift-install version
```

### 4.2 Criar diretório de instalação

```bash
mkdir ~/ocp-install
cd ~/ocp-install
```

### 4.3 Obter o Pull Secret

1. Acesse: https://console.redhat.com/openshift/install
2. Baixe seu **pull secret** (arquivo JSON)
3. Salve em `~/ocp-install/pull-secret.txt`

### 4.4 Gerar par de chaves SSH

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/ocp_id_ed25519
cat ~/.ssh/ocp_id_ed25519.pub   # copie para usar no install-config.yaml
```

---

## 5. Configuração de DNS

Se estiver usando o **bind/named** no bastion para laboratório:

```bash
sudo dnf install -y bind bind-utils

# Editar /etc/named.conf — adicionar zona
# Criar /var/named/ocp.example.com.zone (forward)
# Criar /var/named/1.168.192.in-addr.arpa.zone (reverse)

sudo systemctl enable --now named
sudo firewall-cmd --add-service=dns --permanent
sudo firewall-cmd --reload
```

**Exemplo de zona forward** (`/var/named/ocp.example.com.zone`):

```zone
$TTL 300
@   IN SOA  bastion.ocp.example.com. admin.example.com. (
        2026041301 ; Serial
        3600       ; Refresh
        900        ; Retry
        604800     ; Expire
        300 )      ; Minimum TTL
    IN NS   bastion.ocp.example.com.

bastion         IN A    192.168.1.10
bootstrap       IN A    192.168.1.20
master-0        IN A    192.168.1.21
master-1        IN A    192.168.1.22
master-2        IN A    192.168.1.23
worker-0        IN A    192.168.1.31
worker-1        IN A    192.168.1.32
infra-0         IN A    192.168.1.41
infra-1         IN A    192.168.1.42

api             IN A    192.168.1.100
api-int         IN A    192.168.1.100
*.apps          IN A    192.168.1.101
```

---

## 6. Configuração do Load Balancer (HAProxy)

```bash
sudo dnf install -y haproxy
```

**`/etc/haproxy/haproxy.cfg`:**

```haproxy
global
    log         127.0.0.1 local2
    maxconn     4096

defaults
    log         global
    mode        tcp
    option      tcplog
    timeout connect 10s
    timeout client  1m
    timeout server  1m

#---------------------------------------------------------------------
# API — porta 6443 (externa + interna)
#---------------------------------------------------------------------
frontend api_frontend
    bind *:6443
    default_backend api_backend

backend api_backend
    balance roundrobin
    option tcp-check
    server bootstrap  192.168.1.20:6443  check
    server master-0   192.168.1.21:6443  check
    server master-1   192.168.1.22:6443  check
    server master-2   192.168.1.23:6443  check

#---------------------------------------------------------------------
# Machine Config Server — porta 22623 (bootstrap + masters)
#---------------------------------------------------------------------
frontend mcs_frontend
    bind *:22623
    default_backend mcs_backend

backend mcs_backend
    balance roundrobin
    option tcp-check
    server bootstrap  192.168.1.20:22623 check
    server master-0   192.168.1.21:22623 check
    server master-1   192.168.1.22:22623 check
    server master-2   192.168.1.23:22623 check

#---------------------------------------------------------------------
# Ingress HTTP — porta 80 (infra nodes)
#---------------------------------------------------------------------
frontend ingress_http_frontend
    bind *:80
    default_backend ingress_http_backend

backend ingress_http_backend
    balance roundrobin
    option tcp-check
    server infra-0  192.168.1.41:80  check
    server infra-1  192.168.1.42:80  check

#---------------------------------------------------------------------
# Ingress HTTPS — porta 443 (infra nodes)
#---------------------------------------------------------------------
frontend ingress_https_frontend
    bind *:443
    default_backend ingress_https_backend

backend ingress_https_backend
    balance roundrobin
    option tcp-check
    server infra-0  192.168.1.41:443 check
    server infra-1  192.168.1.42:443 check
```

```bash
sudo systemctl enable --now haproxy
sudo firewall-cmd --add-port={6443,22623,80,443}/tcp --permanent
sudo firewall-cmd --reload

# Verificar
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

> **Nota:** O bootstrap é removido do backend `api_backend` e `mcs_backend` após a instalação ser concluída.

---

## 7. Geração dos Manifestos de Instalação

### 7.1 Criar o `install-config.yaml`

```bash
cd ~/ocp-install
```

**`install-config.yaml`:**

```yaml
apiVersion: v1
baseDomain: example.com                    # seu base domain
metadata:
  name: ocp                                # cluster name

compute:
  - architecture: amd64
    hyperthreading: Enabled
    name: worker
    replicas: 0                            # workers provisionados manualmente (UPI)

controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 3

networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 192.168.1.0/24               # sua rede de nodes
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16

platform:
  none: {}                                 # UPI = none

fips: false

pullSecret: |
  <COLE_SEU_PULL_SECRET_AQUI>

sshKey: |
  <COLE_SUA_CHAVE_PUBLICA_SSH_AQUI>
```

### 7.2 Fazer backup do install-config (será consumido)

```bash
cp install-config.yaml install-config.yaml.bak
```

### 7.3 Gerar manifestos

```bash
openshift-install create manifests --dir ~/ocp-install/

# Remover manifestos de Machine que criariam workers automaticamente
rm -f ~/ocp-install/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
```

### 7.4 Gerar Ignition configs

```bash
openshift-install create ignition-configs --dir ~/ocp-install/

ls -la ~/ocp-install/
# Você verá: bootstrap.ign, master.ign, worker.ign, auth/
```

### 7.5 Hospedar os arquivos Ignition via HTTP

```bash
sudo dnf install -y httpd
sudo cp ~/ocp-install/*.ign /var/www/html/
sudo chmod 644 /var/www/html/*.ign
sudo systemctl enable --now httpd
sudo firewall-cmd --add-service=http --permanent
sudo firewall-cmd --reload

# Teste
curl http://192.168.1.10/bootstrap.ign | head -c 200
```

---

## 8. Bootstrap e Instalação do Cluster

### 8.1 Baixar a ISO do RHCOS

```bash
# Obtenha a URL da versão correta em:
# https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/

RHCOS_VERSION="4.16.x"   # alinhe com a versão do OCP
# Baixe a ISO e o raw image (para bare metal / VM)
```

### 8.2 Ordem de boot dos nodes

**Siga esta ordem rigorosamente:**

```
1. Bootstrap     → boot pela ISO RHCOS → aponta para bootstrap.ign
2. master-0      → boot pela ISO RHCOS → aponta para master.ign
3. master-1      → boot pela ISO RHCOS → aponta para master.ign
4. master-2      → boot pela ISO RHCOS → aponta para master.ign
```

> Workers e infra são iniciados **depois** que o control plane estiver operacional.

### 8.3 Instalação via parâmetro de boot (RHCOS ISO)

No boot loader (GRUB) do RHCOS, adicione os parâmetros:

**Para Bootstrap:**
```
coreos.inst.install_dev=/dev/sda
coreos.inst.ignition_url=http://192.168.1.10/bootstrap.ign
ip=192.168.1.20::192.168.1.1:255.255.255.0:bootstrap.ocp.example.com:ens3:none
nameserver=192.168.1.10
```

**Para Masters (ajuste o IP e hostname):**
```
coreos.inst.install_dev=/dev/sda
coreos.inst.ignition_url=http://192.168.1.10/master.ign
ip=192.168.1.21::192.168.1.1:255.255.255.0:master-0.ocp.example.com:ens3:none
nameserver=192.168.1.10
```

### 8.4 Monitorar o bootstrap

```bash
# Do bastion, acompanhe o progresso
openshift-install wait-for bootstrap-complete \
  --dir ~/ocp-install/ \
  --log-level=info

# Em caso de dúvida, acompanhe os logs do bootstrap diretamente:
ssh -i ~/.ssh/ocp_id_ed25519 core@192.168.1.20 \
  "journalctl -b -f -u release-image.service -u bootkube.service"
```

> O bootstrap leva entre 15-30 minutos. Quando concluir, você verá:
> `Bootstrap complete! The workers may now be deployed.`

### 8.5 Iniciar Workers e Infra nodes

Após o bootstrap completar, inicie os nodes worker e infra com o Ignition de worker:

**Para Workers:**
```
coreos.inst.ignition_url=http://192.168.1.10/worker.ign
ip=192.168.1.31::192.168.1.1:255.255.255.0:worker-0.ocp.example.com:ens3:none
```

**Para Infra (usam o mesmo ignition de worker inicialmente):**
```
coreos.inst.ignition_url=http://192.168.1.10/worker.ign
ip=192.168.1.41::192.168.1.1:255.255.255.0:infra-0.ocp.example.com:ens3:none
```

### 8.6 Aprovar os CSRs dos nodes

Após os nodes subirem, eles precisam ter seus CSRs aprovados:

```bash
export KUBECONFIG=~/ocp-install/auth/kubeconfig

# Verificar CSRs pendentes (rode 2x, pois há 2 rounds de CSRs)
oc get csr

# Aprovar todos os CSRs pendentes
oc get csr -o go-template='{{range .items}}{{if not .status.certificate}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
  | xargs oc adm certificate approve

# Verificar nodes
oc get nodes
```

### 8.7 Aguardar a instalação completar

```bash
openshift-install wait-for install-complete \
  --dir ~/ocp-install/ \
  --log-level=info
```

> Ao final, você receberá a URL do console e as credenciais do `kubeadmin`.

### 8.8 Remover o bootstrap do Load Balancer

Após `install-complete`, edite o HAProxy e **comente ou remova** o bootstrap:

```haproxy
backend api_backend
    # server bootstrap  192.168.1.20:6443  check   ← comentar/remover
    server master-0   192.168.1.21:6443  check
    ...

backend mcs_backend
    # server bootstrap  192.168.1.20:22623 check   ← comentar/remover
    ...
```

```bash
sudo systemctl reload haproxy
```

---

## 9. Configuração dos Nodes Infra

Os nodes **infra** são workers com label, taint e MachineConfigPool próprios. Isso garante que workloads de aplicação não sejam agendados neles.

### 9.1 Criar o MachineConfigPool `infra`

```yaml
# mcp-infra.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: infra
spec:
  machineConfigSelector:
    matchExpressions:
      - key: machineconfiguration.openshift.io/role
        operator: In
        values:
          - worker
          - infra
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/infra: ""
```

```bash
oc apply -f mcp-infra.yaml
```

### 9.2 Aplicar label `infra` nos nodes

```bash
oc label node infra-0.ocp.example.com node-role.kubernetes.io/infra=""
oc label node infra-1.ocp.example.com node-role.kubernetes.io/infra=""

# Remover label worker (opcional, mas recomendado)
oc label node infra-0.ocp.example.com node-role.kubernetes.io/worker-
oc label node infra-1.ocp.example.com node-role.kubernetes.io/worker-

# Verificar
oc get nodes
# infra-0 deve aparecer com ROLES: infra
```

### 9.3 Aplicar Taint nos nodes infra

O taint impede que pods sem toleração sejam agendados nos infra nodes:

```bash
oc adm taint nodes infra-0.ocp.example.com node-role.kubernetes.io/infra=:NoSchedule
oc adm taint nodes infra-1.ocp.example.com node-role.kubernetes.io/infra=:NoSchedule
```

---

## 10. Migração de Workloads de Infra

### 10.1 Mover o Ingress Controller (Router)

```bash
oc edit ingresscontroller default -n openshift-ingress-operator
```

Adicione/edite o campo `spec`:

```yaml
spec:
  replicas: 2
  nodePlacement:
    nodeSelector:
      matchLabels:
        node-role.kubernetes.io/infra: ""
    tolerations:
      - key: node-role.kubernetes.io/infra
        effect: NoSchedule
        operator: Exists
```

```bash
# Verificar se os pods do router foram para os infra nodes
oc get pods -n openshift-ingress -o wide
```

### 10.2 Mover o Image Registry

```bash
oc edit configs.imageregistry.operator.openshift.io cluster
```

Edite o campo `spec`:

```yaml
spec:
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
      operator: Exists
  storage:
    emptyDir: {}       # para lab; em produção use PVC ou S3/NFS
  managementState: Managed
```

```bash
# Verificar
oc get pods -n openshift-image-registry -o wide
```

### 10.3 Mover o Monitoring Stack

```bash
oc -n openshift-monitoring create configmap cluster-monitoring-config \
  --from-literal=config.yaml='
alertmanagerMain:
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
      operator: Exists
prometheusK8s:
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
      operator: Exists
prometheusOperator:
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
      operator: Exists
grafana:
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
      operator: Exists
k8sPrometheusAdapter:
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
      operator: Exists
kubeStateMetrics:
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
      operator: Exists
telemeterClient:
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
      operator: Exists
'

# Aguardar pods recriar nos infra nodes
oc get pods -n openshift-monitoring -o wide -w
```

---

## 11. Validação Final do Cluster

### 11.1 Saúde geral do cluster

```bash
export KUBECONFIG=~/ocp-install/auth/kubeconfig

# Nodes
oc get nodes -o wide

# Espera-se:
# master-0/1/2   Ready   master   ...
# worker-0/1     Ready   worker   ...
# infra-0/1      Ready   infra    ...

# Operators
oc get clusteroperators
# Todos devem estar: AVAILABLE=True, PROGRESSING=False, DEGRADED=False
```

### 11.2 Validar etcd

```bash
# Entrar em um pod etcd
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)

# Dentro do pod:
etcdctl endpoint health \
  --endpoints=https://master-0.ocp.example.com:2379,https://master-1.ocp.example.com:2379,https://master-2.ocp.example.com:2379 \
  --cacert=/etc/kubernetes/static-pod-resources/etcd-certs/configmaps/etcd-serving-ca/ca-bundle.crt \
  --cert=/etc/kubernetes/static-pod-resources/etcd-certs/secrets/etcd-all-certs/etcd-peer-master-0.ocp.example.com.crt \
  --key=/etc/kubernetes/static-pod-resources/etcd-certs/secrets/etcd-all-certs/etcd-peer-master-0.ocp.example.com.key
```

### 11.3 Validar Ingress

```bash
# Criar app de teste
oc new-project test-ingress
oc new-app --image=nginx --name=nginx-test -n test-ingress
oc expose service nginx-test -n test-ingress

# Verificar route
oc get route nginx-test -n test-ingress

# Testar acesso
curl -I http://nginx-test-test-ingress.apps.ocp.example.com

# Limpar
oc delete project test-ingress
```

### 11.4 Verificar distribuição de pods nos infra nodes

```bash
# Router
oc get pods -n openshift-ingress -o wide | grep -E "NODE|infra"

# Registry
oc get pods -n openshift-image-registry -o wide | grep -E "NODE|infra"

# Monitoring
oc get pods -n openshift-monitoring -o wide | grep -E "NODE|infra"
```

### 11.5 Checklist final

```
[ ] Todos os 7 nodes em Ready
[ ] Todos os ClusterOperators Available=True, Degraded=False
[ ] etcd com 3 membros healthy
[ ] Router rodando nos infra nodes
[ ] Registry rodando nos infra nodes
[ ] Monitoring rodando nos infra nodes
[ ] Workers sem pods de infra
[ ] Console web acessível em https://console-openshift-console.apps.ocp.example.com
[ ] Login com kubeadmin funcional
[ ] Trocar senha do kubeadmin (configurar identity provider)
```

---

## 12. Comandos de Referência Rápida

```bash
# Exportar kubeconfig
export KUBECONFIG=~/ocp-install/auth/kubeconfig

# Obter credenciais do kubeadmin
cat ~/ocp-install/auth/kubeadmin-password

# Ver todos os nodes com roles
oc get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels

# Ver eventos recentes com problemas
oc get events --all-namespaces --sort-by='.lastTimestamp' | grep -v Normal | tail -30

# Ver logs de um operator
oc logs -n openshift-ingress-operator deploy/ingress-operator -f

# Escalar réplicas do router
oc patch ingresscontroller default -n openshift-ingress-operator \
  --type=merge -p '{"spec":{"replicas":2}}'

# Verificar MachineConfigPools
oc get mcp

# Ver MachineConfigs aplicados a um node
oc get node infra-0.ocp.example.com -o yaml | grep currentConfig

# Debug de node
oc debug node/infra-0.ocp.example.com

# Configurar HTPasswd como identity provider (substituir kubeadmin)
htpasswd -c -B -b /tmp/htpasswd admin MinhaS3nhaF0rte
oc create secret generic htpass-secret \
  --from-file=htpasswd=/tmp/htpasswd \
  -n openshift-config

oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
    - name: htpasswd_provider
      mappingMethod: claim
      type: HTPasswd
      htpasswd:
        fileData:
          name: htpass-secret
EOF

# Dar role cluster-admin ao novo usuário
oc adm policy add-cluster-role-to-user cluster-admin admin
```

---

## Notas de Estudo

| Conceito               | O que estudar                                              |
|------------------------|------------------------------------------------------------|
| **etcd**               | Quorum, backup, restore, defragment                        |
| **MachineConfig**      | Como funciona o MCO, pools, rendered configs               |
| **Ingress**            | Tipos de route (edge/passthrough/reencrypt), certificados  |
| **SDN (OVN)**          | NetworkPolicy, EgressIP, MultusNetworks                    |
| **RBAC**               | ClusterRole, Role, ServiceAccount                          |
| **SCC**                | Security Context Constraints — diferença do K8s padrão     |
| **Operators**          | CVO, OLM, criar seu próprio operator                       |
| **Persistent Storage** | StorageClass, PVC, PV, CSI drivers                         |
| **Identity Providers** | LDAP, HTPasswd, OIDC                                       |
| **Updates**            | Channel, graph, oc adm upgrade                             |

---

*Guia criado para estudo e laboratório. Não utilizar diretamente em produção sem revisão das especificações do ambiente.*
