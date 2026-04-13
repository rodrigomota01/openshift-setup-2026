# terraform/clusters/atena.tfvars
# Definição das VMs do cluster atena
#
# Uso:
#   terraform workspace new atena
#   terraform workspace select atena
#   terraform apply -var-file=clusters/atena.tfvars

vms = {
  "master-1" = { node = "suhr", cores = 4, memory = 8192,  disk = 80,  ip = "192.168.100.110/24", vmid = 1108 }
  "master-2" = { node = "suhr", cores = 4, memory = 8192,  disk = 80,  ip = "192.168.100.111/24", vmid = 1109 }
  "master-3" = { node = "suhr", cores = 4, memory = 8192,  disk = 80,  ip = "192.168.100.112/24", vmid = 1110 }
  "worker-1" = { node = "suhr", cores = 4, memory = 8192,  disk = 100, ip = "192.168.100.113/24", vmid = 1111 }
  "worker-2" = { node = "suhr", cores = 4, memory = 8192,  disk = 100, ip = "192.168.100.114/24", vmid = 1112 }
  "worker-3" = { node = "suhr", cores = 4, memory = 8192,  disk = 100, ip = "192.168.100.115/24", vmid = 1113 }
  "worker-4" = { node = "suhr", cores = 4, memory = 8192,  disk = 100, ip = "192.168.100.116/24", vmid = 1114 }
  "lb-1"     = { node = "suhr", cores = 2, memory = 2048,  disk = 20,  ip = "192.168.100.117/24", vmid = 1121 }
  "lb-2"     = { node = "suhr", cores = 2, memory = 2048,  disk = 20,  ip = "192.168.100.118/24", vmid = 1122 }
}
