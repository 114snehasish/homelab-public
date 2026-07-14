terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
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
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.homelab_rg.location
  resource_group_name = azurerm_resource_group.homelab_rg.name
}

resource "azurerm_subnet" "homelab_subnet" {
  address_prefixes     = ["10.0.0.0/24"]
  name                 = "homelab-subnet"
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

resource "azurerm_network_security_rule" "allow_ssh" {
  name                        = "Allow-SSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.ssh_source_ip != null ? var.ssh_source_ip : "${chomp(data.http.my_ip.response_body)}/32"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.homelab_rg.name
  network_security_group_name = azurerm_network_security_group.homelab_nsg.name
}

resource "azurerm_subnet_network_security_group_association" "homelab_nsg_assoc" {
  subnet_id                 = azurerm_subnet.homelab_subnet.id
  network_security_group_id = azurerm_network_security_group.homelab_nsg.id
}
