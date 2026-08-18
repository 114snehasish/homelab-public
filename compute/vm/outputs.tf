# Maps keyed by instance name, not scalars: the module builds a fleet, and a
# scalar could only ever describe one node of it. Consumers index by the same
# key used in fleet.tfvars — e.g. `terraform output -json ssh_command | jq -r
# '."homelab-vm"'`. The verify-persistence skill reads ssh_command this way.
output "public_ip" {
  value = { for name, ip in azurerm_public_ip.vm_public_ip : name => ip.ip_address }
}

output "ssh_command" {
  value = {
    for name, vm in azurerm_linux_virtual_machine.homelab_vm :
    name => "ssh ${vm.admin_username}@${azurerm_public_ip.vm_public_ip[name].ip_address}"
  }
}
