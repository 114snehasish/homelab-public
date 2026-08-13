terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "homelab_rg" {
  name     = var.rg_name
  location = var.location
}

resource "azurerm_virtual_network" "homelab_vnet" {
  name                = "homelab-vnet"
  address_space       = var.vnet_address_space
  location            = azurerm_resource_group.homelab_rg.location
  resource_group_name = azurerm_resource_group.homelab_rg.name
}

# Subnets are data: adding a tier from ADR-0012's CIDR plan is a var.subnets
# entry, not another resource block.
resource "azurerm_subnet" "homelab_subnets" {
  for_each = var.subnets

  address_prefixes     = each.value.address_prefixes
  name                 = each.key
  resource_group_name  = azurerm_resource_group.homelab_rg.name
  virtual_network_name = azurerm_virtual_network.homelab_vnet.name
}

resource "azurerm_network_security_group" "homelab_nsg" {
  name                = "homelab-nsg-for-vm"
  location            = azurerm_resource_group.homelab_rg.location
  resource_group_name = azurerm_resource_group.homelab_rg.name
}

data "http" "my_ip" {
  url = "https://api.ipify.org"
}

resource "azurerm_network_security_rule" "homelab_nsg_rules" {
  for_each = var.nsg_rules

  name      = each.key
  priority  = each.value.priority
  direction = each.value.direction
  access    = each.value.access
  protocol  = each.value.protocol

  source_port_range      = each.value.source_port_range
  destination_port_range = each.value.destination_port_range

  # An explicit per-rule prefix wins; a rule that omits it (today only
  # Allow-SSH) falls back to var.ssh_source_ip and then to the public IP of
  # whatever machine is planning, which is why local and CI plans always
  # disagree on this one value until #54 removes the ipify lookup.
  source_address_prefix = coalesce(
    each.value.source_address_prefix,
    var.ssh_source_ip,
    "${chomp(data.http.my_ip.response_body)}/32",
  )
  destination_address_prefix = each.value.destination_address_prefix

  resource_group_name         = azurerm_resource_group.homelab_rg.name
  network_security_group_name = azurerm_network_security_group.homelab_nsg.name
}

# ADR-0012: the subnet is the single owner of NSG rules. The NIC-level
# association in compute/vm is removed in #162.
resource "azurerm_subnet_network_security_group_association" "homelab_nsg_assocs" {
  for_each = var.subnets

  subnet_id                 = azurerm_subnet.homelab_subnets[each.key].id
  network_security_group_id = azurerm_network_security_group.homelab_nsg.id
}

# for_each conversion is an address change, which Terraform plans as
# destroy+create without these. infra/network has no prevent_destroy to catch a
# mistake, and destroying the subnet cascades into the VM's NIC — the
# zero-change plan is the only guard. Precedent: infra/cloudflare/main.tf.
moved {
  from = azurerm_subnet.homelab_subnet
  to   = azurerm_subnet.homelab_subnets["homelab-subnet"]
}

moved {
  from = azurerm_network_security_rule.allow_ssh
  to   = azurerm_network_security_rule.homelab_nsg_rules["Allow-SSH"]
}

moved {
  from = azurerm_subnet_network_security_group_association.homelab_nsg_assoc
  to   = azurerm_subnet_network_security_group_association.homelab_nsg_assocs["homelab-subnet"]
}
