terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# One persistent disk per compute instance, keyed by the same fleet map
# compute/vm uses — a managed disk attaches to exactly one VM, so the disks have
# to multiply in lockstep with the nodes. The fallback name must match the one
# compute/vm's data source builds: the two modules are linked by naming
# convention, not by terraform_remote_state.
#
# They live in homelab-persist-rg, not homelab-rg (E15.2, #98): ADR-0009's first
# principle is that nothing precious shares a resource group with anything
# destroyable. That group is created out-of-band and is only ever read here —
# there is no data source for it on purpose, because the CI identity's custom
# role grants disks/read + disks/write and deliberately no
# Microsoft.Resources/subscriptions/resourceGroups/read.
resource "azurerm_managed_disk" "homelab_data_disk" {
  # checkov:skip=CKV_AZURE_93:Customer-managed key encryption needs a Key Vault, which lands in E05 (#18)
  # checkov:skip=CKV_AZURE_251:No disk export/Private Link scenario in this architecture; the disk is attached directly to compute/vm and never accessed independently
  for_each             = var.instances
  name                 = coalesce(each.value.disk_name, "${each.key}-data-disk")
  location             = var.location
  resource_group_name  = var.disk_rg_name
  storage_account_type = "StandardSSD_LRS" # Cost effective SSD
  create_option        = "Empty"
  disk_size_gb         = each.value.disk_size_gb

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    environment = "homelab"
    persistence = "true"
  }
}
