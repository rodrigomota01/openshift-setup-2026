# terraform/clusters/ocp-lab.tfvars
# Cluster OCP — 3 masters · 2 workers · 2 infra · 1 bastion · 1 bootstrap
#
# Uso:
#   terraform workspace new ocp-lab
#   terraform workspace select ocp-lab
#   terraform apply -var-file=clusters/ocp-lab.tfvars
#
# ANTES DE APLICAR:
#   1. Substitua SEU_NODE pelo nome do seu node Proxmox (ex: pve, suhr, proxmox)
#   2. Confirme que a ISO RHCOS foi baixada e o caminho em rhcos_iso está correto
#   3. Confirme que o template vmid 9001 existe (usado pelo bastion)
#   4. Ajuste os VMIDs se houver conflito com VMs existentes

# ─────────────────────────────────────────────────────────────────────────────
# ISO do RHCOS
# Baixe em: https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.16/latest/
# Arquivo: rhcos-4.16.x-x86_64-live.x86_64.iso
# Faça upload no Proxmox em: Datacenter > Storage > local > ISO Images
# ─────────────────────────────────────────────────────────────────────────────
rhcos_iso = "vz-folder:iso/rhcos-4.16.51-x86_64-live.x86_64.iso"

# ─────────────────────────────────────────────────────────────────────────────
# Bastion — usa clone do template (Linux normal, cloud-init funciona)
# IP: 192.168.100.110 (eth1 — configurado manualmente no SO após o clone)
# ─────────────────────────────────────────────────────────────────────────────
vms = {
  "bastion-ocp" = {
    node   = "suhr"
    cores  = 2
    memory = 4096
    disk   = 50
    ip     = "192.168.100.110/24"
    vmid   = 2000
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Nodes RHCOS — sem clone, sem cloud-init
# IPs são apenas documentação aqui; serão configurados via kernel args no boot
#
# Depois de "terraform apply":
#   1. Abra o console de cada VM no Proxmox
#   2. Na tela do GRUB da ISO RHCOS, pressione Tab ou 'e'
#   3. Adicione os parâmetros na linha do kernel (veja o guia)
#   4. Siga a ordem: bootstrap → master-0/1/2 → worker-0/1 → infra-0/1
# ─────────────────────────────────────────────────────────────────────────────
rhcos_vms = {
  # Bootstrap — temporário, destruído após instalação
  "bootstrap" = {
    node   = "suhr"
    cores  = 4
    memory = 8192
    disk   = 120
    ip     = "192.168.100.111/24"
    vmid   = 2001
  }

  # Control Plane (etcd + API Server)
  "master-0" = {
    node   = "suhr"
    cores  = 4
    memory = 16384
    disk   = 120
    ip     = "192.168.100.112/24"
    vmid   = 2011
  }
  "master-1" = {
    node   = "suhr"
    cores  = 4
    memory = 16384
    disk   = 120
    ip     = "192.168.100.113/24"
    vmid   = 2012
  }
  "master-2" = {
    node   = "suhr"
    cores  = 4
    memory = 16384
    disk   = 120
    ip     = "192.168.100.114/24"
    vmid   = 2013
  }

  # Workers — workloads de aplicação
  "worker-0" = {
    node   = "suhr"
    cores  = 2
    memory = 8192
    disk   = 120
    ip     = "192.168.100.115/24"
    vmid   = 2021
  }
  "worker-1" = {
    node   = "suhr"
    cores  = 2
    memory = 8192
    disk   = 120
    ip     = "192.168.100.116/24"
    vmid   = 2022
  }

  # Infra — Ingress Router + Registry + Monitoring
  "infra-0" = {
    node   = "suhr"
    cores  = 4
    memory = 16384
    disk   = 120
    ip     = "192.168.100.117/24"
    vmid   = 2031
  }
  "infra-1" = {
    node   = "suhr"
    cores  = 4
    memory = 16384
    disk   = 120
    ip     = "192.168.100.118/24"
    vmid   = 2032
  }
}
