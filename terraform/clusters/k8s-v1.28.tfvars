# terraform/clusters/k8s-v1.28.tfvars
# Cluster Kubernetes 1.28 — 1 control-plane · 2 workers
# Rede: VLAN 151 · IPs públicos diretos em cada node
#
# Uso:
#   terraform workspace new k8s-v1.28
#   terraform workspace select k8s-v1.28
#   terraform apply -var-file=clusters/k8s-v1.28.tfvars

rhcos_vms = {}
rhcos_iso = ""

vms = {
  # ── Control Plane ──────────────────────────────────────────────────────────
  "k8s-control-plane" = {
    node          = "suhr"
    cores         = 4
    memory        = 8192
    disk          = 80
    vmid          = 1106
    template_vmid = 9998
    ip            = "177.54.151.50/24"
    gateway       = "177.54.151.1"
    bridge        = "vmbr0"
    vlan_id       = 151
  }

  # ── Workers ────────────────────────────────────────────────────────────────
  "k8s-worker-0" = {
    node          = "suhr"
    cores         = 2
    memory        = 4096
    disk          = 80
    vmid          = 1107
    template_vmid = 9998
    ip            = "177.54.151.51/24"
    gateway       = "177.54.151.1"
    bridge        = "vmbr0"
    vlan_id       = 151
  }

  "k8s-worker-1" = {
    node          = "suhr"
    cores         = 2
    memory        = 4096
    disk          = 80
    vmid          = 1108
    template_vmid = 9998
    ip            = "177.54.151.52/24"
    gateway       = "177.54.151.1"
    bridge        = "vmbr0"
    vlan_id       = 151
  }
}
