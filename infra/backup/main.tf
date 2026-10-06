# infra/backup — the Tier 2 backup account (E15.4, #100, ADR-0009 2026-09-28)
#
# One storage account holding one container: `restic`, the encrypted,
# deduplicated repository the edge VM writes nightly. Nothing else ever lands
# here, which is the entire point — versioning and soft delete are blob-SERVICE
# properties, i.e. account-level, so an account that holds only backups is the
# only kind of account on which ADR-0009 §6c can be satisfied without changing
# behaviour for something else.
#
# LOCAL APPLY, AS OWNER, AND DELIBERATELY NO WORKFLOW — the same standing
# infra/identity has. There is no deploy-backup.yml on purpose:
#
#   - Not infra/storage, which runs in CI. Creating a storage account in
#     homelab-persist-rg needs Microsoft.Storage/storageAccounts/write there, and
#     a CI credential able to create the backup account is able to delete it.
#     ADR-0009 §2's second principle exists precisely to prevent that.
#   - Not an out-of-band `az` script either, though the RG itself is one. §2's
#     "never Terraform-managed" rule applies to the RESOURCE GROUP. The pet disk
#     — more precious than its own backup — already sits inside that group fully
#     Terraform-managed behind prevent_destroy, so holding T2 to a stricter
#     standard than T1 would be incoherent. Terraform also buys back what
#     ADR-0009's Consequences section records as a defect: under a script,
#     nothing would ever notice versioning or soft delete being switched off.
#
# The honest limit of that last point: with no workflow, drift is caught whenever
# someone runs a plan, not continuously. #102's drill remains the backstop.
#
# Applying this module is a prerequisite of applying infra/identity: a role
# assignment's scope must already exist, and infra/identity scopes the backup
# identity's grant to the container below.

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

# No data "azurerm_resource_group" for var.persist_rg_name, matching
# infra/storage and compute/vm. That group is read by name as a plain string
# everywhere in this repo because the CI identity's custom role over it is
# exactly disks/read + disks/write, with no
# Microsoft.Resources/subscriptions/resourceGroups/read — a data source there
# fails at *plan* with AuthorizationFailed. This module is never run by CI so it
# would not hit that, but the convention costs nothing and a module that follows
# it cannot be broken by a future change to who runs it.

