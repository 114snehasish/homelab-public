# Named identity_rg_name rather than rg_name on purpose: infra/network,
# infra/storage and compute/vm all declare a variable called rg_name, and
# CLAUDE.md documents how a static TF_VAR_rg_name would silently override every
# one of them at once. This RG is a different resource group anyway.
variable "identity_rg_name" {
  description = "Resource group holding the CI identity — separate from homelab-rg so E02.2's Contributor grant can never reach it"
  type        = string
  default     = "homelab-identity-rg"
}

variable "location" {
  description = "Azure region for the identity resources"
  type        = string
  default     = "southindia"
}

variable "uami_name" {
  description = "Name of the user-assigned managed identity GitHub Actions federates into"
  type        = string
  default     = "homelab-github-actions-identity"
}

# --- RBAC scope inputs (E02.2, #34) ---------------------------------------
# Same naming caution as identity_rg_name above: none of these may be called
# rg_name. They are looked up by name via data sources, so a rename anywhere
# else in the repo has to be mirrored here — the usual by-name coupling
# documented in CLAUDE.md.

variable "homelab_rg_name" {
  description = "Resource group the CI identity gets Contributor over — the lab's blast radius, created by infra/network"
  type        = string
  default     = "homelab-rg"
}

variable "state_storage_rg_name" {
  description = "Resource group holding the Terraform state storage account and the VM SSH key; pre-existing and managed outside this repo (read-only here)"
  type        = string
  default     = "do-not-delete"
}

variable "state_storage_account_name" {
  description = "Storage account backing every module's remote state"
  type        = string
  default     = "listeninfratfstatesa"
}

variable "state_container_name" {
  description = "Blob container holding the homelab.<module>.tfstate keys — the only container the identity may touch"
  type        = string
  default     = "tfstate"
}

variable "vm_ssh_key_name" {
  description = "SSH public key resource compute/vm reads by name; the identity gets Reader on this one resource only"
  type        = string
  default     = "homelab-vm-ssh-key-2"
}

# --- Edge DNS identity inputs (E03.3, #39) --------------------------------

variable "edge_uami_name" {
  description = "Name of the user-assigned managed identity Caddy uses for the Azure DNS-01 challenge"
  type        = string
  default     = "homelab-edge-dns-identity"
}

# Deliberately no default, same reasoning as compute/vm's variable of the same
# name: _terraform.yml already sets TF_VAR_dns_zone_name for every module (it
# feeds compute/vm and infra/dns today), so this module picks it up for free
# with no workflow change — but a local apply must pass it explicitly.
variable "dns_zone_name" {
  description = "The Azure DNS Zone name Caddy's edge identity gets DNS Zone Contributor over"
  type        = string
}

# --- Persist RG grant inputs (E15.0, #205) --------------------------------
# Same naming caution as every variable above: neither may be called rg_name.
# Unlike the RBAC inputs, this RG is not created by any module in this repo —
# scripts/bootstrap-persist-rg.sh makes it and Terraform only ever reads it
# (ADR-0009 §2).

variable "persist_rg_name" {
  description = "Resource group holding the pet disk, created out-of-band by scripts/bootstrap-persist-rg.sh and never Terraform-managed; read-only here"
  type        = string
  default     = "homelab-persist-rg"
}

variable "persist_disk_role_name" {
  description = "Name of the custom role letting CI create and update managed disks in the persist RG — role names are unique tenant-wide, hence the Homelab prefix"
  type        = string
  default     = "Homelab Persist Disk Writer"
}

# --- Backup identity inputs (E15.4, #100) ---------------------------------
# The account and its container are created by infra/backup, a separate
# local-apply module, and read here by name — the same by-name coupling every
# cross-module reference in this repo uses. Applying infra/backup is therefore a
# prerequisite of applying this module: a role assignment's scope must already
# exist, so a missing account fails at *plan*, the same signal a missing persist
# RG already gives.

variable "backup_storage_account_name" {
  description = "Storage account holding the restic repository, created by infra/backup in the persist RG. Same name, same default and same meaning as that module's variable"
  type        = string
  default     = "homelabpersistbackupsa"
}

variable "restic_container_name" {
  description = "The container the backup identity gets Storage Blob Data Contributor over — never the account, even though that account holds nothing else"
  type        = string
  default     = "restic"
}

variable "backup_uami_name" {
  description = "Name of the user-assigned managed identity restic authenticates as from the edge VM"
  type        = string
  default     = "homelab-backup-identity"
}

# Subscription Owner is a CONTROL-plane role and confers no blob data access, so
# without this grant `restic` and `az storage blob` both fail from a laptop with
# AuthorizationPermissionMismatch — an error naming neither the missing role nor
# the irrelevance of Owner. That is the path #206's disaster-recovery drill and
# #100's "restore from blob alone, no VM" acceptance criterion both run on, so it
# is granted rather than rediscovered.
#
# A variable rather than unconditional because the principal it grants is
# whoever runs the apply (data.azurerm_client_config.current.object_id). That is
# the right answer while this module is applied locally by its owner, and the
# wrong one the day anything else applies it — at which point this is set false
# and the grant made deliberately.
variable "grant_operator_blob_access" {
  description = "Grant the principal running this apply Storage Blob Data Contributor on the restic container, so a human can restore from blob alone"
  type        = bool
  default     = true
}
