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

# One disk per instance, created by infra/storage from the same fleet map. The
# fallback name must match infra/storage's — they are two root modules linked by
# naming convention, not by terraform_remote_state (see CLAUDE.md).
data "azurerm_managed_disk" "data_disk" {
  for_each            = var.instances
  name                = coalesce(each.value.disk_name, "${each.key}-data-disk")
  resource_group_name = var.rg_name
}

data "azurerm_ssh_public_key" "existing_ssh" {
  name                = var.ssh_key_name
  resource_group_name = "do-not-delete" # As per original main.tf
}

# Ephemeral Resources
resource "azurerm_public_ip" "vm_public_ip" {
  for_each            = var.instances
  name                = "${each.key}-public-ip"
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
  for_each            = var.instances
  name                = each.key
  zone_name           = data.azurerm_dns_zone.homelab.name
  resource_group_name = var.dns_rg_name
  ttl                 = 300
  target_resource_id  = azurerm_public_ip.vm_public_ip[each.key].id
}

# The wildcard `*.<zone>` record (#38). It lives here rather than in infra/dns,
# where static records belong by convention, for three reasons:
#
#   1. An alias record needs the public IP's *resource ID*. This module holds it
#      directly; infra/dns would need a data source lookup by name.
#   2. destroy.yml tears this module down routinely (cattle VM, pet disk). That
#      lookup would then fail on every infra/dns plan between deploy cycles —
#      exactly the #124 failure mode.
#   3. Module order runs dns (#2) before compute (#5). A compute-dependent record
#      in infra/dns inverts the dependency.
#
# target_resource_id, not `records = [ip]`: recreating the VM re-points the
# record set in Azure with no Terraform run, so `*` survives a destroy/deploy
# cycle the same way the per-node record does. Requires a Standard SKU public IP,
# which vm_public_ip above already is.
#
# for_each over a 0-or-1 set rather than count, so the address stays keyed by
# instance name like everything else here — and so flipping which node is the
# edge moves the record instead of renumbering it.
locals {
  # At most one entry, enforced by var.instances' validation.
  public_edge_instances = [for name, inst in var.instances : name if inst.public_edge]
}

# Caddy's DNS-01 identity (#39), created once by infra/identity and looked up
# here by name — the same by-name coupling every cross-module reference in
# this repo uses (see CLAUDE.md). Keyed off the same 0-or-1 set as the
# wildcard record above, so it only exists to be attached to the edge node,
# never fleet-wide.
data "azurerm_user_assigned_identity" "edge_dns" {
  for_each            = toset(local.public_edge_instances)
  name                = var.edge_dns_identity_name
  resource_group_name = var.identity_rg_name
}

resource "azurerm_dns_a_record" "wildcard_record" {
  for_each            = toset(local.public_edge_instances)
  name                = "*"
  zone_name           = data.azurerm_dns_zone.homelab.name
  resource_group_name = var.dns_rg_name
  ttl                 = 300
  target_resource_id  = azurerm_public_ip.vm_public_ip[each.key].id
}

# TODO: same one-shot rename fixup as infra/storage's moved block. Delete once
# `terraform -chdir=compute/vm apply` has run and state shows
# wildcard_record["homelab-edge"] — not a standing record of the rename, just the
# state-address side of the homelab-vm -> homelab-edge move. This record's own
# `name` is the literal "*", not derived from the key, so without this block it
# would otherwise be destroyed and recreated for no reason beyond the key change.
moved {
  from = azurerm_dns_a_record.wildcard_record["homelab-vm"]
  to   = azurerm_dns_a_record.wildcard_record["homelab-edge"]
}

resource "azurerm_network_interface" "vm_nic" {
  # checkov:skip=CKV_AZURE_119:Public IP is intentional for direct SSH access; removed only after Tailscale zero-trust access lands (E06, #19) per CLAUDE.md's lockout-critical ordering
  for_each            = var.instances
  name                = "${each.key}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = each.value.ip_configuration_name
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_public_ip[each.key].id
  }
}

# The NSG is associated at the subnet layer only, in infra/network
# (azurerm_subnet_network_security_group_association.homelab_nsg_assocs). The
# NIC-level association that used to sit here was removed in #162: ADR-0012
# makes the subnet the single owner of NSG policy, because rules are a property
# of the tier a node sits in, not of the node. A per-node exception is an
# argument for a new tier, not for reinstating NIC-level rules.

resource "azurerm_linux_virtual_machine" "homelab_vm" {
  for_each            = var.instances
  name                = each.key
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  # tflint-ignore: azurerm_linux_virtual_machine_retired_size # resize to Standard_B4ms is tracked separately (issue #61, roadmap risk R1: OOM once monitoring/k3s land)
  size           = each.value.vm_size
  admin_username = each.value.admin_username

  network_interface_ids = [azurerm_network_interface.vm_nic[each.key].id]

  admin_ssh_key {
    username   = each.value.admin_username
    public_key = data.azurerm_ssh_public_key.existing_ssh.public_key
  }

  disable_password_authentication = true
  allow_extension_operations      = false

  # User-assigned only on the edge node (0-or-1 set, same as the wildcard
  # record) — private-tier nodes have no DNS-01 identity to attach. Does NOT
  # need allow_extension_operations = true: the IMDS token endpoint and VM
  # extensions are separate mechanisms, verified live against this VM before
  # writing this block (a container on the `web` bridge network reached
  # http://169.254.169.254/metadata/instance with no extension involved).
  dynamic "identity" {
    for_each = each.value.public_edge ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [data.azurerm_user_assigned_identity.edge_dns[each.key].id]
    }
  }

  os_disk {
    name                 = "${each.key}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    # Note: OS Disk is ephemeral by default
  }

  custom_data = filebase64(each.value.cloud_init_file)

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "data_disk_attachment" {
  for_each           = var.instances
  managed_disk_id    = data.azurerm_managed_disk.data_disk[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.homelab_vm[each.key].id
  lun                = each.value.data_disk_lun
  caching            = "ReadWrite"
}
