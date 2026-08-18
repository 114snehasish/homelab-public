# TEMPORARY — delete this whole file once the fleet refactor has been applied.
#
# Converting a resource to for_each changes its address, which Terraform plans
# as destroy + create unless a `moved` block tells it otherwise. Every resource
# here already exists in state at its old scalar address; these blocks re-point
# state at the map key "homelab-vm" so the plan reads 0 to add, 0 to change,
# 0 to destroy.
#
# THIS MODULE HAS NO prevent_destroy. In infra/storage a wrong `moved` block
# fails the plan; here it would silently destroy the running node. The gate is
# reading the plan before applying, not a lifecycle rule.
#
# These are one-shot instructions to state, not configuration. Once the apply
# has run they are inert, and the repo's convention is to drop them in a
# dedicated follow-up commit (see f74b8d5, the follow-up to #161) — but NOT
# before the apply, because until then they are still doing the work.

moved {
  from = azurerm_public_ip.vm_public_ip
  to   = azurerm_public_ip.vm_public_ip["homelab-vm"]
}

moved {
  from = azurerm_dns_a_record.vm_record
  to   = azurerm_dns_a_record.vm_record["homelab-vm"]
}

moved {
  from = azurerm_network_interface.vm_nic
  to   = azurerm_network_interface.vm_nic["homelab-vm"]
}

moved {
  from = azurerm_linux_virtual_machine.homelab_vm
  to   = azurerm_linux_virtual_machine.homelab_vm["homelab-vm"]
}

moved {
  from = azurerm_virtual_machine_data_disk_attachment.data_disk_attachment
  to   = azurerm_virtual_machine_data_disk_attachment.data_disk_attachment["homelab-vm"]
}
