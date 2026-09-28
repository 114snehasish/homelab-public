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
# to prove nothing was granted out of band. That diff only works if this list is
# genuinely complete: Managed Identity Operator (E03.3, #39) was missing here
# until E15.0, so the comparison had a spurious extra row on the Azure side and
# quietly failed at the one job this output exists to do.
#
# A LIST OF OBJECTS, NOT A MAP, since E15.4 (#100). It was a map keyed by role
# name until the backup identity arrived with a SECOND `Managed Identity
# Operator` grant — two identical keys, which fails the plan outright with
# "Duplicate object attribute key". Disambiguating the keys was the other option
# and was rejected: the strings would then stop matching what `az role assignment
# list` prints, which is the one job this output has. A list also matches the
# shape of the thing it is diffed against.
#
# One row's role name comes from the role *definition* rather than the
# assignment, because E15.0's grant uses role_definition_id and so sets no
# role_definition_name in config. That attribute is Computed and the provider
# does populate it on read — but it is unknown at *plan* time, and one unknown
# value renders this entire output as "(known after apply)", hiding every other
# row in exactly the plan you want to read them in.
output "granted_scopes" {
  description = "Role assignments held by the CI identity, as a list of {role, scope} — six of them since E15.4"
  value = [
    { role = azurerm_role_assignment.homelab_rg_contributor.role_definition_name, scope = azurerm_role_assignment.homelab_rg_contributor.scope },
    { role = azurerm_role_assignment.tfstate_blob_contributor.role_definition_name, scope = azurerm_role_assignment.tfstate_blob_contributor.scope },
    { role = azurerm_role_assignment.vm_ssh_key_reader.role_definition_name, scope = azurerm_role_assignment.vm_ssh_key_reader.scope },
    { role = azurerm_role_assignment.ci_edge_identity_operator.role_definition_name, scope = azurerm_role_assignment.ci_edge_identity_operator.scope },
    { role = azurerm_role_assignment.ci_backup_identity_operator.role_definition_name, scope = azurerm_role_assignment.ci_backup_identity_operator.scope },
    { role = azurerm_role_definition.persist_disk_writer.name, scope = azurerm_role_assignment.persist_disk_writer.scope },
  ]
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

# --- Backup identity outputs (E15.4, #100) --------------------------------

output "backup_client_id" {
  description = "Client ID of the restic backup identity — AZURE_CLIENT_ID in /etc/homelab/restic.env on the edge VM. Not a secret: an identifier, exactly like the ones already in Caddy's environment file"
  value       = azurerm_user_assigned_identity.homelab_backup.client_id
}

output "backup_uami_id" {
  description = "Full resource ID of the backup identity — the second entry in compute/vm's identity_ids on the edge node"
  value       = azurerm_user_assigned_identity.homelab_backup.id
}

# Same purpose as granted_scopes and edge_granted_scopes, kept separate for the
# same reason: three principals, three lists, never diffed against each other as
# if they were one.
#
# The operator grant is deliberately NOT in here. This output documents what the
# backup identity holds; the human who applied the module is a different
# principal with a different lifetime, and folding it in would make a clean diff
# against `az role assignment list --assignee <backup principal>` show a
# spurious row — the exact failure mode granted_scopes had before #205.
output "backup_granted_scopes" {
  description = "Role assignments held by the restic backup identity, as a list of {role, scope}"
  value = [
    { role = azurerm_role_assignment.backup_restic_blob_contributor.role_definition_name, scope = azurerm_role_assignment.backup_restic_blob_contributor.scope },
  ]
}
