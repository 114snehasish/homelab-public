# --- Names this module PRODUCES ---
#
# Every resource name this module creates derives from instance_name. The
# default reproduces today's deployed names byte-for-byte, so a plan with
# default variables shows no rename and no replacement (E17.3, #162).

variable "instance_name" {
  description = "Name of this compute instance. The NIC, public IP, OS disk and DNS A-record label are all derived from it. Changing it renames — and therefore replaces — every resource in this module."
  type        = string
  default     = "homelab-vm"
}

variable "ip_configuration_name" {
  description = "Name of the NIC's ip_configuration block. Deliberately not derived from instance_name: the name is scoped to its own NIC, so it needs no uniqueness across instances, and changing it would force a NIC (and therefore VM) replacement for no benefit."
  type        = string
  default     = "internal"
}

variable "vm_size" {
  description = "Azure VM size. The resize to Standard_B4ms is tracked in #61 — this variable is what makes it a one-line change."
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "Local admin user created by cloud-init and authorized for the SSH key. cloud-init.yaml also hardcodes this name (chown of /data, docker group), so the two must be changed together."
  type        = string
  default     = "azureuser"
}

variable "data_disk_lun" {
  description = "LUN the persistent data disk is attached at. cloud-init.yaml discovers the disk at /dev/disk/azure/scsi1/lun10, so changing this alone breaks the mount contract — see #99."
  type        = number
  default     = 10
}

variable "cloud_init_file" {
  description = "cloud-init file rendered into custom_data, resolved relative to this module directory. Read with filebase64() and not templatefile() on purpose: the file's $${DISK}1 is a shell expansion that templatefile() would try to interpolate (#99)."
  type        = string
  default     = "cloud-init.yaml"
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

variable "disk_name" {
  type    = string
  default = "homelab-data-disk"
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
