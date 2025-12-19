terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_managed_disk" "homelab_data_disk" {
  name                 = var.disk_name
  location             = var.location
  resource_group_name  = var.rg_name
  storage_account_type = "StandardSSD_LRS" # Cost effective SSD
  create_option        = "Empty"
  disk_size_gb         = var.disk_size_gb

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    environment = "homelab"
    persistence = "true"
  }
}
