terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  # GitHub derives the OIDC `sub` claim from the repository that runs the
  # workflow, so this must track the origin remote exactly. A stale value fails
  # the token exchange with "no matching federated identity record found" —
  # an error that never mentions the subject string, so it is worth getting
  # right here rather than debugging it in E02.3 (#35).
  github_repository = "114snehasish/homelab"

  tags = {
    environment = "homelab"
    purpose     = "github-oidc"
  }
}

# Deliberately its own resource group rather than homelab-rg: E02.2 (#34) grants
# this identity Contributor over homelab-rg, and an identity that can delete
# itself is one bad apply away from locking CI out of Azure entirely.
resource "azurerm_resource_group" "homelab_identity_rg" {
  name     = var.identity_rg_name
  location = var.location

  tags = local.tags
}

resource "azurerm_user_assigned_identity" "homelab_github_oidc" {
  name                = var.uami_name
  location            = azurerm_resource_group.homelab_identity_rg.location
  resource_group_name = azurerm_resource_group.homelab_identity_rg.name

  # Control-plane asset, protected for the same reason as the pet disk:
  # recreating it mints a new client_id, which costs a local re-bootstrap *and*
  # an update to the repo variables every workflow authenticates with.
  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

# --- Federated credentials ------------------------------------------------

# Trust for workflow runs on main — this covers the dispatch-gated applies,
# which are always dispatched from main.
resource "azurerm_federated_identity_credential" "homelab_github_main" {
  name                      = "homelab-github-main"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${local.github_repository}:ref:refs/heads/main"
  user_assigned_identity_id = azurerm_user_assigned_identity.homelab_github_oidc.id
}

# Trust for pull_request runs (plan only — _terraform.yml disables apply on
# pull_request events structurally, regardless of the apply input).
resource "azurerm_federated_identity_credential" "homelab_github_pull_request" {
  name                      = "homelab-github-pull-request"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${local.github_repository}:pull_request"
  user_assigned_identity_id = azurerm_user_assigned_identity.homelab_github_oidc.id
}

# --- RBAC (E02.2, #34) ----------------------------------------------------
#
# Everything below is a *grant*: three role assignments, and the read-only
# lookups that locate their scopes. Nothing here creates, modifies or destroys
# a resource outside this module — `listeninfratfstatesa` and the RG
# `do-not-delete` are pre-existing and managed outside this repo, so they are
# only ever read.
#
# The apply that creates these needs Microsoft.Authorization/roleAssignments/write
# (Owner or User Access Administrator) at each scope — Contributor alone cannot
# hand out roles. See docs/oidc_bootstrap.md, step 0.

data "azurerm_resource_group" "homelab" {
  name = var.homelab_rg_name
}

data "azurerm_storage_account" "tfstate" {
  name                = var.state_storage_account_name
  resource_group_name = var.state_storage_rg_name
}

# compute/vm reads this same key by name; the UAMI needs to be able to read it
# there or every VM plan fails on the data source.
data "azurerm_ssh_public_key" "homelab_vm" {
  name                = var.vm_ssh_key_name
  resource_group_name = var.state_storage_rg_name
}

locals {
  # Built by string-append rather than via an azurerm_storage_container data
  # source on purpose: that data source reads the storage *data* plane, and the
  # bootstrap SP is not guaranteed to have blob-level rights on an account it
  # otherwise only manages. Resource-manager calls only, all the way down.
  tfstate_container_scope = "${data.azurerm_storage_account.tfstate.id}/blobServices/default/containers/${var.state_container_name}"
}

# The whole point of the epic: lab resources, one resource group, nothing wider.
#
# Note the limit this implies — a role assignment scoped to an RG is stored on
# that RG and dies with it, and creating an RG is a subscription-level write
# anyway. So CI can manage homelab-rg but could never *recreate* it after a
# deletion. That is acceptable because destroy.yml deliberately never destroys
# infra/network; the break-glass path is a local apply with the SP (roadmap R8).
resource "azurerm_role_assignment" "homelab_rg_contributor" {
  scope                = data.azurerm_resource_group.homelab.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.homelab_github_oidc.principal_id

  # The Entra existence check azurerm runs before assigning is the one that
  # fails with PrincipalNotFound when the principal was created moments earlier
  # and has not replicated yet — i.e. on a re-bootstrap, where this module
  # creates the UAMI and its roles in a single apply. The principal here is
  # always our own UAMI, one resource up, so skipping the check costs nothing.
  skip_service_principal_aad_check = true
}

# State access is data-plane only: read, write and lease (the state lock) the
# blobs in the tfstate container. Deliberately NOT a role on the storage
# account, which would also confer listKeys — the key is a bearer credential
# for every container in the account, which is exactly what OIDC is replacing.
#
# This grant only works if Terraform talks to the backend with Entra auth
# (ARM_USE_AZUREAD=true). Without it the azurerm backend calls listKeys and
# fails in `terraform init`, before anything else runs.
resource "azurerm_role_assignment" "tfstate_blob_contributor" {
  scope                = local.tfstate_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.homelab_github_oidc.principal_id

  skip_service_principal_aad_check = true # same replication-lag reason as above
}

# Scoped to the single SSH key resource, not the RG that holds it: the epic's
# rule is "no rights over do-not-delete beyond state-blob access", and this is
# the narrowest possible exception that keeps compute/vm plannable. It confers
# read on one public key — which is public by construction.
resource "azurerm_role_assignment" "vm_ssh_key_reader" {
  scope                = data.azurerm_ssh_public_key.homelab_vm.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.homelab_github_oidc.principal_id

  skip_service_principal_aad_check = true # same replication-lag reason as above
}
