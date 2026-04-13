# terraform/variables.tf
variable "proxmox_token" {
  description = "Proxmox API token (ex: k8s-terraform@pam!terraform=<uuid>)"
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Public SSH key for accessing the provisioned VMs"
}

variable "vms" {
  description = "Map of VMs to create via clone (bastion, LBs) — define per cluster in clusters/<name>.tfvars"
  type = map(object({
    node   = string
    cores  = number
    memory = number
    disk   = number
    ip     = string
    vmid   = number
  }))
  default = {}
}

variable "rhcos_vms" {
  description = "Map of RHCOS VMs (bootstrap, masters, workers, infra) — sem clone, sem cloud-init"
  type = map(object({
    node   = string
    cores  = number
    memory = number
    disk   = number
    ip     = string   # apenas documentação — IP é configurado via kernel args no boot
    vmid   = number
  }))
  default = {}
}

variable "rhcos_iso" {
  description = "Caminho da ISO RHCOS no storage do Proxmox (ex: local:iso/rhcos-4.16.1-x86_64-live.x86_64.iso)"
  type        = string
  default     = ""
}