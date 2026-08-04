terraform {
  required_version = ">= 1.9.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
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

# Create NS records in Cloudflare delegating the Azure subdomain zone to Azure DNS.
# Provider v5 renamed cloudflare_record -> cloudflare_dns_record and matches DNS
# records by FQDN, so name must be the full delegated zone name, not the "az" label.
resource "cloudflare_dns_record" "ns_delegation" {
  for_each = data.azurerm_dns_zone.homelab.name_servers
  zone_id  = var.cloudflare_zone_id
  name     = var.azure_dns_zone_name
  content  = each.value
  type     = "NS"
  ttl      = 3600
}

# One-time in-place state migration from the v4 resource type. The v5 provider
# ships a MoveState handler for this rename, so state moves with no destroy or
# recreate; this single block covers all for_each instances. Becomes a no-op
# once applied and can be removed in a later cleanup.
moved {
  from = cloudflare_record.ns_delegation
  to   = cloudflare_dns_record.ns_delegation
}
