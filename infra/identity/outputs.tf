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

# The complete list of what CI is allowed to do, in one greppable place —
# diff it against `az role assignment list --assignee <principal_id> --all`
# to prove nothing was granted out of band. That diff only works if this map is
# genuinely complete: Managed Identity Operator (E03.3, #39) was missing here
# until E15.0, so the comparison had a spurious extra row on the Azure side and
# quietly failed at the one job this output exists to do.
#
# The last key comes from the role *definition* rather than the assignment,
# because E15.0's grant uses role_definition_id and so sets no
# role_definition_name in config. That attribute is Computed and the provider
# does populate it on read — but it is unknown at *plan* time, and an unknown
# map key renders this entire output as "(known after apply)", hiding every
# other row in exactly the plan you want to read them in.
output "granted_scopes" {
  description = "Role assignments held by the identity, as role name => scope"
  value = {
    (azurerm_role_assignment.homelab_rg_contributor.role_definition_name)    = azurerm_role_assignment.homelab_rg_contributor.scope
    (azurerm_role_assignment.tfstate_blob_contributor.role_definition_name)  = azurerm_role_assignment.tfstate_blob_contributor.scope
    (azurerm_role_assignment.vm_ssh_key_reader.role_definition_name)         = azurerm_role_assignment.vm_ssh_key_reader.scope
    (azurerm_role_assignment.ci_edge_identity_operator.role_definition_name) = azurerm_role_assignment.ci_edge_identity_operator.scope
    (azurerm_role_definition.persist_disk_writer.name)                       = azurerm_role_assignment.persist_disk_writer.scope
  }
}

# So `az role definition show` in the runbook's verification step does not have
# to resolve the custom role by display name.
output "persist_disk_role_definition_id" {
  description = "ARM ID of the custom disk role granted to CI over the persist resource group"
  value       = azurerm_role_definition.persist_disk_writer.role_definition_resource_id
}

# --- Edge DNS identity outputs (E03.3, #39) -------------------------------

output "edge_dns_client_id" {
  description = "Client ID of Caddy's edge DNS identity — the AZURE_CLIENT_ID fallback if managed-identity auto-selection on the VM is ever ambiguous"
  value       = azurerm_user_assigned_identity.homelab_edge_dns.client_id
}

output "edge_dns_uami_id" {
  description = "Full resource ID of Caddy's edge DNS identity — what compute/vm's identity block attaches"
  value       = azurerm_user_assigned_identity.homelab_edge_dns.id
}

# Same purpose as granted_scopes above, kept separate: that output documents
# the CI identity specifically, this one documents the edge identity Caddy
# runs as — the two must never be diffed against each other as if one list.
output "edge_granted_scopes" {
  description = "Role assignments held by Caddy's edge DNS identity, as role name => scope"
  value = {
    (azurerm_role_assignment.edge_dns_zone_contributor.role_definition_name) = azurerm_role_assignment.edge_dns_zone_contributor.scope
  }
}
