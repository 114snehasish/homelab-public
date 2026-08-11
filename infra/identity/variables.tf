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
