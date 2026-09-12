# Deliberately NOT `rg_name`, and deliberately not just a changed default on it:
# infra/network and compute/vm both declare `rg_name` meaning `homelab-rg`, and
# CLAUDE.md records what a shared TF_VAR_* of that name already did to infra/dns
# under its old name. This module's group is a different group with a different
# lifetime — the pet disk's home, created out-of-band by
# scripts/bootstrap-persist-rg.sh and never Terraform-managed (ADR-0009 §2) — so
# it gets a name of its own, and a future repo-wide TF_VAR_rg_name can never
# silently repoint the one resource that must outlive everything else.
#
# compute/vm declares the same name, same default and same meaning: that module
# looks the disk up by name through a data source, so the two have to agree.
variable "disk_rg_name" {
  description = "Resource group holding the persistent data disks: homelab-persist-rg, created out-of-band and only ever read by Terraform (E15.2, #98)"
  type        = string
  default     = "homelab-persist-rg"
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
# No default, deliberately: a plan that forgets `-var-file=../../fleet.tfvars`
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
