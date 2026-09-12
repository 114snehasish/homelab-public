#!/usr/bin/env bash
#
# bootstrap-persist-rg.sh — create `homelab-persist-rg` out-of-band (E15.0, #205)
#
# ADR-0009 §2. This resource group holds the one thing in the lab that must
# outlive every other thing in it, so it is deliberately NOT Terraform-managed.
# `prevent_destroy` is a guardrail *inside* Terraform and it is one commit deep;
# a resource Terraform never manages cannot be destroyed by editing HCL at all.
# Same never-touch pattern as RG `do-not-delete` and `listeninfratfstatesa` —
# except those have no script and this one does, so the RG stays reproducible
# from the repo. Out-of-band means *not Terraform-managed*, not *undocumented*.
#
# Run it locally, as the subscription **Owner**, immediately before applying
# `infra/identity` (docs/oidc_bootstrap.md step 0c). Creating a resource group
# is a subscription-level write, which is precisely what CI does not have.
# `infra/identity` reads this RG through a data source; without it, that apply
# fails at *plan* with a "Resource Group ... was not found" error.
#
# It creates NOTHING ELSE — no storage account, no container. ADR-0009's
# original §2 also had it create a backup storage account; that is superseded by
# the 2026-09-12 amendment (#205): the `restic` container will live in the
# existing state storage account `listeninfratfstatesa`, and #100 owns it.

set -euo pipefail

RG_NAME="${PERSIST_RG_NAME:-homelab-persist-rg}"
LOCATION="${PERSIST_RG_LOCATION:-southindia}"

# The repo's tag vocabulary: `environment` everywhere, `purpose` in
# infra/identity. The third key answers the question a reader of the portal will
# actually ask about this RG — "why is this not in Terraform like everything
# else?".
TAGS=(
  "environment=homelab"
  "purpose=persistence"
  "managed-by=scripts/bootstrap-persist-rg.sh"
)

log() { printf '  %s\n' "$*"; }
fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v az >/dev/null 2>&1 || fail "the Azure CLI (az) is not on PATH."
az account show --only-show-errors -o none 2>/dev/null ||
  fail "not logged in. Run 'az login' as the subscription Owner first."

# Honours the same variable infra/identity's runbook exports, so one shell does
# both steps. Left unset, whatever `az account show` points at is used — and
# printed either way, because a bootstrap that silently lands in the wrong
# subscription is the expensive mistake available here.
SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-$(az account show --query id -o tsv --only-show-errors)}"
SUBSCRIPTION_NAME="$(az account show --subscription "$SUBSCRIPTION_ID" \
  --query name -o tsv --only-show-errors)"

printf '\nBootstrapping the persist resource group (ADR-0009 §2, #205)\n\n'
log "subscription  : ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"
log "resource group: ${RG_NAME}"
log "location      : ${LOCATION}"
printf '\n'

# --- 0. Resource provider registration ------------------------------------
# Same check and same reason as step 0a of docs/oidc_bootstrap.md: azurerm 5.x
# defaults `resource_provider_registrations = "none"`, so Terraform registers
# nothing for you. `infra/storage` puts an azurerm_managed_disk in this RG,
# which is Microsoft.Compute; on an unregistered subscription that fails with an
# unsupported-API-version error that never mentions registration.
#
# Microsoft.Authorization — the provider behind #205's custom role definition —
# is deliberately not checked: it is a core provider, always registered, and
# cannot be unregistered.
COMPUTE_STATE="$(az provider show --namespace Microsoft.Compute \
  --subscription "$SUBSCRIPTION_ID" \
  --query registrationState -o tsv --only-show-errors)"

if [[ "$COMPUTE_STATE" == "Registered" ]]; then
  log "Microsoft.Compute: already registered."
else
  log "Microsoft.Compute: '${COMPUTE_STATE}' — registering (can take a few minutes)."
  az provider register --namespace Microsoft.Compute --wait \
    --subscription "$SUBSCRIPTION_ID" --only-show-errors
  log "Microsoft.Compute: registered."
fi

# --- 1. The resource group ------------------------------------------------
if EXISTING_LOCATION="$(az group show --name "$RG_NAME" \
  --subscription "$SUBSCRIPTION_ID" \
  --query location -o tsv --only-show-errors 2>/dev/null)"; then

  # Deliberately does not re-PUT the group. `az group create --tags` REPLACES
  # the entire tag set, so a re-run of a script whose TAGS array has drifted
  # would silently strip tags something else added out of band. Report only.
  log "${RG_NAME}: already exists — left untouched."

  if [[ "$EXISTING_LOCATION" != "$LOCATION" ]]; then
    fail "${RG_NAME} is in '${EXISTING_LOCATION}', not '${LOCATION}'. A resource group's location is immutable, and a managed disk must be in the same region as the VM that attaches it. Resolve this by hand before going further."
  fi
else
  log "${RG_NAME}: not found — creating."
  az group create \
    --name "$RG_NAME" \
    --location "$LOCATION" \
    --subscription "$SUBSCRIPTION_ID" \
    --tags "${TAGS[@]}" \
    --only-show-errors -o none
  log "${RG_NAME}: created."
fi

RG_ID="$(az group show --name "$RG_NAME" --subscription "$SUBSCRIPTION_ID" \
  --query id -o tsv --only-show-errors)"
RG_TAGS="$(az group show --name "$RG_NAME" --subscription "$SUBSCRIPTION_ID" \
  --query tags -o json --only-show-errors | tr -d '\n ')"

printf '\nDone. Nothing else was created — no storage account, no container.\n\n'
log "id  : ${RG_ID}"
log "tags: ${RG_TAGS}"
printf '\nNext: apply infra/identity locally as Owner (docs/oidc_bootstrap.md).\n'
