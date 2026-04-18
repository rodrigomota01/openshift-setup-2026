# Pos-Upgrade OpenShift 4.18 - Problemas e Correcoes

Documento com todos os problemas enfrentados apos o upgrade do OpenShift 4.16 -> 4.17 -> 4.18 e a configuracao do OpenShift Logging com Loki + S3.

**Cluster:** OCP 4.18 (Kubernetes 1.31)
**Base Domain:** ocp.177.54.151.49.sslip.io
**Infra:** Proxmox (node suhr) - 3 masters, 2 workers, 2 infra
**Data:** 17/04/2026

---

## 1. Console do OpenShift parou de funcionar apos upgrade para 4.18

### Problema

Apos o upgrade para 4.18, a console web do OpenShift parou de funcionar. O CLI (`oc`) funcionava normalmente. Nos logs do console:

```
E0417 21:43:05 handlers.go:170 failed to send GET request for "monitoring-plugin" plugin:
  Get "https://monitoring-plugin.openshift-monitoring.svc.cluster.local:9443/...":
  dial tcp 177.54.151.49:9443: connect: connection refused
```

Os servicos internos (`.svc.cluster.local`) estavam resolvendo para o IP externo `177.54.151.49` em vez do ClusterIP.

### Causa Raiz

Combinacao de `sslip.io` como base domain + `ndots:5` no resolv.conf dos pods.

O `resolv.conf` dos pods continha:
```
search openshift-console.svc.cluster.local svc.cluster.local cluster.local ocp.177.54.151.49.sslip.io
nameserver 172.30.0.10
options ndots:5
```

Quando o console resolvia `monitoring-plugin.openshift-monitoring.svc.cluster.local` (4 dots, menor que ndots:5), o resolver tentava os search domains primeiro. Ao chegar em `ocp.177.54.151.49.sslip.io`, o nome completo ficava:

```
monitoring-plugin.openshift-monitoring.svc.cluster.local.ocp.177.54.151.49.sslip.io
```

O wildcard do sslip.io resolvia qualquer subdominio de `177.54.151.49.sslip.io` para `177.54.151.49`, retornando uma resposta valida antes do resolver tentar o nome absoluto.

### Correcao

Configurar o CoreDNS para retornar NXDOMAIN para queries em `*.cluster.local.ocp.177.54.151.49.sslip.io`.

**Passo 1 - Colocar o operador DNS em modo Unmanaged:**
```bash
oc patch dns.operator/default --type merge -p '{"spec":{"managementState":"Unmanaged"}}'
```

**Passo 2 - Editar o ConfigMap do CoreDNS:**
```bash
oc edit configmap dns-default -n openshift-dns
```

Adicionar o seguinte bloco no final do Corefile (apos o bloco `hostname.bind`):

```
    cluster.local.ocp.177.54.151.49.sslip.io:5353 {
        template IN ANY cluster.local.ocp.177.54.151.49.sslip.io {
            rcode NXDOMAIN
        }
    }
```

O Corefile completo ficou:
```
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
cluster.local.ocp.177.54.151.49.sslip.io:5353 {
    template IN ANY cluster.local.ocp.177.54.151.49.sslip.io {
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
ocp.177.54.151.49.sslip.io:5353 {
    template IN ANY ocp.177.54.151.49.sslip.io {
        rcode NXDOMAIN
    }
}
```

> **Nota:** Os blocos `apps/api/api-int` preservam a resolucao de nomes legitimos (routes e API). O bloco generico `ocp.177.54.151.49.sslip.io` retorna NXDOMAIN para queries poluidas pelo search domain (ex: `hooks.slack.com.ocp.177.54.151.49.sslip.io`), permitindo que o resolver tente o hostname absoluto. Sem isso, servicos que acessam endpoints externos (Alertmanager -> Slack/Gmail/Discord) falham com erros de TLS.

**Passo 3 - Reiniciar os pods do CoreDNS:**
```bash
oc delete pods -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default
```

**Passo 4 - Validar:**
```bash
oc exec -n openshift-console deployment/console -- nslookup networking-console-plugin.openshift-network-console.svc.cluster.local
```

Resultado esperado: `172.30.97.28` (ClusterIP) em vez de `177.54.151.49`.

> **Nota:** O operador DNS deve permanecer em `Unmanaged` enquanto o cluster usar sslip.io como base domain. Em caso de upgrade futuro, voltar para `Managed` antes do upgrade, fazer o upgrade, e reaplicar o fix.

---

## 2. Configuracao do OpenShift Logging com Loki + S3

### Pre-requisitos

- Bucket S3: `atn-bucket-teste` (us-east-1)
- Credenciais AWS (Access Key ID + Secret Access Key)

