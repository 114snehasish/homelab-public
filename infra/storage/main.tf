terraform {
  required_version = ">= 1.9.0"

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
  # checkov:skip=CKV_AZURE_93:Customer-managed key encryption needs a Key Vault, which lands in E05 (#18)
  # checkov:skip=CKV_AZURE_251:No disk export/Private Link scenario in this architecture; the disk is attached directly to compute/vm and never accessed independently
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
