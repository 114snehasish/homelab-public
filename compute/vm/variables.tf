# --- The fleet ---

variable "instances" {
  description = "One entry per compute node, keyed by instance name. The key is the name: the VM, NIC, public IP, OS disk and DNS A-record label all derive from it, so the key `homelab-vm` reproduces the deployed node's names exactly. Adding a node is one entry in fleet.tfvars."
  type = map(object({
    # Azure VM size. The resize to Standard_B4ms is tracked in #61.
    vm_size = optional(string, "Standard_B2s")
    # Local admin created by cloud-init and authorized for the SSH key.
    # cloud-init.yaml also hardcodes this name (chown of /data, docker group),
    # so the two must be changed together.
    admin_username = optional(string, "azureuser")
    # LUN the persistent data disk is attached at. cloud-init.yaml discovers the
    # disk at /dev/disk/azure/scsi1/lun10, so changing this alone breaks the
    # mount contract — see #99.
    data_disk_lun = optional(number, 10)
    # cloud-init file rendered into custom_data, resolved relative to this module
    # directory. Read with filebase64() and not templatefile() on purpose: the
    # file's $${DISK}1 is a shell expansion templatefile() would interpolate (#99).
    cloud_init_file = optional(string, "cloud-init.yaml")
    # Name of the NIC's ip_configuration block. Scoped to its own NIC, so it needs
    # no uniqueness across instances; changing it forces a NIC (and VM) replacement
    # for no benefit.
    ip_configuration_name = optional(string, "internal")
    # Persistent data disk to attach, created by infra/storage from this same map.
    # null means "${key}-data-disk"; the deployed node pins "homelab-data-disk"
    # because that is what already exists.
    disk_name = optional(string)
  }))

  # Deliberately no default. A plan that forgets
  # `-var-file=../../fleet.tfvars` then fails with "No value for required
  # variable" instead of silently planning to destroy every node in the fleet.
  # Terraform drops attributes this module does not declare, which is what lets
  # one fleet.tfvars also feed infra/storage — but it means a misspelled
  # attribute is ignored rather than rejected, so read the plan.
}

# --- Names this module CONSUMES ---

variable "rg_name" {
  type    = string
  default = "homelab-rg"
}

variable "vnet_name" {
  type    = string
  default = "homelab-vnet"
}

variable "subnet_name" {
  type    = string
  default = "homelab-subnet"
}

variable "ssh_key_name" {
  type    = string
  default = "homelab-vm-ssh-key-2"
}

variable "dns_zone_name" {
  description = "The Azure DNS Zone name"
  type        = string
}

variable "dns_rg_name" {
  description = "The Resource Group name where Azure DNS Zone resides"
  type        = string
  default     = "homelab-rg"
}
