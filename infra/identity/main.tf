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
