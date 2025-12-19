terraform {
  backend "azurerm" {
    resource_group_name  = "do-not-delete"
    storage_account_name = "listeninfratfstatesa"
    container_name       = "tfstate"
    key                  = "homelab.storage.tfstate"
  }
}
