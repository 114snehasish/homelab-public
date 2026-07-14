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

data "azurerm_resource_group" "dns_rg" {
  name = var.rg_name
}

resource "azurerm_dns_zone" "homelab" {
  name                = var.dns_zone_name
  resource_group_name = data.azurerm_resource_group.dns_rg.name
}
