# terraform/main.tf
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.99"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://hv07.sp02.atena.io:8006"
  api_token = var.proxmox_token
  insecure  = true
}

resource "proxmox_virtual_environment_vm" "vms" {
  for_each  = var.vms
  name      = each.key
  node_name = each.value.node
  vm_id     = each.value.vmid

  clone {
    vm_id        = 9001
    full         = true
    node_name    = each.value.node
    datastore_id = "vz-folder"
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "vz-folder"
    size         = each.value.disk
    interface    = "scsi0"
    discard      = "on"
  }

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  initialization {
    datastore_id = "vz-folder"
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = "192.168.100.1"
      }
    }
    user_account {
      username = "debian"
      keys     = [var.ssh_public_key]
    }
    dns {
      servers = ["8.8.8.8", "1.1.1.1"]
    }
  }

  operating_system {
    type = "l26"
  }

  # Aguardar o agent responder antes de continuar
  timeout_create = 900
}

output "vm_ips" {
  value = { for k, v in var.vms : k => v.ip }
}

# ─────────────────────────────────────────────────────────────────────────────
# Nodes RHCOS — bootstrap, masters, workers, infra
#
# Diferenças em relação ao recurso de clone acima:
#   • Sem bloco clone  → disco em branco, não copia template
#   • Sem bloco initialization → RHCOS usa Ignition, não cloud-init
#   • ISO RHCOS live attachada em ide2 para o primeiro boot
#   • boot_order: tenta o CDROM primeiro; após a instalação o RHCOS
#     remove o entry e sobe pelo disco automaticamente
#   • stop_on_destroy: RHCOS não instala qemu-agent por padrão,
#     então o Terraform não consegue fazer shutdown gracioso
# ─────────────────────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_vm" "rhcos_vms" {
  for_each  = var.rhcos_vms
  name      = each.key
  node_name = each.value.node
  vm_id     = each.value.vmid

  stop_on_destroy = true

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # Disco principal — vazio, será preenchido pelo instalador RHCOS
  disk {
    datastore_id = "vz-folder"
    size         = each.value.disk
    interface    = "scsi0"
    discard      = "on"
  }

  # ISO RHCOS Live — usada apenas no primeiro boot para instalação
  cdrom {
    enabled   = true
    file_id   = var.rhcos_iso
    interface = "ide2"
  }

  # Tenta CDROM primeiro; após instalar e reiniciar, o RHCOS sobe do disco
  boot_order = ["ide2", "scsi0"]

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }
}

output "rhcos_vm_names" {
  description = "VMs RHCOS criadas — acesse cada uma pelo console do Proxmox para o boot inicial com ignition"
  value       = { for k, v in var.rhcos_vms : k => { vmid = v.vmid, ip_planejado = v.ip } }
}