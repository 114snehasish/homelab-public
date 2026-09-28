# Deliberately NOT `rg_name`, for the reason infra/storage's variable of the same
# name spells out: infra/network and compute/vm both declare `rg_name` meaning
# `homelab-rg`, and a repo-wide TF_VAR_rg_name would silently repoint every one
# of them at once. This module's group is a different group with a different
# lifetime.
#
# Same name, same default and same meaning as infra/identity's variable, which
# reads this account through a data source in that group.
variable "persist_rg_name" {
  description = "Resource group holding the persistence tier: the pet disk (infra/storage) and this backup account. Created out-of-band by scripts/bootstrap-persist-rg.sh and never Terraform-managed itself (ADR-0009 §2)"
  type        = string
  default     = "homelab-persist-rg"
}

variable "location" {
  description = "Azure region. southindia on purpose: co-regional with the pet disk and the VM, so a backup write and a restore read never cross a region (ADR-0009, 2026-09-28 amendment)"
  type        = string
  default     = "southindia"
}

# Committed as a default rather than supplied out of band. A storage account name
# is an identifier, not a credential — public blob access is off and the account
# takes no shared key at all — and `listeninfratfstatesa` is already named in
# CLAUDE.md and in every module's backend.tf. Keeping this one out of the repo
# would buy nothing and cost a repo variable plus a bootstrap step that can be
# forgotten.
#
# Storage account names are globally unique, 3-24 lowercase alphanumerics.
variable "backup_storage_account_name" {
  description = "Storage account holding the restic repository (T2). infra/identity and compute/vm both reference this name"
  type        = string
  default     = "homelabpersistbackupsa"
}

variable "restic_container_name" {
  description = "The one container in that account: the restic repository written by the edge VM. infra/identity scopes the backup identity's data-plane grant to exactly this container"
  type        = string
  default     = "restic"
}
