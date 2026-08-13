output "resource_group_name" {
  value = azurerm_resource_group.homelab_rg.name
}

output "location" {
  value = azurerm_resource_group.homelab_rg.location
}

output "subnet_id" {
  description = "Subnet IDs keyed by subnet name. A map since #161 — nothing consumes it (compute/vm resolves the subnet by name via a data source, and no module uses terraform_remote_state)."
  value       = { for name, subnet in azurerm_subnet.homelab_subnets : name => subnet.id }
}

output "nsg_id" {
  value = azurerm_network_security_group.homelab_nsg.id
}