resource "azurerm_storage_account" "homelab_backup" {
  # checkov:skip=CKV2_AZURE_1:Customer-managed key encryption needs a Key Vault, which lands in E05 (#18). Same deferral infra/storage's disk already carries
  # checkov:skip=CKV2_AZURE_18:As above — CMK is an E05 dependency, not an omission
  # checkov:skip=CKV_AZURE_33:Queue service logging is meaningless here; this account has no queues and never will. Blob diagnostics arrive with infra/monitoring (E08.4, #64)
  # checkov:skip=CKV2_AZURE_33:A private endpoint would break the recovery path this account exists for — see the network_rules comment below
  # checkov:skip=CKV2_AZURE_47:Default-deny network rules would break the same recovery path, for the same reason
  # checkov:skip=CKV_AZURE_59:public_network_access_enabled stays true on purpose — #206 restores from blob alone with no VM, from an arbitrary IP, so disabling it would break the one recovery path this account exists to serve. Anonymous access is off (allow_nested_items_to_be_public), there is no account key (shared_access_key_enabled), and every principal is scoped to one container
  # checkov:skip=CKV_AZURE_206:Standard_LRS is a deliberate budget decision (ADR-0009 2026-09-28 amendment) against the ≤ ₹400/mo parked target. GRS was costed and declined; ADR-0009 §5 records regional loss as an accepted residual risk. The revisit lever is named there rather than left implicit
  # checkov:skip=CKV_AZURE_244:Shared key access is already disabled below, which is strictly stronger than the SAS expiry policy this checks for
  name                = var.backup_storage_account_name
  resource_group_name = var.persist_rg_name
  location            = var.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Hot, no lifecycle rule (ADR-0009 §6b). Cool carries a 30-day minimum
  # retention and `restic forget --prune` deletes pack files overwhelmingly
  # INSIDE that window, so Cool's early-deletion penalty would apply to nearly
  # every prune this design performs — buying ~₹11/mo against 2x write ops,
  # 2.5x read ops and a per-GB retrieval charge on every `restic check` and every
  # restore. Stated revisit trigger, so this is testable rather than taste:
  # reconsider above ~100 GB.
  access_tier = "Hot"

  # THE LOAD-BEARING LINE. With shared key access off, no account key works for
  # anybody, ever — every request must be authorized with Entra. ADR-0009 §6a's
  # rule "never an account key on the internet-facing VM" stops being a policy
  # someone can forget and becomes a property of the account.
  #
  # This is exactly what could NOT be done to listeninfratfstatesa, whose azurerm
  # backend calls listKeys unless ARM_USE_AZUREAD=true — the availability of the
  # key is load-bearing there even though this repo's CI does not use it. It is
  # one more thing the 2026-09-12 shared-account arrangement was costing.
  #
  # Two consequences to know before debugging something: an ACCOUNT SAS cannot be
  # minted here (it is signed with the key) — §6a's documented fallback must be a
  # USER-DELEGATION SAS, which is Entra-signed; and subscription Owner is a
  # CONTROL-plane role that confers no blob data access, so a human needs an
  # explicit data-plane role assignment (infra/identity makes one) or every
  # `restic` and `az storage blob` call fails with AuthorizationPermissionMismatch,
  # an error naming neither the missing role nor the irrelevance of Owner.
  shared_access_key_enabled = false

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  # Entra is the only way in anyway (shared keys are off); this makes the portal
  # agree rather than defaulting to a key-based view that cannot work.
  default_to_oauth_authentication = true

  # Public network access stays ENABLED, and no default-deny network_rules block:
  # #206's disaster-recovery drill restores from blob alone, with no VM, from
  # whatever machine and IP the operator happens to have. A VNet-restricted or
  # private-endpoint-only account would break the one recovery path this account
  # exists to serve — and it would break it silently, at the worst possible
  # moment. The compensating controls are the three lines above plus
  # container-scoped RBAC in infra/identity: there is no anonymous read, no key,
  # and no principal holding more than one container.

  # ADR-0009 §6c, as code. This is the R22 mitigation — the VM holds write access
  # to this container and runs `forget --prune` on a timer, so a compromised or
  # misbehaving VM can delete every backup it has, on schedule.
  #
  # 30 days, not the 7-day default, and the number is not arbitrary: the lab is
  # PARKED FOR WEEKS AT A TIME, so a 7-day window would expire unobserved while
  # nobody is looking at anything.
  #
  # Version-level immutability is the strong form and is rejected with a reason
  # (§6c): a time-based retention lock makes the locked versions undeletable,
  # which makes `prune` impossible for the lock window — incompatible with
  # --keep-daily 7 retention rather than merely inconvenient.
  #
  # Honest cost: versioning on a repository that prunes continuously multiplies
  # stored bytes, since every pruned pack keeps a version for 30 days. §8's table
  # carries a 1.5x multiplier rather than pretending the mitigation is free.
  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
      # Left at its false default, explicitly worth noting: permanent delete
      # would let a caller bypass the soft-delete window entirely, which is the
      # exact capability R22 is defending against.
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  # Control-plane guardrail on top of everything above. It is one commit deep —
  # a PR deleting this block plus the resource, applied by an Owner, still
  # destroys the account. That is the same standing the pet disk has had since
  # E15.2, and the reason the RESOURCE GROUP is kept out of Terraform entirely.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    environment = "homelab"
    persistence = "true"
    purpose     = "restic-backup"
  }
}

# storage_account_id, NEVER the legacy storage_account_name: that argument drives
# the provider through the storage DATA plane, which needs a key or an Entra
# data-plane role, and with shared_access_key_enabled = false above it fails
# outright. storage_account_id uses Resource Manager, which the applying Owner
# can always reach. This is the single most likely way a first apply of this
# module breaks.
resource "azurerm_storage_container" "restic" {
  # checkov:skip=CKV2_AZURE_21:Blob read logging belongs to the diagnostic settings infra/monitoring adds in E08.4 (#64), applied uniformly across the estate rather than invented per container here
  name                  = var.restic_container_name
  storage_account_id    = azurerm_storage_account.homelab_backup.id
  container_access_type = "private"

  # Same reasoning as the account: recreating this container does not lose the
  # repository (container soft delete would hold it for 30 days), but it is not
  # an operation that should ever be routine.
  lifecycle {
    prevent_destroy = true
  }
}
