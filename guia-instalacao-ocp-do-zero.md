# Guia de Instalação — OpenShift Container Platform (Do Zero)

**Topologia:** 3 masters · 2 workers · 2 infra  
**Método:** UPI (User Provisioned Infrastructure)  
**Infraestrutura:** Proxmox VE  
**DNS:** dnsmasq no bastion (sem servidor DNS externo)  
**Acesso externo:** 1 IP público → Ingress/rotas (via sslip.io como baseDomain)  
**Objetivo:** Aprendizado — instalação completa e configuração pós-instalação  
**Data de criação:** 2026-04-13  

---

## Sumário

1. [Arquitetura do Cenário](#1-arquitetura-do-cenário)
2. [Rede no Proxmox](#2-rede-no-proxmox)
3. [Criação das VMs no Proxmox](#3-criação-das-vms-no-proxmox)
4. [Configuração do Bastion como Gateway NAT](#4-configuração-do-bastion-como-gateway-nat)
5. [Configuração de DNS com dnsmasq](#5-configuração-de-dns-com-dnsmasq)
6. [Configuração do Load Balancer (HAProxy)](#6-configuração-do-load-balancer-haproxy)
7. [Preparação do Bastion — Ferramentas OCP](#7-preparação-do-bastion--ferramentas-ocp)
8. [Geração dos Manifestos de Instalação](#8-geração-dos-manifestos-de-instalação)
9. [Bootstrap e Instalação do Cluster](#9-bootstrap-e-instalação-do-cluster)
10. [Configuração dos Nodes Infra](#10-configuração-dos-nodes-infra)
11. [Migração de Workloads de Infra](#11-migração-de-workloads-de-infra)
12. [Validação Final do Cluster](#12-validação-final-do-cluster)
13. [Comandos de Referência Rápida](#13-comandos-de-referência-rápida)

---

## 1. Arquitetura do Cenário

### 1.1 Visão geral

```
┌─────────────────────────────────────────────────────────────────┐
│  PROXMOX HOST                                                   │
│                                                                 │
│  vmbr0 (internet/management)     vmbr1 (rede interna cluster)  │
│  SEU_IP_PUBLICO                  192.168.100.0/24              │
│         │                               │                       │
│  ┌──────┴──────────────────────────────┴──────┐               │
│  │  BASTION VM                                 │               │
│  │  eth0: SEU_IP_PUBLICO (ou NAT)             │               │
│  │  eth1: 192.168.100.1 (gateway + DNS + LB)  │               │
│  └─────────────────────────────────────────────┘               │
│                        │ vmbr1                                  │
│          ┌─────────────┼─────────────┐                         │
│          │             │             │                         │
│    [master x3]   [worker x2]   [infra x2]                     │
│    .11/.12/.13   .21/.22        .31/.32                        │
│    (só vmbr1)    (só vmbr1)    (só vmbr1)                      │
└─────────────────────────────────────────────────────────────────┘
```

**Fluxo de acesso externo:**
- `*.apps.ocp.SEU_IP_PUBLICO.sslip.io` → resolve via **sslip.io** para SEU_IP_PUBLICO
  → HAProxy bastion → porta 80/443 → infra nodes
- `api.ocp.SEU_IP_PUBLICO.sslip.io` → HAProxy bastion → porta 6443 → masters

**Por que sslip.io como baseDomain?**  
O `sslip.io` é um serviço DNS público que resolve automaticamente qualquer hostname que
contenha um IP. Exemplo: `algo.192.168.1.5.sslip.io` → `192.168.1.5`. Isso elimina a
necessidade de registrar um domínio ou configurar DNS externo para as rotas de apps.

> Substitua `SEU_IP_PUBLICO` em todo este guia pelo seu IP público real (ex: `203.0.113.50`).

### 1.2 Topologia de Nodes

| Role    | Qtd | IP interno      | Hostname base              |
|---------|-----|-----------------|----------------------------|
| bastion | 1   | 192.168.100.1   | bastion (gateway + DNS + LB)|
| bootstrap| 1  | 192.168.100.10  | bootstrap                  |
| master  | 3   | .11 / .12 / .13 | master-0 / 1 / 2           |
| worker  | 2   | .21 / .22       | worker-0 / 1               |
| infra   | 2   | .31 / .32       | infra-0 / 1                |

> Os nodes RHCOS **não têm acesso direto à internet** — usam o bastion como gateway NAT.

### 1.3 Portas que o bastion precisa escutar

| Porta  | IP               | Direção     | Função                          |
|--------|------------------|-------------|---------------------------------|
| 53     | 192.168.100.1    | interna     | dnsmasq — DNS dos nodes         |
| 80     | SEU_IP_PUBLICO   | externa     | Ingress HTTP                    |
| 443    | SEU_IP_PUBLICO   | externa     | Ingress HTTPS                   |
| 6443   | SEU_IP_PUBLICO   | externa     | API (acesso externo / oc CLI)   |
| 6443   | 192.168.100.1    | interna     | API (acesso dos nodes)          |
| 22623  | 192.168.100.1    | interna     | Machine Config Server           |
| 80     | 192.168.100.1    | interna     | Servidor HTTP — ignition files  |

---

## 2. Rede no Proxmox

### 2.1 Criar a bridge interna `vmbr1`

No host Proxmox, edite `/etc/network/interfaces` e adicione:

```
# Bridge interna para o cluster OCP — sem gateway, sem acesso externo direto
auto vmbr1
iface vmbr1 inet static
    address 192.168.100.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # Sem gateway — o bastion fará NAT para esta rede
```

Aplique sem reiniciar:

```bash
# No host Proxmox
ifreload -a
# ou
ifup vmbr1
```

Verifique:

```bash
ip addr show vmbr1
# deve mostrar 192.168.100.1/24
```

> `vmbr0` continua sendo a bridge de management/internet do Proxmox host (existente).  
> O IP `192.168.100.1` no `vmbr1` é do **host Proxmox**, mas o bastion VM vai ter  
> esse mesmo IP como interface interna — configure apenas um dos dois, ou use `.1` no  
> bastion e outro IP no host se precisar.  
> **Recomendação:** deixe o IP `192.168.100.1/24` no `vmbr1` do bastion VM;  
> no host Proxmox, não atribua IP à vmbr1 (deixe só como bridge).

### 2.2 Bridge corrigida para o host (sem IP no host)

```
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```

Assim, apenas o bastion VM terá o IP `192.168.100.1` nessa rede.

---

## 3. Criação das VMs no Proxmox

### 3.1 Baixar as ISOs necessárias

No host Proxmox, baixe para o storage de ISOs (ex: `/var/lib/vz/template/iso/`):

```bash
# RHCOS — alinha com a versão OCP que você vai instalar
# Acesse: https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.16/latest/
# Baixe o arquivo: rhcos-4.16.x-x86_64-live.x86_64.iso

# RHEL/CentOS Stream 9 — para o bastion
# Baixe: CentOS-Stream-9-latest-x86_64-dvd1.iso
```

### 3.2 Especificações das VMs

| VM          | vCPU | RAM    | Disco  | Bridge(s)         | Boot           |
|-------------|------|--------|--------|-------------------|----------------|
| bastion     | 2    | 4 GB   | 50 GB  | vmbr0 + vmbr1     | ISO CentOS/RHEL|
| bootstrap   | 4    | 8 GB   | 120 GB | vmbr1             | ISO RHCOS      |
| master-0/1/2| 4    | 16 GB  | 120 GB | vmbr1             | ISO RHCOS      |
| worker-0/1  | 2    | 8 GB   | 120 GB | vmbr1             | ISO RHCOS      |
| infra-0/1   | 4    | 16 GB  | 120 GB | vmbr1             | ISO RHCOS      |

> Para lab com poucos recursos: masters podem usar 4 vCPU / 8 GB.

### 3.3 Criar VMs via CLI do Proxmox (qm)

**Exemplo — bastion:**

```bash
# No host Proxmox
VMID=100
qm create $VMID \
  --name bastion \
  --memory 4096 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --net1 virtio,bridge=vmbr1 \
  --scsi0 local-lvm:50 \
  --ide2 local:iso/CentOS-Stream-9-latest-x86_64-dvd1.iso,media=cdrom \
  --boot order=ide2 \
  --ostype l26
qm start $VMID
```

**Exemplo — master-0 (repita para master-1, master-2):**

```bash
VMID=111   # 111=master-0, 112=master-1, 113=master-2
qm create $VMID \
  --name master-0 \
  --memory 16384 \
  --cores 4 \
  --net0 virtio,bridge=vmbr1 \
  --scsi0 local-lvm:120 \
  --ide2 local:iso/rhcos-4.16-live.x86_64.iso,media=cdrom \
  --boot order=ide2 \
  --ostype l26
# NÃO inicie ainda — aguarde a seção de bootstrap
```

**Exemplo — worker-0 / worker-1:**

```bash
VMID=121   # 121=worker-0, 122=worker-1
qm create $VMID \
  --name worker-0 \
  --memory 8192 \
  --cores 2 \
  --net0 virtio,bridge=vmbr1 \
  --scsi0 local-lvm:120 \
  --ide2 local:iso/rhcos-4.16-live.x86_64.iso,media=cdrom \
  --boot order=ide2 \
  --ostype l26
```

**Exemplo — infra-0 / infra-1:**

```bash
VMID=131   # 131=infra-0, 132=infra-1
qm create $VMID \
  --name infra-0 \
  --memory 16384 \
  --cores 4 \
  --net0 virtio,bridge=vmbr1 \
  --scsi0 local-lvm:120 \
  --ide2 local:iso/rhcos-4.16-live.x86_64.iso,media=cdrom \
  --boot order=ide2 \
  --ostype l26
```

### 3.4 Identificar as interfaces de rede nas VMs RHCOS

As VMs RHCOS com `virtio` normalmente enxergam a interface como `ens3` ou `enp6s18`.  
Para confirmar, ao bootar pela ISO RHCOS interativamente, rode:

```bash
ip link
```

Ajuste o nome da interface nos parâmetros de boot na seção 9.

---

## 4. Configuração do Bastion como Gateway NAT

O bastion precisa fazer NAT para que os nodes RHCOS (que só têm interface interna)
consigam acessar a internet — necessário para pull de imagens de container.

### 4.1 Instalar o bastion (CentOS Stream 9 / RHEL 9)

Instale o SO no bastion via ISO. Configure:
- **eth0** (vmbr0): IP obtido por DHCP ou IP do seu ambiente de management
- **eth1** (vmbr1): IP estático `192.168.100.1/24` — gateway da rede interna

```bash
# Configurar eth1 com IP estático no bastion
sudo nmcli con add type ethernet con-name eth1-internal ifname eth1 \
  ip4 192.168.100.1/24

sudo nmcli con up eth1-internal
```

### 4.2 Ativar IP forwarding e NAT

```bash
# Habilitar IP forwarding permanentemente
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-ip-forward.conf
sudo sysctl -p /etc/sysctl.d/99-ip-forward.conf

# Configurar NAT (masquerade) — substitua eth0 pela interface com saída para internet
sudo firewall-cmd --permanent --zone=external --add-masquerade
sudo firewall-cmd --permanent --zone=external --add-interface=eth0
sudo firewall-cmd --permanent --zone=internal --add-interface=eth1
sudo firewall-cmd --permanent --zone=internal --add-source=192.168.100.0/24
sudo firewall-cmd --reload

# Verificar
sudo firewall-cmd --zone=external --query-masquerade
# deve retornar: yes
```

### 4.3 Validar conectividade após NAT

De um node RHCOS (após iniciar com ignition), valide:

```bash
# Do node — deve chegar na internet via bastion
curl -s https://registry.redhat.io -o /dev/null -w "%{http_code}\n"
```

---

## 5. Configuração de DNS com dnsmasq

O `dnsmasq` resolve **todos** os nomes do cluster internamente.  
Os nodes RHCOS são configurados para usar `192.168.100.1` (bastion) como DNS.

### 5.1 Instalar dnsmasq

```bash
# No bastion
sudo dnf install -y dnsmasq
```

### 5.2 Criar o arquivo de configuração

> Substitua `SEU_IP_PUBLICO` pelo IP público real em todo o bloco abaixo.  
> Exemplo: se seu IP é `203.0.113.50`, o domínio será `ocp.203.0.113.50.sslip.io`

**`/etc/dnsmasq.d/ocp-cluster.conf`:**

```ini
# Interface de escuta — apenas rede interna
interface=eth1
bind-interfaces

# Não usar resolv.conf do host para forward — upstream explícito
no-resolv

# Servidores upstream para nomes não resolvidos localmente
server=8.8.8.8
server=1.1.1.1

# Domínio local do cluster
domain=ocp.SEU_IP_PUBLICO.sslip.io

# ──────────────────────────────────────────────────
# API — resolve para o bastion (HAProxy interno)
# ──────────────────────────────────────────────────
address=/api.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.1
address=/api-int.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.1

# ──────────────────────────────────────────────────
# Apps wildcard — resolve internamente para o bastion
# (HAProxy redireciona para infra nodes na porta 80/443)
# ──────────────────────────────────────────────────
address=/.apps.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.1

# ──────────────────────────────────────────────────
# Nodes individuais
# ──────────────────────────────────────────────────
address=/bootstrap.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.10
address=/master-0.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.11
address=/master-1.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.12
address=/master-2.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.13
address=/worker-0.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.21
address=/worker-1.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.22
address=/infra-0.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.31
address=/infra-1.ocp.SEU_IP_PUBLICO.sslip.io/192.168.100.32

# ──────────────────────────────────────────────────
# Registros PTR (reverse DNS) — obrigatório para OCP
# ──────────────────────────────────────────────────
ptr-record=10.100.168.192.in-addr.arpa,bootstrap.ocp.SEU_IP_PUBLICO.sslip.io
ptr-record=11.100.168.192.in-addr.arpa,master-0.ocp.SEU_IP_PUBLICO.sslip.io
ptr-record=12.100.168.192.in-addr.arpa,master-1.ocp.SEU_IP_PUBLICO.sslip.io
ptr-record=13.100.168.192.in-addr.arpa,master-2.ocp.SEU_IP_PUBLICO.sslip.io
ptr-record=21.100.168.192.in-addr.arpa,worker-0.ocp.SEU_IP_PUBLICO.sslip.io
ptr-record=22.100.168.192.in-addr.arpa,worker-1.ocp.SEU_IP_PUBLICO.sslip.io
ptr-record=31.100.168.192.in-addr.arpa,infra-0.ocp.SEU_IP_PUBLICO.sslip.io
ptr-record=32.100.168.192.in-addr.arpa,infra-1.ocp.SEU_IP_PUBLICO.sslip.io

# Log de queries (útil para debug — comente em produção)
log-queries
log-facility=/var/log/dnsmasq.log
```

### 5.3 Ativar o dnsmasq

```bash
sudo systemctl enable --now dnsmasq

# Abrir DNS apenas na interface interna
sudo firewall-cmd --zone=internal --add-service=dns --permanent
sudo firewall-cmd --reload

# Verificar
sudo systemctl status dnsmasq
```

### 5.4 Validar o DNS do bastion

```bash
# Instalar dig
sudo dnf install -y bind-utils

# Forward
dig @192.168.100.1 api.ocp.SEU_IP_PUBLICO.sslip.io +short
# deve retornar: 192.168.100.1

dig @192.168.100.1 api-int.ocp.SEU_IP_PUBLICO.sslip.io +short
# deve retornar: 192.168.100.1

dig @192.168.100.1 console-openshift-console.apps.ocp.SEU_IP_PUBLICO.sslip.io +short
# deve retornar: 192.168.100.1

dig @192.168.100.1 master-0.ocp.SEU_IP_PUBLICO.sslip.io +short
# deve retornar: 192.168.100.11

# Reverse
dig @192.168.100.1 -x 192.168.100.11 +short
# deve retornar: master-0.ocp.SEU_IP_PUBLICO.sslip.io.

# Upstream (internet) — confirma que o forward para 8.8.8.8 funciona
dig @192.168.100.1 registry.redhat.io +short
```

---

## 6. Configuração do Load Balancer (HAProxy)

O HAProxy roda no bastion e serve dois propósitos:
- **Rede interna (192.168.100.1):** API + MCS para os nodes do cluster
- **IP público (SEU_IP_PUBLICO):** Ingress HTTP/HTTPS + API para acesso externo

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
# API — porta 6443
# Bind em TODAS as interfaces: acesso externo (oc CLI) e interno (nodes)
#---------------------------------------------------------------------
frontend api_frontend
    bind *:6443
    default_backend api_backend

backend api_backend
    balance roundrobin
    option tcp-check
    server bootstrap  192.168.100.10:6443  check
    server master-0   192.168.100.11:6443  check
    server master-1   192.168.100.12:6443  check
    server master-2   192.168.100.13:6443  check

#---------------------------------------------------------------------
# Machine Config Server — porta 22623
# Apenas rede interna (nodes precisam baixar config durante boot)
#---------------------------------------------------------------------
frontend mcs_frontend
    bind 192.168.100.1:22623
    default_backend mcs_backend

backend mcs_backend
    balance roundrobin
    option tcp-check
    server bootstrap  192.168.100.10:22623 check
    server master-0   192.168.100.11:22623 check
    server master-1   192.168.100.12:22623 check
    server master-2   192.168.100.13:22623 check

#---------------------------------------------------------------------
# Ingress HTTP — porta 80
# Bind em TODAS as interfaces: IP público recebe e encaminha para infra
#---------------------------------------------------------------------
frontend ingress_http_frontend
    bind *:80
    default_backend ingress_http_backend

backend ingress_http_backend
    balance roundrobin
    option tcp-check
    server infra-0  192.168.100.31:80  check
    server infra-1  192.168.100.32:80  check

#---------------------------------------------------------------------
# Ingress HTTPS — porta 443
# Bind em TODAS as interfaces: IP público recebe e encaminha para infra
#---------------------------------------------------------------------
frontend ingress_https_frontend
    bind *:443
    default_backend ingress_https_backend

backend ingress_https_backend
    balance roundrobin
    option tcp-check
    server infra-0  192.168.100.31:443 check
    server infra-1  192.168.100.32:443 check
```

```bash
# Verificar sintaxe
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# Habilitar e iniciar
sudo systemctl enable --now haproxy

# Abrir portas no firewall — zona externa (IP público)
sudo firewall-cmd --zone=external --add-port={6443,80,443}/tcp --permanent
# Abrir MCS apenas na zona interna
sudo firewall-cmd --zone=internal --add-port=22623/tcp --permanent
sudo firewall-cmd --reload

# Verificar se está escutando
ss -tlnp | grep -E "6443|22623|:80|:443"
```

---

## 7. Preparação do Bastion — Ferramentas OCP

### 7.1 Baixar o instalador e oc CLI

```bash
# Acesse: https://console.redhat.com/openshift/install
# Selecione: Bare Metal > User-provisioned infrastructure
# Baixe: openshift-install-linux.tar.gz e openshift-client-linux.tar.gz

tar -xvf openshift-install-linux.tar.gz
tar -xvf openshift-client-linux.tar.gz

sudo mv oc kubectl openshift-install /usr/local/bin/
sudo chmod +x /usr/local/bin/{oc,kubectl,openshift-install}

# Verificar — versões devem coincidir
oc version --client
openshift-install version
```

### 7.2 Criar diretório de instalação e gerar chave SSH

```bash
mkdir ~/ocp-install
cd ~/ocp-install

ssh-keygen -t ed25519 -N '' -f ~/.ssh/ocp_id_ed25519
echo "Chave pública:"
cat ~/.ssh/ocp_id_ed25519.pub
```

### 7.3 Obter o Pull Secret

1. Acesse: https://console.redhat.com/openshift/install
2. Copie ou baixe o **pull secret**
3. Salve em `~/ocp-install/pull-secret.txt`

### 7.4 Servidor HTTP para os arquivos Ignition

```bash
sudo dnf install -y httpd
sudo systemctl enable --now httpd

# Abrir porta 80 na zona interna (nodes precisam baixar ignition)
sudo firewall-cmd --zone=internal --add-service=http --permanent
sudo firewall-cmd --reload
```

---

## 8. Geração dos Manifestos de Instalação

### 8.1 Criar o `install-config.yaml`

> Substitua `SEU_IP_PUBLICO` pelo IP público real.

```yaml
# ~/ocp-install/install-config.yaml
apiVersion: v1
baseDomain: SEU_IP_PUBLICO.sslip.io      # ex: 203.0.113.50.sslip.io
metadata:
  name: ocp                               # cluster name → ocp.SEU_IP_PUBLICO.sslip.io

compute:
  - architecture: amd64
    hyperthreading: Enabled
    name: worker
    replicas: 0                           # UPI: workers criados manualmente

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
    - cidr: 192.168.100.0/24             # rede interna dos nodes no Proxmox
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16

platform:
  none: {}                                # UPI obrigatório

fips: false

pullSecret: '<COLE_SEU_PULL_SECRET_AQUI>'

sshKey: '<COLE_SUA_CHAVE_PUBLICA_SSH_AQUI>'
```

### 8.2 Backup e geração dos manifestos

```bash
cd ~/ocp-install

# Backup obrigatório — o instalador consome e apaga o install-config.yaml
cp install-config.yaml install-config.yaml.bak

# Gerar manifestos
openshift-install create manifests --dir ~/ocp-install/

# Remover MachineSet de workers automáticos (UPI = provisionamento manual)
rm -f ~/ocp-install/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

# Gerar arquivos Ignition
openshift-install create ignition-configs --dir ~/ocp-install/

ls -lh ~/ocp-install/
# bootstrap.ign  master.ign  worker.ign  auth/
```

### 8.3 Publicar os Ignition via HTTP

```bash
sudo cp ~/ocp-install/*.ign /var/www/html/
sudo chmod 644 /var/www/html/*.ign
sudo restorecon -Rv /var/www/html/

# Testar
curl http://192.168.100.1/bootstrap.ign | python3 -m json.tool | head -5
```

---

## 9. Bootstrap e Instalação do Cluster

### 9.1 Entender os parâmetros de boot do RHCOS

Ao iniciar cada VM pela ISO do RHCOS, no menu GRUB pressione `e` para editar e adicione
na linha `linux` (após `quiet`):

```
coreos.inst.install_dev=/dev/sda
coreos.inst.ignition_url=http://192.168.100.1/<arquivo>.ign
ip=<IP_NODE>::192.168.100.1:255.255.255.0:<HOSTNAME>:<INTERFACE>:none
nameserver=192.168.100.1
```

> `<INTERFACE>`: geralmente `ens3` ou `enp6s18` em VMs Proxmox com virtio.  
> Confirme antes com `ip link` na ISO live.

### 9.2 Ordem de boot — siga rigorosamente

```
Passo 1: Bootstrap   (bootstrap.ign)
Passo 2: master-0    (master.ign)
Passo 3: master-1    (master.ign)
Passo 4: master-2    (master.ign)
--- aguardar bootstrap completar ---
Passo 5: worker-0    (worker.ign)
Passo 6: worker-1    (worker.ign)
Passo 7: infra-0     (worker.ign)
Passo 8: infra-1     (worker.ign)
```

### 9.3 Parâmetros de boot por node

**Bootstrap:**
```
coreos.inst.install_dev=/dev/sda
coreos.inst.ignition_url=http://192.168.100.1/bootstrap.ign
ip=192.168.100.10::192.168.100.1:255.255.255.0:bootstrap.ocp.SEU_IP_PUBLICO.sslip.io:ens3:none
nameserver=192.168.100.1
```

**master-0:**
```
coreos.inst.install_dev=/dev/sda
coreos.inst.ignition_url=http://192.168.100.1/master.ign
ip=192.168.100.11::192.168.100.1:255.255.255.0:master-0.ocp.SEU_IP_PUBLICO.sslip.io:ens3:none
nameserver=192.168.100.1
```

**master-1:**
```
ip=192.168.100.12::192.168.100.1:255.255.255.0:master-1.ocp.SEU_IP_PUBLICO.sslip.io:ens3:none
```

**master-2:**
```
ip=192.168.100.13::192.168.100.1:255.255.255.0:master-2.ocp.SEU_IP_PUBLICO.sslip.io:ens3:none
```

**worker-0:**
```
coreos.inst.ignition_url=http://192.168.100.1/worker.ign
ip=192.168.100.21::192.168.100.1:255.255.255.0:worker-0.ocp.SEU_IP_PUBLICO.sslip.io:ens3:none
nameserver=192.168.100.1
```

**worker-1:**
```
ip=192.168.100.22::192.168.100.1:255.255.255.0:worker-1.ocp.SEU_IP_PUBLICO.sslip.io:ens3:none
```

**infra-0** (usa worker.ign):
```
coreos.inst.ignition_url=http://192.168.100.1/worker.ign
ip=192.168.100.31::192.168.100.1:255.255.255.0:infra-0.ocp.SEU_IP_PUBLICO.sslip.io:ens3:none
nameserver=192.168.100.1
```

**infra-1:**
```
ip=192.168.100.32::192.168.100.1:255.255.255.0:infra-1.ocp.SEU_IP_PUBLICO.sslip.io:ens3:none
```

### 9.4 Monitorar o bootstrap

```bash
export KUBECONFIG=~/ocp-install/auth/kubeconfig

openshift-install wait-for bootstrap-complete \
  --dir ~/ocp-install/ \
  --log-level=info

# Se travar, inspecione diretamente:
ssh -i ~/.ssh/ocp_id_ed25519 core@192.168.100.10 \
  "journalctl -b -f -u release-image.service -u bootkube.service"
```

> Aguarde a mensagem: `Bootstrap complete! The workers may now be deployed.`  
> O processo leva **15-30 minutos** dependendo da velocidade de download das imagens.

### 9.5 Aprovar os CSRs dos nodes

Após o bootstrap completar e os nodes worker/infra subirem:

```bash
# Listar CSRs
oc get csr

# Aprovar todos de uma vez (execute 2x — há dois rounds de CSRs por node)
oc get csr -o go-template='{{range .items}}{{if not .status.certificate}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
  | xargs oc adm certificate approve

# Verificar nodes
oc get nodes
```

### 9.6 Aguardar instalação completar

```bash
openshift-install wait-for install-complete \
  --dir ~/ocp-install/ \
  --log-level=info
```

Ao finalizar, você receberá:
```
INFO Install complete!
INFO To access the cluster as the system:admin user when using 'oc', run
INFO     export KUBECONFIG=/root/ocp-install/auth/kubeconfig
INFO Access the OpenShift web-console here: https://console-openshift-console.apps.ocp.SEU_IP_PUBLICO.sslip.io
INFO Login to the console with user: kubeadmin, and password: <SENHA>
```

### 9.7 Remover o bootstrap do HAProxy

Após `install-complete`:

```bash
sudo vi /etc/haproxy/haproxy.cfg
# Comente ou remova as linhas do bootstrap nos backends api e mcs:
#   server bootstrap  192.168.100.10:6443  check
#   server bootstrap  192.168.100.10:22623 check

sudo systemctl reload haproxy

# Opcional: desligar a VM do bootstrap
qm stop 110 && qm destroy 110   # ajuste o VMID
```

---

## 10. Configuração dos Nodes Infra

Os nodes **infra** são workers promovidos — recebem label, taint e MachineConfigPool
próprios para isolar os componentes da plataforma das cargas de trabalho.

### 10.1 Criar o MachineConfigPool `infra`

```bash
cat <<'EOF' | oc apply -f -
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
EOF
```

### 10.2 Aplicar labels e taints

```bash
# Aplicar label infra
oc label node infra-0.ocp.SEU_IP_PUBLICO.sslip.io node-role.kubernetes.io/infra=""
oc label node infra-1.ocp.SEU_IP_PUBLICO.sslip.io node-role.kubernetes.io/infra=""

# Remover label worker
oc label node infra-0.ocp.SEU_IP_PUBLICO.sslip.io node-role.kubernetes.io/worker-
oc label node infra-1.ocp.SEU_IP_PUBLICO.sslip.io node-role.kubernetes.io/worker-

# Aplicar taint — impede pods sem toleração de ser agendados nos infra nodes
oc adm taint nodes infra-0.ocp.SEU_IP_PUBLICO.sslip.io node-role.kubernetes.io/infra=:NoSchedule
oc adm taint nodes infra-1.ocp.SEU_IP_PUBLICO.sslip.io node-role.kubernetes.io/infra=:NoSchedule

# Verificar
oc get nodes
# infra-0 e infra-1 devem aparecer com ROLES: infra
```

### 10.3 Aguardar o MachineConfigPool sincronizar

```bash
oc get mcp
# infra deve mostrar MACHINECOUNT: 2, READYMACHINECOUNT: 2
# Aguarde — os nodes infra serão drenados e reiniciados para aplicar as configs
```

---

## 11. Migração de Workloads de Infra

### 11.1 Mover o Ingress Controller (Router)

```bash
oc patch ingresscontroller default \
  -n openshift-ingress-operator \
  --type=merge \
  --patch='
{
  "spec": {
    "replicas": 2,
    "nodePlacement": {
      "nodeSelector": {
        "matchLabels": {
          "node-role.kubernetes.io/infra": ""
        }
      },
      "tolerations": [
        {
          "key": "node-role.kubernetes.io/infra",
          "effect": "NoSchedule",
          "operator": "Exists"
        }
      ]
    }
  }
}'

# Verificar
oc get pods -n openshift-ingress -o wide
# router-default-* devem estar nos infra nodes
```

### 11.2 Mover o Image Registry

```bash
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type=merge \
  --patch='
{
  "spec": {
    "managementState": "Managed",
    "storage": {"emptyDir": {}},
    "nodeSelector": {
      "node-role.kubernetes.io/infra": ""
    },
    "tolerations": [
      {
        "key": "node-role.kubernetes.io/infra",
        "effect": "NoSchedule",
        "operator": "Exists"
      }
    ]
  }
}'

# Verificar
oc get pods -n openshift-image-registry -o wide
```

> `storage: emptyDir` é apenas para lab. Em produção use PVC (NFS, Ceph, etc.) ou S3.

### 11.3 Mover o Monitoring Stack

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
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
EOF

# Acompanhar migração
oc get pods -n openshift-monitoring -o wide -w
```

---

## 12. Validação Final do Cluster

### 12.1 Saúde geral

```bash
export KUBECONFIG=~/ocp-install/auth/kubeconfig

# Todos os nodes devem estar Ready com os roles corretos
oc get nodes -o wide

# Todos os operators devem estar: AVAILABLE=True PROGRESSING=False DEGRADED=False
oc get clusteroperators

# Ver eventos de erro (normal ter alguns no início, mas não devem persistir)
oc get events --all-namespaces --sort-by='.lastTimestamp' | grep -v Normal | tail -20
```

### 12.2 Validar etcd (3 membros saudáveis)

```bash
oc rsh -n openshift-etcd \
  $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) \
  etcdctl endpoint status --cluster -w table
```

### 12.3 Validar acesso externo às rotas

```bash
# Criar app de teste
oc new-project test-app
oc new-app --image=registry.access.redhat.com/ubi9/nginx-120 --name=nginx-test -n test-app
oc expose service nginx-test -n test-app

# Ver a route gerada
oc get route nginx-test -n test-app
# Deve mostrar: nginx-test-test-app.apps.ocp.SEU_IP_PUBLICO.sslip.io

# Testar do seu computador (fora do Proxmox)
curl -I http://nginx-test-test-app.apps.ocp.SEU_IP_PUBLICO.sslip.io
# Esperado: HTTP/1.1 200 OK

# Limpar
oc delete project test-app
```

### 12.4 Verificar distribuição dos componentes de infra

```bash
echo "=== Router ===" && oc get pods -n openshift-ingress -o wide
echo "=== Registry ===" && oc get pods -n openshift-image-registry -o wide
echo "=== Monitoring ===" && oc get pods -n openshift-monitoring -o wide | grep -v "Completed"
```

### 12.5 Configurar Identity Provider (substituir kubeadmin)

```bash
# Criar usuário admin com HTPasswd
htpasswd -c -B -b /tmp/htpasswd admin SuaSenhaForte123!
oc create secret generic htpass-secret \
  --from-file=htpasswd=/tmp/htpasswd \
  -n openshift-config

# Configurar OAuth
cat <<'EOF' | oc apply -f -
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

# Dar cluster-admin ao usuário criado
oc adm policy add-cluster-role-to-user cluster-admin admin

# Testar login
oc login -u admin -p SuaSenhaForte123! \
  https://api.ocp.SEU_IP_PUBLICO.sslip.io:6443

# Após confirmar que admin funciona, remover kubeadmin (opcional)
oc delete secret kubeadmin -n kube-system
```

### 12.6 Checklist final

```
[ ] 7 nodes em Ready (3 master, 2 worker, 2 infra)
[ ] Todos ClusterOperators: AVAILABLE=True, PROGRESSING=False, DEGRADED=False
[ ] etcd: 3 membros healthy
[ ] dnsmasq respondendo na 192.168.100.1
[ ] HAProxy: api:6443, ingress:80/443 operacionais
[ ] Router rodando nos infra nodes
[ ] Registry rodando nos infra nodes
[ ] Monitoring rodando nos infra nodes
[ ] Route de teste acessível externamente via sslip.io
[ ] Console acessível: https://console-openshift-console.apps.ocp.SEU_IP_PUBLICO.sslip.io
[ ] Login com HTPasswd funcionando
[ ] kubeadmin removido (opcional)
```

---

## 13. Comandos de Referência Rápida

```bash
# Exportar kubeconfig
export KUBECONFIG=~/ocp-install/auth/kubeconfig

# Senha do kubeadmin (durante instalação)
cat ~/ocp-install/auth/kubeadmin-password

# Nodes com roles
oc get nodes

# Status dos MachineConfigPools
oc get mcp

# Operators com problema
oc get co | grep -v "True.*False.*False"

# Eventos de erro
oc get events -A --sort-by='.lastTimestamp' | grep -i "error\|fail\|warning" | tail -20

# Debug de um node
oc debug node/infra-0.ocp.SEU_IP_PUBLICO.sslip.io

# Logs de um operator
oc logs -n openshift-ingress-operator deploy/ingress-operator --tail=50 -f

# Ver config atual do MCS aplicado a um node
oc get node master-0.ocp.SEU_IP_PUBLICO.sslip.io \
  -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}'

# Inspecionar logs do dnsmasq no bastion
sudo tail -f /var/log/dnsmasq.log

# Verificar HAProxy stats
echo "show stat" | sudo socat stdio /var/lib/haproxy/stats 2>/dev/null || \
  sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

---

## Notas de Estudo

| Conceito               | O que estudar                                               |
|------------------------|-------------------------------------------------------------|
| **etcd**               | Quorum, backup (`etcdctl snapshot save`), restore, defrag  |
| **MachineConfig**      | MCO, pools, rendered configs, como aplicar mudanças        |
| **Ingress**            | Route types: edge / passthrough / reencrypt, certificados  |
| **SDN (OVN)**          | NetworkPolicy, EgressIP, Multus                            |
| **RBAC**               | ClusterRole, Role, ServiceAccount, RoleBinding             |
| **SCC**                | Security Context Constraints vs. PodSecurityPolicy K8s     |
| **Operators**          | CVO (cluster), OLM (apps), criar operator com SDK          |
| **Storage**            | StorageClass, PVC, PV, CSI drivers, LocalVolume            |
| **Identity Providers** | LDAP, HTPasswd, OIDC (Keycloak, etc.)                      |
| **Updates**            | `oc adm upgrade`, canais, graph, EUS                       |

---

*Guia criado para estudo e laboratório em ambiente Proxmox.*  
*Substitua `SEU_IP_PUBLICO` pelo IP público real antes de iniciar.*
