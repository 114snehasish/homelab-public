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