### 2.1 Instalar o Loki Operator

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators-redhat
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators-redhat
  namespace: openshift-operators-redhat
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.1
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Validar:
```bash
oc get csv -n openshift-operators-redhat
# Esperar "Succeeded"
```

### 2.2 Instalar o Cluster Logging Operator

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-logging
  namespace: openshift-logging
spec:
  targetNamespaces:
    - openshift-logging
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable-6.1
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Validar:
```bash
oc get csv -n openshift-logging
# Esperar "Succeeded"
```

### 2.3 Instalar o LVMS Operator (Storage Local)

O Loki precisa de PVCs para cache local. Como o cluster nao tinha StorageClass, foi necessario instalar o LVMS (Logical Volume Manager Storage).

**Passo 1 - Instalar o operador:**
```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage
  namespace: openshift-storage
spec:
  targetNamespaces:
    - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  channel: stable-4.18
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

**Passo 2 - Adicionar disco extra nas VMs (Proxmox):**

O LVMS precisa de discos raw sem filesystem. Como cada VM so tinha o disco do SO (`/dev/sda`), foi necessario adicionar um segundo disco de 50GB nos workers e infra via Proxmox:

```bash
# No host Proxmox (suhr)
qm set 2021 --scsi1 vz-folder:50,discard=on   # worker-0
qm set 2022 --scsi1 vz-folder:50,discard=on   # worker-1
qm set 2031 --scsi1 vz-folder:50,discard=on   # infra-0
qm set 2032 --scsi1 vz-folder:50,discard=on   # infra-1
```

Os discos aparecem via hotplug como `/dev/sdb` sem necessidade de reiniciar as VMs.

**Passo 3 - Criar o LVMCluster:**

Os masters nao receberam disco extra, entao o LVMCluster foi configurado para excluir masters:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
      - name: vg1
        default: true
        nodeSelector:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/master
                  operator: DoesNotExist
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
EOF
```

Validar:
```bash
oc get lvmcluster -n openshift-storage
# STATUS: Ready

oc get sc
# Deve aparecer: lvms-vg1 (default)
```

### 2.4 Criar o Secret com credenciais S3

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: logging-loki-s3
  namespace: openshift-logging
type: Opaque
stringData:
  access_key_id: "SUA_ACCESS_KEY_AQUI"
  access_key_secret: "SUA_SECRET_KEY_AQUI"
  bucketnames: "atn-bucket-teste"
  endpoint: "https://s3.us-east-1.amazonaws.com"
  region: "us-east-1"
EOF
```

### 2.5 Criar o LokiStack

```bash
cat <<'EOF' | oc apply -f -
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  size: 1x.extra-small
  storage:
    schemas:
      - effectiveDate: "2024-10-01"
        version: v13
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: lvms-vg1
  tenants:
    mode: openshift-logging
EOF
```

#### Problema: Pods Pending por falta de recursos

O LokiStack `1x.extra-small` cria varios pods. O ingester pede 2 CPUs e 8Gi de RAM. Os workers (originalmente 2 cores, 8GB RAM) e infra (4 cores, 16GB) nao tinham recursos suficientes.

**Correcao - Aumentar recursos das VMs no Proxmox:**

```bash
# Workers: 2 -> 4 cores
qm set 2021 --cores 4   # worker-0
qm set 2022 --cores 4   # worker-1

# Infra: 4 -> 8 cores, 16GB -> 24GB
qm set 2031 --cores 8 --memory 24576   # infra-0
qm set 2032 --cores 8 --memory 24576   # infra-1
```

Para aplicar mudancas de CPU/memoria, reiniciar cada VM uma por vez:
```bash
oc adm drain <node> --ignore-daemonsets --delete-emptydir-data
# Reiniciar VM no Proxmox
oc get node <node> -w  # Esperar Ready
oc adm uncordon <node>
```

Validar:
```bash
oc get pods -n openshift-logging
# Todos os pods devem estar Running
```

### 2.6 Criar a ServiceAccount e ClusterLogForwarder

**Passo 1 - Criar ServiceAccount:**
```bash
oc create serviceaccount collector -n openshift-logging
```

**Passo 2 - Adicionar permissoes:**
```bash
oc adm policy add-cluster-role-to-user logging-collector-logs-writer -z collector -n openshift-logging
oc adm policy add-cluster-role-to-user cluster-logging-write-application-logs -z collector -n openshift-logging
oc adm policy add-cluster-role-to-user cluster-logging-write-infrastructure-logs -z collector -n openshift-logging
oc adm policy add-cluster-role-to-user cluster-logging-write-audit-logs -z collector -n openshift-logging
oc adm policy add-cluster-role-to-user collect-application-logs -z collector -n openshift-logging
oc adm policy add-cluster-role-to-user collect-infrastructure-logs -z collector -n openshift-logging
oc adm policy add-cluster-role-to-user collect-audit-logs -z collector -n openshift-logging
```

**Passo 3 - Criar o ClusterLogForwarder:**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  serviceAccount:
    name: collector
  outputs:
    - name: default-lokistack
      type: lokiStack
      lokiStack:
        target:
          name: logging-loki
          namespace: openshift-logging
        authentication:
          token:
            from: serviceAccount
      tls:
        ca:
          configMapName: logging-loki-gateway-ca-bundle
          key: service-ca.crt
  pipelines:
    - name: default-logs
      inputRefs:
        - infrastructure
        - application
        - audit
      outputRefs:
        - default-lokistack
EOF
```

