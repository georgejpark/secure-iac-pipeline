# ---------------------------------------------------------------------------
# Deploy: dev
# Developer environment. One replica, smallest footprint, no boot
# persistence -- losing it costs an afternoon.
#
# This is the root that ACTUALLY APPLIES. It provisions the application tier as
# LXC containers on Proxmox, onto this environment's own network segment.
#
# State lives in the same Postgres backend as everything else, in its own
# schema, so a deploy and a platform change cannot race each other.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }

  # Partial config. conn_str is supplied at init from the SOPS-encrypted
  # secrets file that only this environment's runner can decrypt.
  backend "pg" {
    schema_name = "deploy_dev"
  }
}

variable "pve_endpoint" {
  type        = string
  description = "Proxmox API endpoint"
}

variable "pve_token_id" {
  type        = string
  description = "API token id, e.g. terraform@pve!ci-dev"
}

variable "pve_token_secret" {
  type        = string
  description = "API token secret, supplied from SOPS at apply time"
  sensitive   = true
}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = "${var.pve_token_id}=${var.pve_token_secret}"
  insecure  = true # lab certificate; a real deployment would trust the CA
}

module "workload" {
  source = "../../modules/workload"

  environment   = "dev"
  vmid_base     = 301
  replica_count = 1
  cores         = 1
  memory_mb     = 512
  disk_gb       = 8
  bridge        = "vmbr1"
  subnet_prefix = "10.10.10"
  gateway       = "10.10.10.1"

  start_on_boot = false
  protect       = false
}

output "container_ids" {
  description = "Proxmox VMIDs of the deployed containers"
  value       = module.workload.container_ids
}

output "hostnames" {
  description = "Hostnames of the deployed containers"
  value       = module.workload.hostnames
}
