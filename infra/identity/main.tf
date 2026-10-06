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

locals {
  # GitHub derives the OIDC `sub` claim from the repository that runs the
  # workflow, so this must track the origin remote exactly. A stale value fails
  # the token exchange with "no matching federated identity record found" —
  # an error that never mentions the subject string, so it is worth getting
  # right here rather than debugging it in E02.3 (#35).
  github_repository = "114snehasish/homelab"

  tags = {
    environment = "homelab"
    purpose     = "github-oidc"
  }
}

# Deliberately its own resource group rather than homelab-rg: E02.2 (#34) grants
# this identity Contributor over homelab-rg, and an identity that can delete
# itself is one bad apply away from locking CI out of Azure entirely.
resource "azurerm_resource_group" "homelab_identity_rg" {
  name     = var.identity_rg_name
  location = var.location

  tags = local.tags
}

resource "azurerm_user_assigned_identity" "homelab_github_oidc" {
  name                = var.uami_name
  location            = azurerm_resource_group.homelab_identity_rg.location
  resource_group_name = azurerm_resource_group.homelab_identity_rg.name

  # Control-plane asset, protected for the same reason as the pet disk:
  # recreating it mints a new client_id, which costs a local re-bootstrap *and*
  # an update to the repo variables every workflow authenticates with.
  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

# --- Federated credentials ------------------------------------------------

# Trust for workflow runs on main — this covers the dispatch-gated applies,
# which are always dispatched from main.
resource "azurerm_federated_identity_credential" "homelab_github_main" {
  name                      = "homelab-github-main"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${local.github_repository}:ref:refs/heads/main"
  user_assigned_identity_id = azurerm_user_assigned_identity.homelab_github_oidc.id
}

# Trust for pull_request runs (plan only — _terraform.yml disables apply on
# pull_request events structurally, regardless of the apply input).
resource "azurerm_federated_identity_credential" "homelab_github_pull_request" {
  name                      = "homelab-github-pull-request"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${local.github_repository}:pull_request"
  user_assigned_identity_id = azurerm_user_assigned_identity.homelab_github_oidc.id
}

# --- RBAC (E02.2, #34) ----------------------------------------------------
#
# Everything below is a *grant*: three role assignments, and the read-only
# lookups that locate their scopes. Nothing here creates, modifies or destroys
# a resource outside this module — `listeninfratfstatesa` and the RG
# `do-not-delete` are pre-existing and managed outside this repo, so they are
# only ever read.
#
# The apply that creates these needs Microsoft.Authorization/roleAssignments/write
# (Owner or User Access Administrator) at each scope — Contributor alone cannot
# hand out roles. See docs/oidc_bootstrap.md, step 0.

data "azurerm_resource_group" "homelab" {
  name = var.homelab_rg_name
}

data "azurerm_storage_account" "tfstate" {
  name                = var.state_storage_account_name
  resource_group_name = var.state_storage_rg_name
}

# compute/vm reads this same key by name; the UAMI needs to be able to read it
# there or every VM plan fails on the data source.
data "azurerm_ssh_public_key" "homelab_vm" {
  name                = var.vm_ssh_key_name
  resource_group_name = var.state_storage_rg_name
}

locals {
  # Built by string-append rather than via an azurerm_storage_container data
  # source on purpose: that data source reads the storage *data* plane, and the
  # bootstrap SP is not guaranteed to have blob-level rights on an account it
  # otherwise only manages. Resource-manager calls only, all the way down.
  tfstate_container_scope = "${data.azurerm_storage_account.tfstate.id}/blobServices/default/containers/${var.state_container_name}"
}

# The whole point of the epic: lab resources, one resource group, nothing wider.
#
# Note the limit this implies — a role assignment scoped to an RG is stored on
# that RG and dies with it, and creating an RG is a subscription-level write
# anyway. So CI can manage homelab-rg but could never *recreate* it after a
# deletion. That is acceptable because destroy.yml deliberately never destroys
# infra/network; the break-glass path is a local apply with the SP (roadmap R8).
resource "azurerm_role_assignment" "homelab_rg_contributor" {
  scope                = data.azurerm_resource_group.homelab.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.homelab_github_oidc.principal_id

  # The Entra existence check azurerm runs before assigning is the one that
  # fails with PrincipalNotFound when the principal was created moments earlier
  # and has not replicated yet — i.e. on a re-bootstrap, where this module
  # creates the UAMI and its roles in a single apply. The principal here is
  # always our own UAMI, one resource up, so skipping the check costs nothing.
  skip_service_principal_aad_check = true
}

# State access is data-plane only: read, write and lease (the state lock) the
# blobs in the tfstate container. Deliberately NOT a role on the storage
# account, which would also confer listKeys — the key is a bearer credential
# for every container in the account, which is exactly what OIDC is replacing.
#
# This grant only works if Terraform talks to the backend with Entra auth
# (ARM_USE_AZUREAD=true). Without it the azurerm backend calls listKeys and
# fails in `terraform init`, before anything else runs.
resource "azurerm_role_assignment" "tfstate_blob_contributor" {
  scope                = local.tfstate_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.homelab_github_oidc.principal_id

  skip_service_principal_aad_check = true # same replication-lag reason as above
}

# Scoped to the single SSH key resource, not the RG that holds it: the epic's
# rule is "no rights over do-not-delete beyond state-blob access", and this is
# the narrowest possible exception that keeps compute/vm plannable. It confers
# read on one public key — which is public by construction.
resource "azurerm_role_assignment" "vm_ssh_key_reader" {
  scope                = data.azurerm_ssh_public_key.homelab_vm.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.homelab_github_oidc.principal_id

  skip_service_principal_aad_check = true # same replication-lag reason as above
}

# --- Edge DNS identity (E03.3, #39) ---------------------------------------
#
# A second, unrelated UAMI: Caddy's DNS-01 identity, not the CI identity above.
# It lets Caddy authenticate to Azure DNS from inside a container on the edge
# VM with no credential on disk anywhere — libdns/azure falls back to managed
# identity when tenant_id/client_id/client_secret are all left empty.
#
# User-assigned, not system-assigned: compute/vm is cattle (destroy.yml tears
# it down every park cycle). A system-assigned identity dies with the VM and
# mints a new principal_id, breaking the role assignment below on every
# recreate. This one is created once, here, and compute/vm only ever attaches
# it by name.
#
# No prevent_destroy, unlike homelab_github_oidc above: nothing outside this
# module references this identity's client_id — recreating it costs one
# infra/identity re-apply, not a repo-variable update and a re-bootstrap.
resource "azurerm_user_assigned_identity" "homelab_edge_dns" {
  name                = var.edge_uami_name
  location            = azurerm_resource_group.homelab_identity_rg.location
  resource_group_name = azurerm_resource_group.homelab_identity_rg.name

  # Not local.tags: that map's purpose = "github-oidc" describes the CI
  # identity above, not this one. Same environment tag, distinct purpose.
  tags = merge(local.tags, { purpose = "caddy-dns01" })
}

# Looked up by name, the same by-name coupling CLAUDE.md documents everywhere
# else in this repo (a zone rename silently breaks this lookup) — infra/dns is
# a separate root module with its own state, not something this module can
# depend on directly. Unlike the RBAC data sources above, which only read
# resources pre-existing outside this repo, this one depends on infra/dns
# having already applied: a from-scratch rebuild applies infra/dns before
# infra/identity for that reason.
data "azurerm_dns_zone" "homelab" {
  name                = var.dns_zone_name
  resource_group_name = var.homelab_rg_name
}

# Caddy's only Azure right: write the ACME DNS-01 TXT challenge into the zone
# and clean it up after. Scoped to the zone, not homelab-rg — this identity has
# no reason to touch the VM, the disk, or anything else Contributor would allow.
resource "azurerm_role_assignment" "edge_dns_zone_contributor" {
  scope                = data.azurerm_dns_zone.homelab.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.homelab_edge_dns.principal_id

  skip_service_principal_aad_check = true # same replication-lag reason as above
}

# Lets the CI identity ATTACH this UAMI to the edge VM in compute/vm — nothing
# wider. Not a privilege escalation: CI already holds Contributor on
# homelab-rg, and the DNS zone lives in homelab-rg, so CI could already write
# records there directly today. This grant only adds the attach action.
#
# Reader is NOT enough here, even though it looks narrower: attaching a UAMI to
# a VM needs Microsoft.ManagedIdentity/userAssignedIdentities/assign/action,
# which is a write, not a read. A Reader grant plans clean in compute/vm and
# then fails at apply with an authorization error that names neither "Reader"
# nor "assign" — worth getting right here rather than debugging it there.
resource "azurerm_role_assignment" "ci_edge_identity_operator" {
  scope                = azurerm_user_assigned_identity.homelab_edge_dns.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.homelab_github_oidc.principal_id

  skip_service_principal_aad_check = true # same replication-lag reason as above
}

# --- Persist RG disk grant (E15.0, #205) ----------------------------------
#
# ADR-0009 §2: homelab-persist-rg holds the one thing in this lab that must
# outlive every other thing in it, so it is deliberately NOT Terraform-managed
# anywhere — prevent_destroy is a guardrail *inside* Terraform and it is one
# commit deep, while a resource Terraform never manages cannot be destroyed by
# editing HCL at all. scripts/bootstrap-persist-rg.sh creates it, and it joins
# `do-not-delete` and `listeninfratfstatesa` on CLAUDE.md's *Never touch* list.
# Everything below is a grant over it, nothing more.

# If the bootstrap script has not run, this fails at *plan* with a "Resource
# Group ... was not found" error naming homelab-persist-rg. That is the
# ordering signal working, not a bug — see docs/oidc_bootstrap.md step 0c.
data "azurerm_resource_group" "homelab_persist" {
  name = var.persist_rg_name
}

# There is no built-in "Disk Contributor" role. Checked against Microsoft's
# catalogue: the only disk-named built-ins are Disk Backup Reader, Disk Pool
# Operator, Disk Restore Operator, Disk Snapshot Contributor and Data Operator
# for Managed Disks, none of which can create a managed disk. The alternatives
# are Virtual Machine Contributor or Contributor, both of which re-widen exactly
# what this section narrows. So: a custom role, two actions.
#
# Both are needed, and `write` is load-bearing twice over. infra/storage creates
# the disk (write) and refreshes it (read); compute/vm reads it through a data
# source (read) and *attaches* it (write — attaching sets the disk's `managedBy`
# property, and Azure has no disks/join/action the way it does for subnets and
# NICs). Scoped to the RG rather than to the disk because a role assignment's
# scope must already exist, and a new fleet node's disk does not yet.
#
# Deliberately absent, each for its own reason:
#   - Microsoft.Compute/disks/delete — CI never needs it. A delete happens only
#     on destroy, and infra/storage's prevent_destroy already refuses. Leaving
#     it out makes retiring a disk a deliberate local-owner act and demotes
#     prevent_destroy to belt-and-braces (ADR-0009 §2).
#   - Microsoft.Compute/disks/{begin,end}GetAccess/action — these mint a disk
#     SAS URI, i.e. read the bytes. The worst possible action to hand a CI
#     credential over the one disk holding every live database in the lab.
#   - Microsoft.Resources/subscriptions/resourceGroups/read — nothing needs it
#     today: infra/storage passes the RG as a plain string and compute/vm's only
#     resource-group data source points at homelab-rg. If a future module adds
#     `data "azurerm_resource_group"` over this RG it fails at *plan* with
#     AuthorizationFailed naming that exact action; the fix is one more entry
#     here, not a wider role.
#
# The definition is stored *at* its scope, so it dies with the RG — same
# property as the homelab-rg Contributor assignment above. Recovery is re-run
# the bootstrap script, then re-apply this module.
resource "azurerm_role_definition" "persist_disk_writer" {
  name        = var.persist_disk_role_name
  scope       = data.azurerm_resource_group.homelab_persist.id
  description = "Create, read and update managed disks in ${var.persist_rg_name}. Cannot delete them, and cannot export their contents via a SAS URI."

  # No role_definition_id: the provider generates the GUID. Pinning one is
  # ForceNew, so a destroy/recreate would collide with the retained definition
  # (RoleDefinitionWithSameNameExists) instead of minting a fresh one.

  permissions {
    actions     = ["Microsoft.Compute/disks/read", "Microsoft.Compute/disks/write"]
    not_actions = []
  }

  # Defaults to [scope] when omitted. Stated explicitly because this is the
  # field that answers "where could this role ever be handed out?", and that
  # answer should not depend on the reader knowing a provider default.
  assignable_scopes = [data.azurerm_resource_group.homelab_persist.id]
}

# role_definition_id, not role_definition_name: the provider documents the
# latter as the name of a *built-in* role, and its code path for it does a
# tenant-wide roleDefinitions List filtered by roleName that hard-fails unless
# exactly one match comes back — a race against RBAC propagation on the very
# apply that creates the definition. role_definition_resource_id is the ARM ID;
# `.id` must not be used here, it is "{guid}|{scope}" and not an ARM ID at all.
resource "azurerm_role_assignment" "persist_disk_writer" {
  scope              = data.azurerm_resource_group.homelab_persist.id
  role_definition_id = azurerm_role_definition.persist_disk_writer.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.homelab_github_oidc.principal_id

  skip_service_principal_aad_check = true # same replication-lag reason as above
}

# --- Backup identity (E15.4, #100) ----------------------------------------
#
# A THIRD UAMI, unrelated to the two above: the identity restic authenticates as
# from the edge VM, so the internet-facing host holds no credential for the
# backups it writes. ADR-0009 §6a.
#
# User-assigned, not system-assigned, for the same reason as the edge DNS
# identity: compute/vm is cattle and destroy.yml tears it down every park cycle,
# and a system-assigned identity dies with the VM and mints a new principal_id,
# breaking the role assignment below on every recreate.
#
# No prevent_destroy, unlike homelab_github_oidc: nothing outside this module
# pins this identity's client_id. compute/vm reads it by name and renders it into
# the VM's restic environment on every apply, so recreating it costs one
# infra/identity apply plus one compute/vm apply — not a repo-variable update.
resource "azurerm_user_assigned_identity" "homelab_backup" {
  name                = var.backup_uami_name
  location            = azurerm_resource_group.homelab_identity_rg.location
  resource_group_name = azurerm_resource_group.homelab_identity_rg.name

  tags = merge(local.tags, { purpose = "restic-backup" })
}

# Created by infra/backup (local apply, as Owner, no workflow) and read here by
# name. Safe as a data source here and only here: this module is never run by CI,
# which holds disks/read + disks/write in that resource group and no
# Microsoft.Storage/* at all. compute/vm, which IS run by CI, takes the account
# name as a plain string for exactly that reason.
data "azurerm_storage_account" "backup" {
  name                = var.backup_storage_account_name
  resource_group_name = var.persist_rg_name
}

locals {
  # Same string shape as tfstate_container_scope above, and built the same way
  # rather than via an azurerm_storage_container data source: that data source
  # reads the storage DATA plane, and this account takes no shared key at all
  # (infra/backup sets shared_access_key_enabled = false), so a data-plane read
  # would depend on the very grant being created below.
  restic_container_scope = "${data.azurerm_storage_account.backup.id}/blobServices/default/containers/${var.restic_container_name}"
}

# restic's only Azure right: read and write blobs in one container.
#
# Scoped to the CONTAINER, not the account — and deliberately still so, even
# though that account now holds nothing else. The scope states what the
# credential may reach, not what happens to sit beside it today; an account-scoped
# grant here would silently widen the moment anything else lands in the account,
# and the principal holding it runs on the lab's only internet-facing host.
#
# This is the narrowest built-in that lets restic work. `Storage Blob Data
# Contributor` can also DELETE blobs, which is risk R22 — the credential being
# used as designed is the attack. §6c's shipped mitigation is versioning plus
# 30-day soft delete on the account (infra/backup); the strong form — a custom
# data-plane role without .../blobs/delete, plus `forget --prune` moved into a
# scheduled CI job with its own identity — is an open ADR item, not shipped here.
resource "azurerm_role_assignment" "backup_restic_blob_contributor" {
  scope                = local.restic_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.homelab_backup.principal_id

  skip_service_principal_aad_check = true # same replication-lag reason as above
}

# Lets the CI identity ATTACH the backup identity to the edge VM in compute/vm,
# and nothing wider — the second grant of this role, alongside the edge DNS one
# above. Reader is not enough: attaching a UAMI needs
# Microsoft.ManagedIdentity/userAssignedIdentities/assign/action, a write, and a
# Reader grant plans clean in compute/vm then fails at apply with an error
# naming neither "Reader" nor "assign".
resource "azurerm_role_assignment" "ci_backup_identity_operator" {
  scope                = azurerm_user_assigned_identity.homelab_backup.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.homelab_github_oidc.principal_id

  skip_service_principal_aad_check = true # same replication-lag reason as above
}

# The human. See var.grant_operator_blob_access for why Owner is not enough and
# why this is a variable rather than unconditional.
#
# Not skip_service_principal_aad_check: this principal is a user that has existed
# for years, not a service principal created moments ago in this same apply, so
# the replication-lag reason the other assignments cite does not apply and the
# existence check is worth keeping.
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "operator_restic_blob_contributor" {
  count = var.grant_operator_blob_access ? 1 : 0

  scope                = local.restic_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
