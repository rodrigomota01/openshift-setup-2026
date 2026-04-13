# Plano de Atualização — OpenShift Container Platform 4.16.x

**Ambiente:** OpenShift 4.16 on Nutanix  
**Objetivo:** Atualizar para a última versão disponível do 4.16.x  
**Data de criação:** 2026-04-13  
**Status:** Em planejamento

---

## Sumário

1. [Informações do Ambiente](#1-informações-do-ambiente)
2. [Riscos e Mitigações](#2-riscos-e-mitigações)
3. [Pré-Requisitos](#3-pré-requisitos)
4. [Fase 1 — Levantamento e Verificação de Saúde](#4-fase-1--levantamento-e-verificação-de-saúde)
5. [Fase 2 — Backup](#5-fase-2--backup)
6. [Fase 3 — Estratégia de Atualização](#6-fase-3--estratégia-de-atualização)
7. [Fase 4 — Execução da Atualização](#7-fase-4--execução-da-atualização)
8. [Fase 5 — Validação Pós-Atualização](#8-fase-5--validação-pós-atualização)
9. [Fase 6 — Rollback](#9-fase-6--rollback)
10. [Checklist Executivo](#10-checklist-executivo)
11. [Registro de Execução](#11-registro-de-execução)

---

## 1. Informações do Ambiente

| Item | Valor |
|---|---|
| Plataforma | OpenShift Container Platform |
| Versão atual | 4.16.x |
| Versão alvo | Última disponível no canal stable-4.16 |
| Infraestrutura | Nutanix AHV |
| Configuração de nodes | MachineConfig / MachineConfigOperator |
| Canal de atualização | stable-4.16 |

### 1.1 Topologia esperada

| Pool | Nodes | Descrição |
|---|---|---|
| master | 3 | Control plane nodes |
| worker | N | Nodes de workload |

> **Preencher antes da execução:** Registrar IPs, hostnames e versão exata atual dos nodes.

---

## 2. Riscos e Mitigações

| Risco | Impacto | Probabilidade | Mitigação |
|---|---|---|---|
| MachineConfig conflitante após update | Alto | Médio | Exportar MCs antes; validar rendered configs pós-update |
| Node não retorna após reinício | Alto | Baixo | Snapshot Nutanix dos control planes antes de iniciar |
| Operator travado em Degraded | Médio | Médio | Monitoramento contínuo; rollback via etcd se necessário |
| CSI Nutanix incompatível | Alto | Baixo | Verificar versão do Nutanix CSI contra a versão alvo |
| Workload interrompido durante drain | Médio | Médio | Pausar MCP worker; executar drain em janela de manutenção |
| Falha no etcd durante update | Crítico | Muito baixo | Backup obrigatório antes de iniciar; snapshot Nutanix |

---

## 3. Pré-Requisitos

### 3.1 Acesso necessário

- [ ] Acesso `cluster-admin` ao cluster OpenShift
- [ ] Acesso ao Nutanix Prism (para snapshots e monitoramento de VMs)
- [ ] Acesso SSH aos control plane nodes (para backup do etcd)
- [ ] Acesso à console web do OpenShift (monitoramento visual)
- [ ] Conectividade com `quay.io` e `registry.redhat.io` (pull de imagens) ou mirror registry configurado

### 3.2 Ferramentas necessárias

```bash
# Verificar versão do cliente oc (deve estar próxima da versão alvo)
oc version --client

# Verificar conectividade com o cluster
oc whoami
oc get nodes
```

### 3.3 Janela de manutenção recomendada

| Etapa | Duração estimada |
|---|---|
| Pré-requisitos e backup | 30–60 min |
| Atualização dos operators | 20–45 min |
| Reinício dos control planes | 30–60 min |
| Reinício dos workers (por node) | 10–20 min cada |
| Validação final | 20–30 min |
| **Total estimado** | **2–4 horas** (depende do número de workers) |

> Recomendado: janela de manutenção de 4 horas em horário de baixo uso.

---

## 4. Fase 1 — Levantamento e Verificação de Saúde

**Critério de entrada:** Execução obrigatória antes de qualquer ação de atualização.  
**Critério de saída:** Todos os checks passando. Nenhum operator Degraded, nenhum node NotReady.

### 4.1 Verificar versão atual e canal

```bash
# Versão atual do cluster
oc get clusterversion

# Canal configurado atualmente
oc get clusterversion -o jsonpath='{.items[0].spec.channel}'

# Detalhes completos da versão
oc describe clusterversion version
```

**Ação esperada:** Canal deve ser `stable-4.16`. Se não estiver, corrigir:

```bash
oc patch clusterversion version --type merge \
  -p '{"spec":{"channel":"stable-4.16"}}'
```

### 4.2 Verificar versões disponíveis para atualização

```bash
# Versões disponíveis no canal (caminhos seguros)
oc adm upgrade

# Incluir versões não recomendadas (para diagnóstico)
oc adm upgrade --include-not-recommended
```

> **Anotar aqui a versão alvo:** `4.16.___`

### 4.3 Verificar saúde dos Cluster Operators

```bash
# Status de todos os operators
oc get clusteroperators

# Filtrar apenas operators com problema (deve retornar vazio se tudo OK)
oc get co | grep -v "True.*False.*False"
```

**Critério de bloqueio:** Se qualquer operator estiver `Degraded=True` ou `Available=False`, a atualização NÃO deve ser iniciada. Resolver o problema antes de prosseguir.

### 4.4 Verificar saúde dos Nodes

```bash
# Status de todos os nodes
oc get nodes

# Nodes com problema (deve retornar vazio se tudo OK)
oc get nodes | grep -v Ready

# Detalhes de recursos dos nodes
oc describe nodes | grep -A 5 "Conditions:"
```

### 4.5 Verificar MachineConfigPools

```bash
# Status dos pools
oc get mcp

# Filtrar pools com problema (deve retornar vazio se tudo OK)
oc get mcp | grep -v "True.*False.*False"

# Detalhes dos pools
oc get mcp -o wide

# Listar MachineConfigs customizados (excluir rendered)
oc get mc | grep -v rendered
```

**Critério de bloqueio:** Se algum MCP estiver `Updating=True` ou `Degraded=True`, aguardar conclusão antes de prosseguir.

### 4.6 Verificar saúde do etcd

```bash
# Pods do etcd
oc get pods -n openshift-etcd

# Health check do etcd (executar dentro de um pod etcd)
oc rsh -n openshift-etcd \
  $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) \
  etcdctl endpoint health --cluster
```

### 4.7 Verificar PVCs e Storage (Nutanix CSI)

```bash
# PVCs com problema (deve retornar vazio)
oc get pvc -A | grep -v Bound

# StorageClasses disponíveis
oc get storageclass

# Pods do Nutanix CSI
oc get pods -n openshift-cluster-csi-drivers | grep nutanix
```

### 4.8 Verificar pods com problema

```bash
# Pods não saudáveis em todos os namespaces
oc get pods -A | grep -v -E "Running|Completed|Succeeded"

# Pods com restarts elevados
oc get pods -A | awk '$5 > 5 {print}'
```

---

## 5. Fase 2 — Backup

**Critério de entrada:** Fase 1 concluída com sucesso.  
**Critério de saída:** Backup do etcd confirmado; arquivos exportados; snapshots Nutanix tirados.

### 5.1 Backup do etcd (OBRIGATÓRIO)

> O backup do etcd é o mecanismo de recuperação mais importante em caso de falha catastrófica.

```bash
# Identificar os control plane nodes
oc get nodes -l node-role.kubernetes.io/master

# Executar backup em CADA control plane node (um de cada vez)
# Substituir <master-node-X> pelo nome real do node

oc debug node/<master-node-1> -- \
  chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup

oc debug node/<master-node-2> -- \
  chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup

oc debug node/<master-node-3> -- \
  chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup
```

```bash
# Verificar que o backup foi criado
oc debug node/<master-node-1> -- \
  chroot /host ls -lh /home/core/assets/backup/
```

> Copiar os arquivos de backup para um storage externo ao cluster (NFS, S3, ou storage do Nutanix fora do cluster).

### 5.2 Exportar configurações críticas do cluster

```bash
# Criar diretório local para backups
mkdir -p ./backup-pre-update-$(date +%F)
cd ./backup-pre-update-$(date +%F)

# MachineConfigs
oc get mc -o yaml > machineconfigs-backup.yaml

# MachineConfigPools
oc get mcp -o yaml > mcp-backup.yaml

# Infrastructure
oc get infrastructure cluster -o yaml > infrastructure.yaml

# Network
oc get network cluster -o yaml > network.yaml

# Proxy (se configurado)
oc get proxy cluster -o yaml > proxy.yaml 2>/dev/null || echo "Sem proxy configurado"

# Scheduler
oc get scheduler cluster -o yaml > scheduler.yaml

# APIServer
oc get apiserver cluster -o yaml > apiserver.yaml

# OAuth
oc get oauth cluster -o yaml > oauth.yaml

# ImageContentSourcePolicy / ImageDigestMirrorSet (se mirror registry)
oc get imagecontentsourcepolicy -o yaml > icsp.yaml 2>/dev/null || true
oc get imagedigestmirrorset -o yaml > idms.yaml 2>/dev/null || true

# Listar arquivos gerados
ls -lh
```

### 5.3 Snapshots no Nutanix Prism

No **Nutanix Prism Element ou Prism Central**, executar antes de iniciar a atualização:

1. Identificar as VMs dos **3 control plane nodes**
2. Criar snapshot manual de cada VM com label: `pre-update-ocp-4.16-YYYY-MM-DD`
3. Confirmar que os snapshots foram criados com sucesso

> Os snapshots dos control plane são o último recurso de recuperação. Workers podem ser recriados mais facilmente.

---

## 6. Fase 3 — Estratégia de Atualização

### 6.1 Comportamento do MachineConfig durante atualização

Durante a atualização do OCP, o processo ocorre em duas etapas distintas:

**Etapa A — Atualização dos Operators:**
- O Cluster Version Operator (CVO) atualiza os operators um por um
- Não há reinício de nodes nesta etapa
- Duração: 20–45 minutos

**Etapa B — Atualização dos Nodes via MachineConfig:**
- O MachineConfigOperator gera novos `rendered-*` configs
- Nodes são drenados e reiniciados respeitando `maxUnavailable` do pool
- Masters: sempre 1 por vez (não configurável)
- Workers: padrão 1 por vez (configurável)

### 6.2 Verificar e ajustar maxUnavailable dos pools

```bash
# Ver configuração atual
oc get mcp master -o jsonpath='{.spec.maxUnavailable}{"\n"}'
oc get mcp worker -o jsonpath='{.spec.maxUnavailable}{"\n"}'
```

> **Recomendação:** Manter `maxUnavailable: 1` nos workers para garantir que workloads não sejam interrompidos. Nunca alterar nos masters.

### 6.3 Decisão: Pausar ou não os MachineConfigPools

**Opção A — Atualização contínua (sem pausar pools):**
- Mais simples, processo automático
- Nodes reiniciam imediatamente após operators serem atualizados
- Recomendado para ambientes onde a interrupção gradual é aceitável

**Opção B — Pausar MCP worker (recomendado para ambientes críticos):**
- Operators atualizam automaticamente
- Nodes workers reiniciam SOMENTE quando você liberar (janela de manutenção)
- Masters não podem ser pausados
- Permite separar atualização de operators da atualização de nodes

```bash
# Para pausar o pool worker ANTES de iniciar a atualização:
oc patch mcp worker --type merge -p '{"spec":{"paused":true}}'

# Verificar
oc get mcp worker -o jsonpath='{.spec.paused}'
```

> **Decisão registrada:** ( ) Opção A — Contínua &nbsp;&nbsp; ( ) Opção B — MCP Worker pausado

---

## 7. Fase 4 — Execução da Atualização

**Critério de entrada:** Fases 1, 2 e 3 concluídas. Backup confirmado. Janela de manutenção iniciada.  
**Critério de saída:** `oc get clusterversion` mostra versão alvo como `True` em `Progressing=False`.

### 7.1 (Se escolheu Opção B) Pausar MCP worker

```bash
oc patch mcp worker --type merge -p '{"spec":{"paused":true}}'
oc get mcp worker -o jsonpath='{.spec.paused}'
```

### 7.2 Iniciar a atualização

```bash
# Opção 1: Atualizar para a última versão disponível no canal
oc adm upgrade --to-latest=true

# Opção 2: Atualizar para uma versão específica
oc adm upgrade --to=4.16.X
```

### 7.3 Monitorar progresso dos Cluster Operators

```bash
# Monitoramento em tempo real (atualiza a cada 30s)
watch -n 30 'echo "=== CLUSTER VERSION ===" && \
  oc get clusterversion && \
  echo "" && \
  echo "=== OPERATORS COM PROBLEMA ===" && \
  oc get co | grep -v "True.*False.*False" || echo "Todos saudáveis"'
```

```bash
# Ver histórico de progresso da atualização
oc describe clusterversion version | grep -A 30 "Conditions:"

# Logs do CVO
oc logs -n openshift-cluster-version \
  deploy/cluster-version-operator -f --tail=100
```

> Esta etapa leva de **20 a 45 minutos**. Acompanhar até todos os operators estarem atualizados.

### 7.4 Monitorar atualização dos Control Plane nodes

Os masters atualizam automaticamente (não é possível pausar):

```bash
# Status dos nodes e MCPs
watch -n 20 'echo "=== NODES ===" && \
  oc get nodes && \
  echo "" && \
  echo "=== MACHINE CONFIG POOLS ===" && \
  oc get mcp'

# Logs do MCO
oc logs -n openshift-machine-config-operator \
  deploy/machine-config-operator -f --tail=50
```

> Masters reiniciam **1 por vez**. Esta etapa leva de **30 a 60 minutos**.

### 7.5 (Se escolheu Opção B) Liberar MCP worker na janela de manutenção

```bash
# Verificar que operators e masters já foram atualizados
oc get clusterversion
oc get nodes -l node-role.kubernetes.io/master

# Liberar workers
oc patch mcp worker --type merge -p '{"spec":{"paused":false}}'

# Monitorar drain e reinício dos workers
watch -n 20 'echo "=== NODES ===" && \
  oc get nodes && \
  echo "" && \
  echo "=== MCP STATUS ===" && \
  oc get mcp'
```

### 7.6 Acompanhar drain de cada worker node

```bash
# Ver eventos de drain em tempo real
oc get events -A --field-selector reason=Drain -w

# Ver qual node está sendo drenado
oc get nodes -o wide | grep -v Ready
```

> Workers reiniciam **1 por vez** (com `maxUnavailable: 1`). Calcular: N workers × 10–20 min cada.

---

## 8. Fase 5 — Validação Pós-Atualização

**Critério de entrada:** `oc get mcp` mostra todos os pools com `Updated=True`.  
**Critério de saída:** Todos os checks abaixo passando.

### 8.1 Verificar versão final

```bash
# Versão do cluster
oc get clusterversion

# Versões dos componentes
oc version
```

**Resultado esperado:** `Cluster version is X.X.X` sem mensagens de progresso.

### 8.2 Verificar saúde dos Cluster Operators

```bash
# Todos os operators devem estar Available=True, Progressing=False, Degraded=False
oc get co

# Filtrar problemas (deve retornar vazio)
oc get co | grep -v "True.*False.*False"
```

### 8.3 Verificar saúde dos Nodes

```bash
# Todos os nodes devem estar Ready
oc get nodes

# Confirmar versão do kubelet em todos os nodes (deve ser a versão alvo)
oc get nodes -o wide
```

### 8.4 Verificar MachineConfigPools

```bash
# Todos os pools devem estar Updated=True, Updating=False, Degraded=False
oc get mcp

# Confirmar rendered configs estão atualizados
oc get mc | grep rendered
```

### 8.5 Verificar componentes Nutanix

```bash
# CSI Driver do Nutanix
oc get pods -n openshift-cluster-csi-drivers | grep nutanix

# StorageClasses
oc get storageclass

# PVCs (todos devem estar Bound)
oc get pvc -A | grep -v Bound || echo "Todos os PVCs estão Bound"
```

### 8.6 Verificar pods com problema

```bash
# Pods não saudáveis (deve retornar vazio ou apenas jobs concluídos)
oc get pods -A | grep -v -E "Running|Completed|Succeeded"
```

### 8.7 Verificar MachineConfigs customizados

```bash
# Confirmar que os MachineConfigs customizados ainda estão presentes
oc get mc | grep -v rendered

# Comparar com o backup
diff <(oc get mc --no-headers | awk '{print $1}' | grep -v rendered | sort) \
     <(grep "^  name:" ./backup-pre-update-*/machineconfigs-backup.yaml | \
       awk '{print $2}' | grep -v rendered | sort)
```

### 8.8 Teste funcional básico

```bash
# Criar namespace de teste
oc new-project test-post-update

# Deploy de pod de teste
oc run test-pod --image=registry.access.redhat.com/ubi9/ubi:latest \
  --command -- sleep 300 -n test-post-update

# Verificar que pod subiu
oc get pod test-pod -n test-post-update

# Limpar namespace de teste
oc delete project test-post-update
```

---

## 9. Fase 6 — Rollback

> O rollback no OpenShift não é uma operação trivial. Não existe "downgrade" automático após uma atualização bem-sucedida. As opções abaixo são ordenadas por preferência.

### 9.1 Opção 1 — Reverter via CVO (apenas durante progresso)

Válido apenas se a atualização ainda está em progresso e não foi concluída:

```bash
# Forçar retorno para versão anterior (use com cuidado)
oc adm upgrade --force --to=<versão-anterior>
```

### 9.2 Opção 2 — Restaurar etcd (cluster inacessível ou corrompido)

Se o cluster estiver inacessível ou os control planes estiverem em estado inválido:

```bash
# Em um dos control plane nodes (via SSH ou acesso direto à VM no Nutanix):
# 1. Copiar backup para o node
# 2. Executar restauração
sudo -E /usr/local/bin/cluster-restore.sh /home/core/assets/backup/<backup-dir>
```

Seguir documentação oficial: [Restoring to a previous cluster state](https://docs.openshift.com/container-platform/4.16/backup_and_restore/control_plane_backup_and_restore/disaster_recovery/scenario-2-restoring-cluster-state.html)

### 9.3 Opção 3 — Restaurar snapshots Nutanix (último recurso)

Se o etcd não puder ser restaurado:

1. Desligar as VMs dos control plane nodes no Nutanix Prism
2. Restaurar snapshot `pre-update-ocp-4.16-YYYY-MM-DD` de cada VM
3. Religar as VMs
4. Verificar saúde do cluster

> Esta opção pode resultar em inconsistências se workers já foram atualizados.

---

## 10. Checklist Executivo

### Pré-Atualização

```
[ ] Janela de manutenção agendada e comunicada
[ ] Acesso cluster-admin confirmado
[ ] Acesso Nutanix Prism confirmado
[ ] Canal stable-4.16 configurado
[ ] oc adm upgrade — versão alvo identificada e anotada: 4.16.___
[ ] oc get co — zero operators Degraded ou Unavailable
[ ] oc get nodes — todos os nodes em Ready
[ ] oc get mcp — todos os pools Updated=True, Degraded=False
[ ] oc get pods -n openshift-etcd — todos Running
[ ] etcdctl endpoint health — todos healthy
[ ] oc get pvc -A — todos Bound
[ ] Nutanix CSI pods Running
[ ] Backup etcd executado nos 3 masters
[ ] Backup etcd copiado para storage externo
[ ] Configurações exportadas (mc, mcp, infrastructure, network)
[ ] Snapshots Nutanix criados nos 3 control plane nodes
[ ] Decisão sobre pausar MCP worker registrada
```

### Durante a Atualização

```
[ ] (Se Opção B) MCP worker pausado
[ ] oc adm upgrade executado
[ ] Progresso dos operators monitorado
[ ] Todos os operators atualizados (Available=True)
[ ] Masters atualizados (1 por vez) — sem erros
[ ] (Se Opção B) MCP worker liberado na janela de manutenção
[ ] Workers atualizados (1 por vez) — sem erros
```

### Pós-Atualização

```
[ ] oc get clusterversion — versão alvo confirmada
[ ] oc get co — todos Available=True, Degraded=False
[ ] oc get nodes — todos Ready, versão correta
[ ] oc get mcp — todos Updated=True
[ ] Nutanix CSI pods Running
[ ] oc get pvc -A — todos Bound
[ ] MachineConfigs customizados presentes
[ ] Teste funcional de pod realizado
[ ] Documentação atualizada com versão final
[ ] Snapshots Nutanix mantidos por 30 dias (recomendado)
```

---

## 11. Registro de Execução

> Preencher durante e após a execução para rastreabilidade.

| Campo | Valor |
|---|---|
| Data de execução | |
| Executado por | |
| Versão inicial | |
| Versão final | |
| Canal utilizado | stable-4.16 |
| MCP worker pausado? | ( ) Sim &nbsp; ( ) Não |
| Início da execução | |
| Operators atualizados em | |
| Masters atualizados em | |
| Workers atualizados em | |
| Fim da execução | |
| Duração total | |
| Incidentes durante execução | |
| Ações corretivas tomadas | |
| Status final | ( ) Sucesso &nbsp; ( ) Falha parcial &nbsp; ( ) Rollback |

### Notas e Observações

> *(Espaço para anotações livres durante a execução)*

---

## Referências

- [OpenShift 4.16 Update Documentation](https://docs.openshift.com/container-platform/4.16/updating/updating_a_cluster/updating-cluster-cli.html)
- [Backing up etcd](https://docs.openshift.com/container-platform/4.16/backup_and_restore/control_plane_backup_and_restore/backing-up-etcd.html)
- [MachineConfigOperator](https://docs.openshift.com/container-platform/4.16/post_installation_configuration/machine-configuration-tasks.html)
- [Nutanix CSI Driver for OpenShift](https://portal.nutanix.com/page/documents/details?targetId=CSI-Volume-Driver-v2_6:CSI-Volume-Driver-v2_6)
- [Update channels and releases](https://docs.openshift.com/container-platform/4.16/updating/understanding_updates/understanding-update-channels-release.html)

---

*Documento gerado em 2026-04-13 — Revisão obrigatória antes da execução.*
