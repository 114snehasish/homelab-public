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

# Data Sources (Lookup existing persistent resources)
data "azurerm_resource_group" "rg" {
  name = var.rg_name
}

data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.rg_name
}

data "azurerm_managed_disk" "data_disk" {
  name                = var.disk_name
  resource_group_name = var.rg_name
}

data "azurerm_ssh_public_key" "existing_ssh" {
  name                = var.ssh_key_name
  resource_group_name = "do-not-delete" # As per original main.tf
}

# Ephemeral Resources
resource "azurerm_public_ip" "vm_public_ip" {
  name                = "${var.instance_name}-public-ip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

data "azurerm_dns_zone" "homelab" {
  name                = var.dns_zone_name
  resource_group_name = var.dns_rg_name
}

resource "azurerm_dns_a_record" "vm_record" {
  name                = var.instance_name
  zone_name           = data.azurerm_dns_zone.homelab.name
  resource_group_name = var.dns_rg_name
  ttl                 = 300
  target_resource_id  = azurerm_public_ip.vm_public_ip.id
}

resource "azurerm_network_interface" "vm_nic" {
  # checkov:skip=CKV_AZURE_119:Public IP is intentional for direct SSH access; removed only after Tailscale zero-trust access lands (E06, #19) per CLAUDE.md's lockout-critical ordering
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = var.ip_configuration_name
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_public_ip.id
  }
}

# The NSG is associated at the subnet layer only, in infra/network
# (azurerm_subnet_network_security_group_association.homelab_nsg_assocs). The
# NIC-level association that used to sit here was removed in #162: ADR-0012
# makes the subnet the single owner of NSG policy, because rules are a property
# of the tier a node sits in, not of the node. A per-node exception is an
# argument for a new tier, not for reinstating NIC-level rules.

resource "azurerm_linux_virtual_machine" "homelab_vm" {
  name                = var.instance_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  # tflint-ignore: azurerm_linux_virtual_machine_retired_size # resize to Standard_B4ms is tracked separately (issue #61, roadmap risk R1: OOM once monitoring/k3s land)
  size           = var.vm_size
  admin_username = var.admin_username

  network_interface_ids = [azurerm_network_interface.vm_nic.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = data.azurerm_ssh_public_key.existing_ssh.public_key
  }

  disable_password_authentication = true
  allow_extension_operations      = false

  os_disk {
    name                 = "${var.instance_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    # Note: OS Disk is ephemeral by default
  }

  custom_data = filebase64(var.cloud_init_file)

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "data_disk_attachment" {
  managed_disk_id    = data.azurerm_managed_disk.data_disk.id
  virtual_machine_id = azurerm_linux_virtual_machine.homelab_vm.id
  lun                = var.data_disk_lun
  caching            = "ReadWrite"
}