#### Problema: Erro TLS - self-signed certificate in certificate chain

O collector (Vector) nao conseguia conectar ao gateway do Loki por erro de certificado TLS.

**Causa:** O ClusterLogForwarder usava o ConfigMap `logging-loki-ca-bundle` (Loki signing CA) em vez do `logging-loki-gateway-ca-bundle` (OpenShift service-ca que assina o certificado do gateway).

**Correcao:** Usar `logging-loki-gateway-ca-bundle` no campo `tls.ca.configMapName` (ja incluido no YAML acima).

#### Problema: Erro 403 Forbidden

Apos corrigir o TLS, o collector recebia 403 ao enviar logs.

**Causa:** A ServiceAccount `collector` nao tinha as ClusterRoles necessarias para escrever logs no LokiStack.

**Correcao:** Adicionar as roles `logging-collector-logs-writer`, `cluster-logging-write-*-logs` e `collect-*-logs` (ja incluido nos comandos acima).

Validar:
```bash
oc get daemonset -n openshift-logging
# collector: 7/7 Ready

oc logs -n openshift-logging -l app.kubernetes.io/component=collector --tail=5 2>&1 | grep ERROR
# Nenhum erro deve aparecer
```

### 2.7 Instalar o Cluster Observability Operator (UI de Logs)

Para ter a aba **Observe -> Logs** na console do OpenShift:

**Passo 1 - Instalar o operador:**
```bash
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

**Passo 2 - Criar o UIPlugin:**
```bash
cat <<'EOF' | oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: logging
spec:
  type: Logging
  logging:
    lokiStack:
      name: logging-loki
EOF
```

Validar: Acessar a console do OpenShift em **Observe -> Logs**, selecionar **infrastructure** e clicar em **Run Query**.

---

## Resumo dos Operadores Instalados

| Operador | Namespace | Finalidade |
|----------|-----------|------------|
| Loki Operator | openshift-operators-redhat | Backend de logs (Loki) |
| Cluster Logging Operator | openshift-logging | Coleta de logs (Vector) |
| LVMS Operator | openshift-storage | Storage local (LVM) para PVCs do Loki |
| Cluster Observability Operator | openshift-operators | UI de Logs na console |

## Resumo dos Recursos das VMs (apos ajustes)

| Node | Cores | RAM | Disco Extra |
|------|-------|-----|-------------|
| master-0/1/2 | 4 | 16GB | Nao |
| worker-0/1 | 4 | 8GB | 50GB (sdb) |
| infra-0/1 | 8 | 24GB | 50GB (sdb) |

## 3. Deploy de Aplicacao de Exemplo + Logs + Alertas

### 3.1 Deploy da Aplicacao

Vamos subir uma aplicacao simples que gera logs para validar a stack completa.

```bash
# Criar o projeto
oc new-project demo-logging

# Deploy de uma app que gera logs continuamente
cat <<'EOF' | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-generator
  namespace: demo-logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: log-generator
  template:
    metadata:
      labels:
        app: log-generator
    spec:
      containers:
        - name: log-generator
          image: quay.io/openshift-logging/cluster-logging-load-client:latest
          env:
            - name: PAYLOAD_GEN
              value: "true"
            - name: MSG_PER_SEC
              value: "1"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app
  namespace: demo-logging
spec:
  replicas: 2
  selector:
    matchLabels:
      app: sample-app
  template:
    metadata:
      labels:
        app: sample-app
    spec:
      containers:
        - name: app
          image: registry.access.redhat.com/ubi9/httpd-24:latest
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: sample-app
  namespace: demo-logging
spec:
  selector:
    app: sample-app
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: sample-app
  namespace: demo-logging
spec:
  to:
    kind: Service
    name: sample-app
  port:
    targetPort: 8080
EOF
```

Validar:
```bash
oc get pods -n demo-logging
# log-generator e sample-app devem estar Running

# Verificar se os logs estao chegando no Loki (via console: Observe -> Logs)
# Selecionar "application", filtrar por namespace: demo-logging
```

### 3.2 Verificar Logs da Aplicacao no Loki

Via CLI usando o endpoint do Loki gateway:

```bash
# Pegar a URL do gateway
oc get route -n openshift-logging

