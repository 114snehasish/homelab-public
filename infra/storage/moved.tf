# TEMPORARY — delete this whole file once the fleet refactor has been applied.
# See compute/vm/moved.tf for the full rationale and the removal ordering.
#
# The disk carries prevent_destroy, so if this block were missing or wrong the
# plan would *fail* rather than delete the pet disk. That error is the safety
# net; this block is what makes the plan succeed with zero changes.

moved {
  from = azurerm_managed_disk.homelab_data_disk
  to   = azurerm_managed_disk.homelab_data_disk["homelab-vm"]
}
