variable "rg_name" {
  type    = string
  default = "homelab-rg"
}

variable "location" {
  type    = string
  default = "southindia"
}

# The same fleet map compute/vm reads, from the same repo-root fleet.tfvars.
# This module declares only the two attributes it consumes; Terraform silently
# drops the rest (vm_size, data_disk_lun, ...), which is what lets one file
# serve both modules. A misspelled attribute is therefore ignored rather than
# rejected — read the plan.
#
# No default, deliberately: a plan that forgets `-var-file=../fleet.tfvars`
# fails with "No value for required variable" instead of quietly planning to
# delete every disk in the fleet. prevent_destroy would catch that, but failing
# before the plan is better than failing during it.
variable "instances" {
  description = "One entry per compute node, keyed by instance name. Each gets its own persistent data disk."
  type = map(object({
    # null means "${key}-data-disk". The deployed node pins "homelab-data-disk"
    # because that disk already exists under that name and renaming it would be
    # a destroy-and-recreate of the one resource that must never die.
    disk_name    = optional(string)
    disk_size_gb = optional(number, 20)
  }))
}