# Ou via console: Observe -> Logs -> selecionar "application"
# Usar o filtro: {kubernetes_namespace_name="demo-logging"}
```

Via LogQL na aba Observe -> Logs:
```
{kubernetes_namespace_name="demo-logging"} |= "error"
{kubernetes_namespace_name="demo-logging", kubernetes_container_name="app"}
{kubernetes_namespace_name="demo-logging"} | json | level="error"
```

### 3.3 Configurar Alertas baseados em Logs (Loki Ruler)

O LokiStack suporta AlertingRules e RecordingRules nativas. Esses alertas sao avaliados pelo ruler do Loki e integrados ao Alertmanager do OpenShift.

**Passo 1 - Criar AlertingRule para logs de erro da aplicacao:**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: loki.grafana.com/v1
kind: AlertingRule
metadata:
  name: demo-logging-alerts
  namespace: demo-logging
  labels:
    openshift.io/cluster-monitoring: "true"
spec:
  tenantID: application
  groups:
    - name: demo-app-errors
      interval: 1m
      rules:
        - alert: HighErrorRateInDemoApp
          expr: |
            sum(count_over_time({kubernetes_namespace_name="demo-logging"} |= "error" [5m])) > 10
          for: 5m
          labels:
            severity: warning
            namespace: demo-logging
          annotations:
            summary: "Alta taxa de erros na aplicacao demo"
            description: "Mais de 10 logs de erro nos ultimos 5 minutos no namespace demo-logging."
        - alert: NoLogsFromDemoApp
          expr: |
            absent_over_time({kubernetes_namespace_name="demo-logging", kubernetes_container_name="app"} [15m])
          for: 15m
          labels:
            severity: critical
            namespace: demo-logging
          annotations:
            summary: "Sem logs da aplicacao demo"
            description: "Nenhum log recebido do container 'app' no namespace demo-logging nos ultimos 15 minutos."
EOF
```

**Passo 2 - Criar alertas via PrometheusRule (para metricas de pods):**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: demo-app-metrics-alerts
  namespace: demo-logging
  labels:
    openshift.io/cluster-monitoring: "true"
