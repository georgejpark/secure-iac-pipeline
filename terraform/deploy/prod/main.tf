# ---------------------------------------------------------------------------
# Deploy: prod
# Production. Two replicas, restart on boot, delete protection on.
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
    schema_name = "deploy_prod"
  }
}

variable "pve_endpoint" {
  type        = string
  description = "Proxmox API endpoint"
}

variable "pve_token_id" {
  type        = string
  description = "API token id, e.g. terraform@pve!ci-prod"
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

  environment   = "prod"
  vmid_base     = 321
  replica_count = 3
  cores         = 2
  memory_mb     = 2048
  disk_gb       = 20
  bridge        = "vmbr3"
  subnet_prefix = "10.30.10"
  gateway       = "10.30.10.1"

  start_on_boot = true
  protect       = true
}

output "container_ids" {
  description = "Proxmox VMIDs of the deployed containers"
  value       = module.workload.container_ids
}

output "hostnames" {
  description = "Hostnames of the deployed containers"
  value       = module.workload.hostnames
}
