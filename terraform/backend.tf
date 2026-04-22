terraform {
  backend "s3" {
    bucket         = "infra-terraform-state-856467372193-us-east-1-an"
    key            = "proxmox/terraform.tfstate"
    region         = "us-east-1"
    use_lockfile   = true
    encrypt        = true
  }
}
