# Use the existing Azure resources
resource "azurerm_resource_group" "homelab_rg" {
  name     = "homelab-rg"
  location = "southindia"
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

data "azurerm_ssh_public_key" "existing_ssh" {
  name                = "homelab-vm-ssh-key-2"
  resource_group_name = "do-not-delete"
}

resource "azurerm_public_ip" "vm_public_ip" {
  name                = "homelab-vm-public-ip"
  location            = azurerm_resource_group.homelab_rg.location
  resource_group_name = azurerm_resource_group.homelab_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "vm_nic" {
  name                = "homelab-vm-nic"
  location            = azurerm_resource_group.homelab_rg.location
  resource_group_name = azurerm_resource_group.homelab_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.homelab_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_public_ip.id
  }
}

resource "azurerm_network_interface_security_group_association" "vm_nsg_assoc" {
  network_interface_id      = azurerm_network_interface.vm_nic.id
  network_security_group_id = azurerm_network_security_group.homelab_nsg.id
}

resource "azurerm_linux_virtual_machine" "homelab_vm" {
  name                = "homelab-vm"
  location            = azurerm_resource_group.homelab_rg.location
  resource_group_name = azurerm_resource_group.homelab_rg.name
  size                = "Standard_B2s" # Cost-effective for homelabs
  admin_username      = "azureuser"

  network_interface_ids = [azurerm_network_interface.vm_nic.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = data.azurerm_ssh_public_key.existing_ssh.public_key
  }

  disable_password_authentication = true # Enforce SSH key-based authentication

  os_disk {
    name                 = "homelab-vm-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  custom_data = filebase64("cloud-init.yaml")

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}


