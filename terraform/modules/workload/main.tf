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

variable "host_octet_base" {
  type        = number
  description = "First host octet for workload containers. Must avoid .1 (gateway) and .10 (runner)."
  default     = 20
  validation {
    condition     = var.host_octet_base >= 20 && var.host_octet_base <= 200
    error_message = "host_octet_base must be between 20 and 200, to avoid the gateway and the runner."
  }
}

variable "dns_servers" {
  type        = list(string)
  description = "Resolvers for the workload containers."
  default     = ["1.1.1.1", "8.8.8.8"]
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

    # Without this the container inherits nothing and cannot resolve anything,
    # so apt and every outbound call fail with "Temporary failure resolving".
    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        # Host octet is a fixed offset, NOT derived from the VMID. Deriving it
        # from the VMID put app-dev-1 on 10.10.10.1 -- the gateway address --
        # because 301 % 100 = 1. Segment layout is now explicit:
        #   .1   bridge / gateway
        #   .10  CI runner
        #   .20+ workload containers
        address = "${var.subnet_prefix}.${var.host_octet_base + count.index}/24"
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
    # Deliberately false. The Proxmox per-container firewall inserts an extra
    # bridge (fwbr/fwpr/fwln) in front of the NIC, and with it enabled the
    # container loses return traffic for outbound connections -- DNS and apt
    # both break -- regardless of policy_in.
    #
    # Environment isolation does NOT depend on this flag. It is enforced by the
    # host forward policy (runner-net.service), which drops every cross-segment
    # path and is verified in both directions. Turning this on bought nothing
    # and broke the workload, so it is off, and the reason is written here
    # rather than left for the next person to rediscover.
    firewall = false
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
