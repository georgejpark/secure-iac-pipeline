# ---------------------------------------------------------------------------
# Deploy: stage
# Pre-production. Mirrors prod's SECURITY posture; differs only in
# scale. A control absent here is a control never tested.
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
    schema_name = "deploy_stage"
  }
}

variable "pve_endpoint" {
  type        = string
  description = "Proxmox API endpoint"
}

variable "pve_token_id" {
  type        = string
  description = "API token id, e.g. terraform@pve!ci-stage"
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

  environment   = "stage"
  vmid_base     = 311
  replica_count = 1
  cores         = 2
  memory_mb     = 1024
  disk_gb       = 12
  bridge        = "vmbr2"
  subnet_prefix = "10.20.10"
  gateway       = "10.20.10.1"

  start_on_boot = true
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
