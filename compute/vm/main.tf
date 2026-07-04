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

# Data Sources (Lookup existing persistent resources)
data "azurerm_resource_group" "rg" {
  name = var.rg_name
}

data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.rg_name
}

data "azurerm_network_security_group" "nsg" {
  name                = var.nsg_name
  resource_group_name = var.rg_name
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
  name                = "homelab-vm-public-ip"
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
  name                = "homelab-vm"
  zone_name           = data.azurerm_dns_zone.homelab.name
  resource_group_name = var.dns_rg_name
  ttl                 = 300
  target_resource_id  = azurerm_public_ip.vm_public_ip.id
}

resource "azurerm_network_interface" "vm_nic" {
  name                = "homelab-vm-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_public_ip.id
  }
}

resource "azurerm_network_interface_security_group_association" "vm_nsg_assoc" {
  network_interface_id      = azurerm_network_interface.vm_nic.id
  network_security_group_id = data.azurerm_network_security_group.nsg.id
}

resource "azurerm_linux_virtual_machine" "homelab_vm" {
  name                = "homelab-vm"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = "Standard_B2s"
  admin_username      = "azureuser"

  network_interface_ids = [azurerm_network_interface.vm_nic.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = data.azurerm_ssh_public_key.existing_ssh.public_key
  }

  disable_password_authentication = true

  os_disk {
    name                 = "homelab-vm-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    # Note: OS Disk is ephemeral by default
  }

  custom_data = filebase64("cloud-init.yaml")

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
  lun                = 10
  caching            = "ReadWrite"
}
