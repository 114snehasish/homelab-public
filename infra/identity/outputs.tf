# None of these are secrets — they are identifiers, which is precisely why
# E02.3 (#35) puts them in repo *variables* rather than repo secrets.

output "client_id" {
  description = "Client ID of the UAMI — becomes the ARM_CLIENT_ID repo variable in E02.3"
  value       = azurerm_user_assigned_identity.homelab_github_oidc.client_id
}

output "principal_id" {
  description = "Object ID of the UAMI's service principal — the role assignment target in E02.2"
  value       = azurerm_user_assigned_identity.homelab_github_oidc.principal_id
}

output "tenant_id" {
  description = "Tenant the UAMI belongs to — becomes the ARM_TENANT_ID repo variable in E02.3"
  value       = azurerm_user_assigned_identity.homelab_github_oidc.tenant_id
}

output "uami_id" {
  description = "Full resource ID of the UAMI"
  value       = azurerm_user_assigned_identity.homelab_github_oidc.id
}

output "identity_rg_name" {
  description = "Resource group the identity lives in"
  value       = azurerm_resource_group.homelab_identity_rg.name
}
