# ---------------------------------------------------------------------------
# Module: workload
#
# The application tier, deployed as LXC containers on Proxmox. One definition,
# instantiated three times; the environments differ only in the variables they
# pass, so a control that is on in prod cannot be quietly absent in dev.
#
# The security-relevant attributes here (unprivileged, firewall, protection,
# start_on_boot) are enforced by the custom Checkov policies in
# .checkov/custom_policies/ -- written for this codebase, because Checkov ships
# no Proxmox rules of its own.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment name"
  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

variable "node_name" {
  type        = string
  description = "Proxmox node to deploy onto"
  default     = "pve2"
}

variable "replica_count" {
  type        = number
  description = "Number of application containers. Production runs more than one."
  default     = 1
}

variable "vmid_base" {
  type        = number
  description = "First container ID for this environment"
}

variable "cores" {
  type        = number
  description = "vCPU per container"
  default     = 1
}

variable "memory_mb" {
  type        = number
  description = "Memory per container in MB"
  default     = 512
}

variable "disk_gb" {
  type        = number
  description = "Root disk per container in GB"
  default     = 8
}

variable "bridge" {
  type        = string
  description = "Network bridge for this environment's segment"
}

variable "subnet_prefix" {
  type        = string
  description = "First three octets of this environment's segment"
}

variable "gateway" {
  type        = string
  description = "Default gateway for this environment's segment"
}

variable "start_on_boot" {
  type        = bool
  description = "Restart automatically after a host reboot. Required in production."
  default     = false
}

variable "protect" {
  type        = bool
  description = "Block accidental destruction. Required in production."
  default     = false
}

variable "template" {
  type        = string
  description = "LXC template to deploy"
  default     = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
}

variable "datastore" {
  type        = string
  description = "Storage backing the container root disk"
  default     = "local-zfs"
}

resource "proxmox_virtual_environment_container" "app" {
  count     = var.replica_count
  node_name = var.node_name
  vm_id     = var.vmid_base + count.index

  description = "claims-platform application tier — ${var.environment}"
  tags        = ["claims-platform", var.environment, "terraform"]

  # Required by policy CKV_PVE_1. A privileged container shares the host's
  # user namespace; a root escape inside it is root on the hypervisor.
  unprivileged = true

  # Required in production by policy CKV_PVE_3.
  start_on_boot = var.start_on_boot

  # Required in production by policy CKV_PVE_4. Blocks an accidental destroy.
  protection = var.protect

  started = true

  initialization {
    hostname = "app-${var.environment}-${count.index + 1}"

    ip_config {
      ipv4 {
        address = "${var.subnet_prefix}.${var.vmid_base % 100 + count.index}/24"
        gateway = var.gateway
      }
    }
  }

  operating_system {
    template_file_id = var.template
    type             = "debian"
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.datastore
    size         = var.disk_gb
  }

  network_interface {
    name   = "eth0"
    bridge = var.bridge
    # Required by policy CKV_PVE_2. Without this the container's traffic
    # bypasses the Proxmox firewall entirely.
    firewall = true
  }

  lifecycle {
    ignore_changes = [initialization[0].user_account]
  }
}

output "container_ids" {
  description = "Proxmox VMIDs of the deployed application containers"
  value       = proxmox_virtual_environment_container.app[*].vm_id
}

output "hostnames" {
  description = "Hostnames of the deployed application containers"
  value       = [for c in proxmox_virtual_environment_container.app : c.initialization[0].hostname]
}
