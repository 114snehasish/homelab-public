terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.1.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "do-not-delete"
    storage_account_name = "listeninfratfstatesa"
    container_name       = "tfstate"
    key                  = "homelab.tfstate"
  }
}

provider "azurerm" {
  features {}
  subscription_id            = "5fc79c15-502a-4bc3-ab63-e9ab6d783ce8"
}