spec:
  groups:
    - name: demo-app-health
      rules:
        - alert: DemoAppPodRestarting
          expr: |
            increase(kube_pod_container_status_restarts_total{namespace="demo-logging", container="app"}[1h]) > 3
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod da demo app reiniciando frequentemente"
            description: "O container {{ $labels.container }} no pod {{ $labels.pod }} reiniciou mais de 3 vezes na ultima hora."
        - alert: DemoAppPodNotReady
          expr: |
            kube_pod_status_ready{namespace="demo-logging", condition="true"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Pod da demo app nao esta Ready"
            description: "O pod {{ $labels.pod }} no namespace demo-logging nao esta Ready ha mais de 5 minutos."
EOF
```

Validar:
```bash
# Verificar que as regras foram criadas
oc get alertingrules -n demo-logging
oc get prometheusrules -n demo-logging

# Verificar no console: Observe -> Alerting -> Alerting Rules
# Os alertas devem aparecer listados
```

### 3.4 Configurar Receivers no Alertmanager (opcional)

Para receber notificacoes dos alertas (email, Slack, etc), editar o secret do Alertmanager:

```bash
# Ver a configuracao atual
oc -n openshift-monitoring get secret alertmanager-main -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d

# Exemplo: adicionar um receiver de webhook/Slack
cat <<'EOF' > /tmp/alertmanager.yaml
global:
  resolve_timeout: 5m
route:
  receiver: default
  group_by: ['namespace', 'alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  routes:
    - receiver: demo-app-alerts
      matchers:
        - namespace = "demo-logging"
receivers:
  - name: default
  - name: demo-app-alerts
    webhook_configs:
      - url: "http://seu-webhook-endpoint:5001/"
        send_resolved: true
EOF

oc -n openshift-monitoring create secret generic alertmanager-main --from-file=alertmanager.yaml=/tmp/alertmanager.yaml --dry-run=client -o yaml | oc apply -f -
```

---

## 4. Dashboards e Interfaces para Visualizacao

### 4.1 Interfaces ja disponiveis (built-in)

Com a stack atual, voce ja tem:

| Interface | Acesso | O que mostra |
|-----------|--------|-------------|
| **Observe → Logs** | Console OCP | Queries LogQL no Loki (logs de app/infra/audit) |
| **Observe → Metrics** | Console OCP | Queries PromQL no Prometheus |
| **Observe → Alerting** | Console OCP | Alertas ativos e regras configuradas |
| **Observe → Dashboards** | Console OCP | Dashboards pre-configurados de infra (etcd, API server, nodes, etc) |

### 4.2 Instalar Dashboards UIPlugin (Cluster Observability Operator)

O Cluster Observability Operator que voce ja instalou suporta UIPlugins adicionais para dashboards customizados:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: dashboards
spec:
  type: Dashboards
EOF
```

Isso habilita a criacao de dashboards customizados diretamente na console do OCP.

### 4.3 Instalar Grafana (Community) para Dashboards Avancados

O Grafana permite criar dashboards mais complexos conectando a multiplas fontes (Loki, Prometheus, etc).

**Passo 1 - Deploy do Grafana:**

```bash
oc new-project grafana

cat <<'EOF' | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: docker.io/grafana/grafana:11.4.0
          ports:
            - containerPort: 3000
          env:
            - name: GF_SECURITY_ADMIN_USER
              value: admin
            - name: GF_SECURITY_ADMIN_PASSWORD
              value: admin123
          volumeMounts:
            - name: grafana-storage
              mountPath: /var/lib/grafana
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: grafana-storage
          persistentVolumeClaim:
            claimName: grafana-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
  namespace: grafana
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: lvms-vg1
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: grafana
spec:
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: grafana
  namespace: grafana
spec:
  to:
    kind: Service
    name: grafana
  port:
    targetPort: 3000
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
```

**Passo 2 - Criar ServiceAccount para o Grafana acessar Loki e Prometheus:**

```bash
# SA para acessar o Thanos Querier (metricas) e Loki (logs)
oc create serviceaccount grafana-sa -n grafana
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z grafana-sa -n grafana

# Permissoes para ler logs no Loki
oc adm policy add-cluster-role-to-user cluster-logging-application-view -z grafana-sa -n grafana
oc adm policy add-cluster-role-to-user cluster-logging-infrastructure-view -z grafana-sa -n grafana
oc adm policy add-cluster-role-to-user cluster-logging-audit-view -z grafana-sa -n grafana

# Pegar o token
GRAFANA_TOKEN=$(oc create token grafana-sa -n grafana --duration=8760h)
echo $GRAFANA_TOKEN
```

**Passo 3 - Configurar Datasources no Grafana:**

Acessar o Grafana via route (`oc get route grafana -n grafana`) e adicionar:

**Datasource 1 - Prometheus (Thanos Querier):**
- Type: Prometheus
- URL: `https://thanos-querier.openshift-monitoring.svc.cluster.local:9091`
- Auth: Custom Header → `Authorization: Bearer <GRAFANA_TOKEN>`
- TLS: Skip TLS Verify = true (ou usar o CA do cluster)

**Datasource 2 - Loki:**
- Type: Loki
- URL: `https://logging-loki-gateway-http.openshift-logging.svc.cluster.local:8080/api/logs/v1/application`
- Auth: Custom Header → `Authorization: Bearer <GRAFANA_TOKEN>`
- TLS: Skip TLS Verify = true

> **Nota:** O Loki gateway tem endpoints separados por tenant:
> - `/api/logs/v1/application` - logs de aplicacao
> - `/api/logs/v1/infrastructure` - logs de infraestrutura
> - `/api/logs/v1/audit` - logs de auditoria
>
> Crie um datasource para cada tipo que quiser visualizar.

**Passo 4 - Importar dashboards uteis:**

No Grafana, va em Dashboards → Import e use estes IDs do grafana.com:
- **15141** - Kubernetes Logs (via Loki)
- **13639** - Loki & Promtail
- **1860** - Node Exporter Full

Validar:
```bash
oc get route grafana -n grafana
# Acessar a URL, login: admin / admin123
# Testar os datasources: Configuration -> Data Sources -> Test
```

---

## 5. Aplicacao de Testes com Alertas (Email, Discord, Slack)

### 5.1 Deploy da Aplicacao de Testes

Uma aplicacao Python que gera logs com diferentes niveis (info, warning, error, critical) de forma controlada, simulando cenarios reais.

```bash
oc new-project demo-alerts

cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: error-generator-script
  namespace: demo-alerts
data:
  app.py: |
    import time
    import random
    import json
    import sys
    import os
    from datetime import datetime
    from http.server import HTTPServer, BaseHTTPRequestHandler

    ERROR_RATE = int(os.getenv("ERROR_RATE", "20"))

    class HealthHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")
            elif self.path == "/crash":
                log("critical", "CRASH SIMULADO - aplicacao vai reiniciar!")
                sys.exit(1)
            elif self.path == "/error-burst":
                for i in range(50):
                    log("error", f"ERROR BURST {i}/50 - falha massiva simulada")
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"50 errors generated")
            else:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"demo app - use /crash or /error-burst to test alerts")
        def log_message(self, format, *args):
            pass

    def log(level, message):
        entry = {
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "level": level,
            "app": "error-generator",
            "message": message
        }
        print(json.dumps(entry), flush=True)

    def background_logs():
        messages = {
            "info": [
                "Request processed successfully",
                "User login successful",
                "Database query completed in 45ms",
                "Cache hit for session abc123",
                "Health check passed"
            ],
            "warning": [
                "Response time above threshold: 2300ms",
                "Memory usage at 85%",
                "Connection pool near capacity: 18/20",
                "Retry attempt 2/3 for external API",
                "Disk usage at 90%"
            ],
            "error": [
                "Failed to connect to database: connection refused",
                "NullPointerException in PaymentService.process()",
                "API request timeout after 30s: external-service.com",
                "Authentication failed: invalid token",
                "Out of memory error in worker thread"
            ],
            "critical": [
                "Database cluster unreachable - all replicas down",
                "Certificate expired for api.production.internal",
                "Data corruption detected in table orders"
            ]
        }
        while True:
            roll = random.randint(1, 100)
            if roll <= ERROR_RATE:
                if roll <= 2:
                    level = "critical"
                elif roll <= 8:
                    level = "error"
                else:
                    level = "warning"
            else:
                level = "info"
            msg = random.choice(messages[level])
            log(level, msg)
            time.sleep(random.uniform(1, 5))

    if __name__ == "__main__":
        import threading
        t = threading.Thread(target=background_logs, daemon=True)
        t.start()
        log("info", "Error generator started - HTTP server on port 8080")
        HTTPServer(("0.0.0.0", 8080), HealthHandler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: error-generator
  namespace: demo-alerts
spec:
  replicas: 2
  selector:
    matchLabels:
      app: error-generator
  template:
    metadata:
      labels:
        app: error-generator
    spec:
      containers:
        - name: app
          image: registry.access.redhat.com/ubi9/python-311:latest
          command: ["python", "/app/app.py"]
          env:
            - name: ERROR_RATE
              value: "30"
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
          volumeMounts:
            - name: app-script
              mountPath: /app
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
      volumes:
        - name: app-script
          configMap:
            name: error-generator-script
---
apiVersion: v1
kind: Service
metadata:
  name: error-generator
  namespace: demo-alerts
spec:
  selector:
    app: error-generator
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: error-generator
  namespace: demo-alerts
spec:
  to:
    kind: Service
    name: error-generator
  port:
    targetPort: 8080
EOF
```

Validar:
```bash
oc get pods -n demo-alerts
# Ambos os pods devem estar Running

# Ver os logs sendo gerados
oc logs -n demo-alerts -l app=error-generator --tail=10

# Disparar um burst de erros manualmente (para testar alertas)
ROUTE=$(oc get route error-generator -n demo-alerts -o jsonpath='{.spec.host}')
curl http://$ROUTE/error-burst
```

### 5.2 Habilitar o Ruler do Loki

O LokiStack `1x.extra-small` nao habilita o ruler por padrao. Sem ele, as AlertingRules do Loki nao sao avaliadas. Cada ruler pede 1 CPU + 2Gi RAM (2 replicas).

```bash
oc patch lokistack logging-loki -n openshift-logging --type merge -p '{
  "spec": {
    "rules": {
      "enabled": true,
      "selector": {
        "matchLabels": null
      },
      "namespaceSelector": {
        "matchLabels": null
      }
    }
  }
}'

# Verificar se os pods subiram
oc get pods -n openshift-logging -l app.kubernetes.io/component=ruler
# Ambos devem estar Running
```

> **Nota:** Se os pods ficarem Pending por falta de recursos, sera necessario aumentar CPU/RAM nos nodes (como feito na secao 2.5).

### 5.3 Criar Alertas baseados em Logs (Loki AlertingRule)

```bash
cat <<'EOF' | oc apply -f -
apiVersion: loki.grafana.com/v1
kind: AlertingRule
metadata:
  name: error-generator-alerts
  namespace: demo-alerts
  labels:
    openshift.io/cluster-monitoring: "true"
spec:
  tenantID: application
  groups:
    - name: error-generator-log-alerts
      interval: 1m
      rules:
        - alert: HighErrorRate
          expr: |
            sum(count_over_time({kubernetes_namespace_name="demo-alerts"} |= "error" [5m])) > 10
          for: 2m
          labels:
            severity: warning
            app: error-generator
          annotations:
            summary: "Alta taxa de erros na app error-generator"
            description: "Mais de 10 logs de erro nos ultimos 5 minutos."

        - alert: CriticalLogDetected
          expr: |
            count_over_time({kubernetes_namespace_name="demo-alerts"} |= "critical" [5m]) > 0
          for: 1m
          labels:
            severity: critical
            app: error-generator
          annotations:
            summary: "Log CRITICAL detectado na app error-generator"
            description: "Pelo menos um log de nivel critical foi registrado nos ultimos 5 minutos."

        - alert: ErrorBurstDetected
          expr: |
            sum(count_over_time({kubernetes_namespace_name="demo-alerts"} |= "ERROR BURST" [2m])) > 20
          for: 1m
          labels:
            severity: critical
            app: error-generator
          annotations:
            summary: "Burst de erros detectado"
            description: "Mais de 20 logs de ERROR BURST em 2 minutos - possivel falha massiva."
EOF
```

### 5.4 Criar Alertas baseados em Metricas (PrometheusRule)

```bash
cat <<'EOF' | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: error-generator-metrics-alerts
  namespace: demo-alerts
  labels:
    openshift.io/cluster-monitoring: "true"
spec:
  groups:
    - name: error-generator-pod-alerts
      rules:
        - alert: PodCrashLooping
          expr: |
            increase(kube_pod_container_status_restarts_total{namespace="demo-alerts", container="app"}[10m]) > 2
          for: 1m
          labels:
            severity: critical
            app: error-generator
          annotations:
            summary: "Pod em CrashLoopBackOff"
            description: "O pod {{ $labels.pod }} reiniciou mais de 2 vezes nos ultimos 10 minutos."

        - alert: PodHighMemory
          expr: |
            container_memory_working_set_bytes{namespace="demo-alerts", container="app"} / container_spec_memory_limit_bytes{namespace="demo-alerts", container="app"} > 0.8
          for: 5m
          labels:
            severity: warning
            app: error-generator
          annotations:
            summary: "Pod usando mais de 80% da memoria"
            description: "O pod {{ $labels.pod }} esta usando {{ $value | humanizePercentage }} da memoria limite."
EOF
```

Validar:
```bash
oc get alertingrules -n demo-alerts
oc get prometheusrules -n demo-alerts

# Verificar no console: Observe -> Alerting -> Alerting Rules
```

### 5.5 Configurar Alertmanager - Email, Discord e Slack

Para configurar os receivers, primeiro pegue a configuracao atual:

```bash
oc -n openshift-monitoring get secret alertmanager-main \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d > /tmp/alertmanager.yaml
```

Substitua o conteudo de `/tmp/alertmanager.yaml` com a configuracao abaixo, ajustando seus dados:

```yaml
global:
  resolve_timeout: 5m
  # Configuracao SMTP para envio de emails
  smtp_smarthost: "smtp.gmail.com:587"
  smtp_from: "seu-email@gmail.com"
  smtp_auth_username: "seu-email@gmail.com"
  smtp_auth_password: "sua-app-password"    # Use App Password do Gmail, nao a senha normal
  smtp_require_tls: true

route:
  receiver: default
  group_by: ['namespace', 'alertname', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # Alertas criticos -> todos os canais
    - receiver: all-channels
      matchers:
        - severity = "critical"
      continue: false

    # Alertas warning -> apenas email e slack
    - receiver: email-slack
      matchers:
        - severity = "warning"
      continue: false

receivers:
  - name: default
    email_configs:
      - to: "seu-email@gmail.com"

  - name: all-channels
    email_configs:
      - to: "equipe@empresa.com"
        send_resolved: true
        headers:
          Subject: '[OCP CRITICAL] {{ .GroupLabels.alertname }}'

    slack_configs:
      - api_url: "https://hooks.slack.com/services/TXXXXX/BXXXXX/XXXXXXX"
        channel: "#alertas-ocp"
        send_resolved: true
        title: '{{ if eq .Status "firing" }}🔴{{ else }}🟢{{ end }} [{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
        text: >-
          *Severity:* {{ .CommonLabels.severity }}
          *Namespace:* {{ .CommonLabels.namespace }}
          *Description:* {{ (index .Alerts 0).Annotations.description }}

    webhook_configs:
      # Discord via webhook
      - url: "https://discord.com/api/webhooks/SEU_WEBHOOK_ID/SEU_WEBHOOK_TOKEN"
        send_resolved: true

  - name: email-slack
    email_configs:
      - to: "equipe@empresa.com"
        send_resolved: true
        headers:
          Subject: '[OCP WARNING] {{ .GroupLabels.alertname }}'

    slack_configs:
      - api_url: "https://hooks.slack.com/services/TXXXXX/BXXXXX/XXXXXXX"
        channel: "#alertas-ocp"
        send_resolved: true
        title: '{{ if eq .Status "firing" }}🟡{{ else }}🟢{{ end }} [{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
        text: >-
          *Severity:* {{ .CommonLabels.severity }}
          *Namespace:* {{ .CommonLabels.namespace }}
          *Description:* {{ (index .Alerts 0).Annotations.description }}
```

> **Nota sobre Discord:** O Alertmanager nao tem suporte nativo a Discord, mas o webhook do Discord aceita o formato do Alertmanager diretamente. Para mensagens mais formatadas, use um proxy como o [alertmanager-discord](https://github.com/benjojo/alertmanager-discord):
>
> ```bash
> # Opcao 1: Webhook direto (mensagens simples, funciona mas formato basico)
> # Use a URL: https://discord.com/api/webhooks/ID/TOKEN
>
> # Opcao 2: Proxy para mensagens formatadas (recomendado)
> cat <<'PROXY' | oc apply -n openshift-monitoring -f -
> apiVersion: apps/v1
> kind: Deployment
> metadata:
>   name: alertmanager-discord
>   namespace: openshift-monitoring
> spec:
>   replicas: 1
>   selector:
>     matchLabels:
>       app: alertmanager-discord
>   template:
>     metadata:
>       labels:
>         app: alertmanager-discord
>     spec:
>       containers:
>         - name: alertmanager-discord
>           image: docker.io/benjojo/alertmanager-discord:latest
>           env:
>             - name: DISCORD_WEBHOOK
>               value: "https://discord.com/api/webhooks/SEU_WEBHOOK_ID/SEU_WEBHOOK_TOKEN"
>           ports:
>             - containerPort: 9094
> ---
> apiVersion: v1
> kind: Service
> metadata:
>   name: alertmanager-discord
>   namespace: openshift-monitoring
> spec:
>   selector:
>     app: alertmanager-discord
>   ports:
>     - port: 9094
>       targetPort: 9094
> PROXY
> ```
>
> Com o proxy, use esta URL no webhook_configs:
> `http://alertmanager-discord.openshift-monitoring.svc.cluster.local:9094`

Aplicar a configuracao:

```bash
oc -n openshift-monitoring create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=/tmp/alertmanager.yaml \
  --dry-run=client -o yaml | oc apply -f -
```

### 5.6 Como obter os Webhooks

**Slack:**
1. Acessar https://api.slack.com/apps → Create New App → From Scratch
2. Incoming Webhooks → Ativar → Add New Webhook to Workspace
3. Selecionar o canal → copiar a URL `https://hooks.slack.com/services/T.../B.../...`

**Discord:**
1. No servidor Discord → Configuracoes do Canal → Integracoes → Webhooks
2. Novo Webhook → Copiar URL do Webhook
3. A URL tem o formato: `https://discord.com/api/webhooks/ID/TOKEN`

**Gmail (App Password):**
1. Acessar https://myaccount.google.com/apppasswords
2. Criar uma App Password para "Mail"
3. Usar essa senha (16 caracteres) no campo `smtp_auth_password`, nao a senha normal da conta

### 5.7 Testar os Alertas

```bash
# Pegar a URL da app
ROUTE=$(oc get route error-generator -n demo-alerts -o jsonpath='{.spec.host}')

# Teste 1: Gerar burst de erros (dispara HighErrorRate e ErrorBurstDetected)
curl http://$ROUTE/error-burst

# Teste 2: Simular crash do pod (dispara PodCrashLooping)
curl http://$ROUTE/crash

# Teste 3: Esperar ~5 minutos e verificar os alertas
# Console: Observe -> Alerting -> Alerts
# Verificar se as notificacoes chegaram no email/slack/discord
```

Verificar o estado dos alertas:
```bash
# Ver alertas ativos
oc exec -n openshift-monitoring statefulset/alertmanager-main -- \
  amtool alert query --alertmanager.url=http://localhost:9093

# Ver configuracao do alertmanager
oc exec -n openshift-monitoring statefulset/alertmanager-main -- \
  amtool config show --alertmanager.url=http://localhost:9093
```

---

## Notas Importantes

1. O operador DNS esta em modo `Unmanaged` para manter o fix do CoreDNS. Em caso de upgrade futuro, voltar para `Managed`, fazer upgrade, e reaplicar.
2. O fix do CoreDNS tem 2 partes: (a) NXDOMAIN para `*.cluster.local.ocp.177.54.151.49.sslip.io` (fix da console) e (b) NXDOMAIN para `*.ocp.177.54.151.49.sslip.io` com excecao de `apps/api/api-int` (fix para servicos externos como Slack, Gmail, Discord).
3. O LVMS exclui masters via `nodeSelector` (masters nao tem disco extra).
4. O LokiStack `1x.extra-small` e adequado para lab mas consome recursos significativos (ingester: 2 CPU + 8Gi RAM, ruler: 1 CPU + 2Gi RAM por replica).
5. Os logs sao armazenados no S3 (`atn-bucket-teste`). O storage local (LVMS) e usado apenas para cache/WAL do Loki.
6. O ruler do Loki precisa ser habilitado manualmente (secao 5.2) e requer recursos adicionais nos nodes.
