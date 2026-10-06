output "backup_storage_account_id" {
  description = "ARM ID of the backup storage account"
  value       = azurerm_storage_account.homelab_backup.id
}

output "backup_storage_account_name" {
  description = "Name of the backup storage account — AZURE_ACCOUNT_NAME in restic's environment on the VM"
  value       = azurerm_storage_account.homelab_backup.name
}

# The exact scope infra/identity assigns the backup identity's role over, and the
# one the runbook echoes when proving the grant is container-scoped rather than
# account-scoped.
#
# `.id` is safe to use here and it is worth saying why, because the older shape
# is everywhere: under azurerm 3.x this attribute was the DATA-PLANE URL
# (https://<account>.blob.core.windows.net/<container>), which is not an ARM ID
# and cannot be a role-assignment scope — hence the
# "<account id>/blobServices/default/containers/<name>" concatenation that
# infra/identity still uses for the tfstate container, and that this repo's
# comments describe. Since the move to storage_account_id, `.id` IS the ARM form:
# verified on the 2026-09-28 apply, which reported
# .../storageAccounts/homelabpersistbackupsa/blobServices/default/containers/restic.
output "restic_container_scope" {
  description = "ARM scope of the restic container — what a role assignment over it must use"
  value       = azurerm_storage_container.restic.id
}
