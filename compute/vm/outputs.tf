# Both outputs are scalars because the fleet is one node. They become maps keyed
# by instance name in E17.6/E17.7 (#165/#166) — anything consuming them (the
# verify-persistence skill reads ssh_command) has to change with them.
output "public_ip" {
  value = azurerm_public_ip.vm_public_ip.ip_address
}

output "ssh_command" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.vm_public_ip.ip_address}"
}
