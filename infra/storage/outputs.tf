# Keyed by instance name, matching the fleet map. compute/vm does not read this
# output (it looks the disk up by name through a data source), so this is for
# operators and future modules.
output "disk_id" {
  value = { for name, disk in azurerm_managed_disk.homelab_data_disk : name => disk.id }
}
