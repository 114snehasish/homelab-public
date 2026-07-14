terraform {
  required_version = ">= 1.9.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "azurerm" {
  features {}
}

# Get the Azure DNS Zone to retrieve Name Servers
data "azurerm_dns_zone" "homelab" {
  name                = var.azure_dns_zone_name
  resource_group_name = var.azure_rg_name
}

# Create NS records in Cloudflare for the submodule
resource "cloudflare_record" "ns_delegation" {
  for_each = data.azurerm_dns_zone.homelab.name_servers
  zone_id  = var.cloudflare_zone_id
  name     = "az"
  content  = each.value
  type     = "NS"
  ttl      = 3600
}
