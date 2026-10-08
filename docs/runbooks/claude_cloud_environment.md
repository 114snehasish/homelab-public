# Runbook: the Claude Code cloud environment (read-only, plan-only)

How the personal Claude Code **cloud** environment `homelab` (claude.ai/code) is set up, what it is
allowed to do, and how to rotate, rebuild and debug it. The environment is configured **in the
claude.ai UI, not in git** — this file is the versioned record of that configuration, so nothing here
can be recovered from the repo any other way. In the repo: `scripts/cloud-session-init.sh` (the
sign-in script), the `SessionStart` entry in `.claude/settings.json` that runs it, the rules a session
follows (*Cloud sessions* under *Local setup* in [`CLAUDE.md`](../../CLAUDE.md), and the Cloud branch of
the `tf-plan` skill), and the hook's own notes in [`.claude/hooks/README.md`](../../.claude/hooks/README.md).

**This file contains no secret and no identifier** — only variable names, fixed non-secret settings and
`<placeholders>`. Keep it that way: `main` is force-mirrored to a public repo.

## Why this exists

So a Claude Code session on claude.ai/code can **plan and inspect** the lab — read state, run
`terraform plan` for a branch, answer questions about what is deployed — without the owner's laptop and
without any write access. Applies stay where they were: GitHub Actions (the OIDC UAMI, via
`workflow_dispatch` with the apply checkbox) or a local run as Owner.

It is **not** the "read-only Azure identity" of E14 ([#94](https://github.com/114snehasish/homelab/issues/94)),
which is for ephemeral agent runners on k3s in month 2 and does not exist yet (see the
[roadmap](../roadmap.md)). If that one is ever built, compare the two rather than merging them.

## The identity

| | |
|---|---|
| Name | `homelab-claude-cloud-reader` (an app registration and its service principal) |
| `Reader` | the subscription |
| `Storage Blob Data Reader` | the `tfstate` **container** of `listeninfratfstatesa` (RG `do-not-delete`) — never the account |
| Credential | one client secret, default lifetime one year |
| Lives in | the `ARM_*` variables of the `homelab` environment in claude.ai. Not in this repo, not in repo Settings, not in CI |

What that buys: every control-plane read (which is all `terraform plan` needs) and read access to the
state blobs. State is read over Entra data-plane RBAC (`ARM_USE_AZUREAD=true`), so no storage account
key is involved — the same property the CI identity has. The data role is scoped to the container for
the same reason as everywhere else in this lab: an account-scoped role carries `listKeys`, which is a
bearer credential for every container in the account.

**What it cannot do, deliberately:** write anything in Azure; take the state blob lease (hence
`-lock=false`); `listKeys` on any storage account; read the `secret-files` container or the `restic`
container in `homelabpersistbackupsa` (the DR path in [`restic_backup.md`](restic_backup.md) uses the
operator's own role, not this one); reach Cloudflare. When a plan fails with `AuthorizationFailed` the
answer is to grant the one action it names — never to widen to `Contributor`.

### Why a client secret, and why that is acceptable here

Everything else in the lab is keyless: CI federates over OIDC (E02.3, [#35](https://github.com/114snehasish/homelab/issues/35)),
the VM uses managed identities, and E02.4 ([#36](https://github.com/114snehasish/homelab/issues/36))
deleted the last client secret. This identity is the **one deliberate exception** to that, and the only
client secret in the lab. A cloud session runs outside Azure and has no OIDC issuer Azure can federate
with, so the choice is a secret or a certificate — and a certificate would have to live in the same
claude.ai UI, so it would improve rotation hygiene without changing the trust model. (Microsoft's own
guidance is to prefer federation or managed identity; this is the case where neither is available.)

It is acceptable **only because it is read-only**, and these bound the damage:

- *If the secret leaks:* subscription-wide read of resource configuration, plus the Terraform state
  blobs (state can hold sensitive attribute values, as any state can). No writes, and no data-plane
  access outside the `tfstate` container.
- It expires after a year unless rotated, and rotation takes minutes (below).
- The environment's network allowlist limits where a session can send anything, and Cloudflare is
  deliberately unreachable.
- The secret appears nowhere in this repo, in repo Settings or in CI.

**Do not grant this identity a write role.** Its acceptability rests on it being read-only; if something
needs to apply from a cloud session, that is a different design, not a bigger role.

### Creating it

Run as the subscription Owner (`az login`). Check what exists first —
`az ad sp list --display-name homelab-claude-cloud-reader -o table`.

```bash
# 1. The service principal, with Reader on the subscription. The output carries the client
#    secret ONCE: capture it, paste it into the claude.ai variables, then clear the terminal.
sp=$(az ad sp create-for-rbac --name homelab-claude-cloud-reader \
       --role Reader --scopes /subscriptions/<subscription_id> --years 1)
app_id=$(jq -r .appId  <<<"$sp")      # -> ARM_CLIENT_ID
tenant=$(jq -r .tenant <<<"$sp")      # -> ARM_TENANT_ID
jq -r .password <<<"$sp"              # -> ARM_CLIENT_SECRET   (<subscription_id> -> ARM_SUBSCRIPTION_ID)

# 2. Blob data read on the tfstate CONTAINER only — never the storage account.
az role assignment create \
  --assignee-object-id "$(az ad sp show --id "$app_id" --query id -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" \
  --scope "/subscriptions/<subscription_id>/resourceGroups/do-not-delete/providers/Microsoft.Storage/storageAccounts/listeninfratfstatesa/blobServices/default/containers/tfstate"

# 3. Check: exactly two rows, scoped as above.
az role assignment list --assignee "$app_id" --all -o table
```

Step 2 uses the object ID and principal type, the same style as in [`restic_backup.md`](restic_backup.md):
it skips a Graph lookup and the "principal not found" race right after creation. A role assignment takes
a minute or so to propagate.

## Environment variables

Set in the environment's variables in the claude.ai UI. The service principal's identifiers and secret
are listed by **name only** — never print, echo or commit their values; to check one is set without
showing it: `[ -n "$ARM_CLIENT_SECRET" ] && echo set`. The non-secret settings show their fixed values.

| Variable | Why |
|---|---|
| `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID` | The service principal. Terraform's azurerm provider and backend authenticate from these on their own; the SessionStart hook passes the same three to `az login`. |
| `ARM_SUBSCRIPTION_ID` | Required by azurerm; the hook also uses it to select `az`'s default subscription. |
| `ARM_USE_AZUREAD=true` | Read the state backend over Entra data-plane RBAC (the role on the `tfstate` container) instead of `listKeys`. Without it `init` fails before `validate`. The same flag CI sets. |
| `TF_CLI_ARGS_plan=-lock=false` | A read-only identity cannot take the state blob lease, so plans run unlocked. |
| `TF_INPUT=0` | A missing variable is an error, not a prompt that hangs the session. |
| `TF_IN_AUTOMATION=1` | Output without "run this next" hints. |
| `CHECKPOINT_DISABLE=1` | No HashiCorp version/announcement check. |
| `TF_PLUGIN_CACHE_DIR=/opt/terraform-plugin-cache` | Provider cache; the setup script creates the directory. |
| `AZURE_CORE_COLLECT_TELEMETRY=false` | `az` telemetry off. |
| `TF_VAR_dns_zone_name`, `TF_VAR_dns_rg_name` | Stand-ins for the gitignored `terraform.tfvars` files, which a cloud clone does not have — the same two values CI feeds from its `DNS_ZONE_NAME` / `RESOURCE_GROUP_NAME` secrets. `fleet.tfvars` is committed and needs no variable. |

`CLAUDE_CODE_REMOTE=true` is set by Claude Code itself in every cloud session; it is what makes the
hook and the skills take their cloud branch.

## Network allowlist

Network access is **Custom**: the default package-manager list plus —

| Host | Needed for |
|---|---|
| `registry.terraform.io` | Provider metadata (`terraform init`). |
| `management.azure.com` | Azure Resource Manager: every provider read, and `az` queries. |
| `graph.microsoft.com` | Microsoft Graph: `az` principal lookups (`az ad ...`, role assignment listing). |
| `listeninfratfstatesa.blob.core.windows.net` | The Terraform state backend (blob data plane). |
| `api.ipify.org` | The data source in `infra/network` that fetches the caller's IP for the NSG SSH rule — the source of the expected plan diff. |

**Deliberately not allowed: `api.cloudflare.com`.** `infra/cloudflare` cannot be planned from a cloud
session, and no Cloudflare credential belongs in this environment.

**Also required, but not on that list.** Probed on 2026-10-08, these answered without having been added,
so the default list evidently covers them. If the policy is ever tightened to an explicit-only list, add
them or sign-in and `init` break:

- `login.microsoftonline.com` — the Entra token endpoint, for `az login` and for Terraform's own sign-in.
- `releases.hashicorp.com` — the setup script's Terraform download, and where `terraform init` fetches
  provider binaries from (`registry.terraform.io` serves only metadata).

**Observed and harmless:** in a fresh `az` config directory every `az` command, even `az version`, tries
`azcliprod.blob.core.windows.net` (`az`'s command and extension index). It is not allowlisted, the policy
refuses the connection, and `az` carries on. Nothing in this repo needs `az` extensions; if one ever
does, that is the host to add. Refused hosts are listed by the proxy's status endpoint —
`curl -sS "$HTTPS_PROXY/__agentproxy/status"` — which is the first thing to read when a tool reports
`CONNECT tunnel failed, response 403`.

## Setup script

Installs Terraform at the version pinned in `.terraform-version`, the Azure CLI from Microsoft's apt
repository, and the plugin cache directory. It lives in the environment's *Setup script* field in the UI;
this is the copy of record. **`TF_VERSION` must match `.terraform-version`** — see *When
`.terraform-version` changes*.

```bash
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

TF_VERSION=1.9.8   # keep in sync with .terraform-version

apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl gnupg unzip lsb-release

curl -fsSLo /tmp/terraform.zip \
  "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip"
unzip -o /tmp/terraform.zip terraform -d /usr/local/bin
rm -f /tmp/terraform.zip

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/azure-cli.list
apt-get update -y
apt-get install -y azure-cli

install -d -m 1777 /opt/terraform-plugin-cache
terraform version
az version
```

It does not install `jq`, which the sign-in hook uses for its Terraform version check; the cloud image
already has it (jq 1.7 on 2026-10-08), and the hook says so and carries on if it ever does not.

## How a session signs in

1. The session starts in the `homelab` environment with the variables above and `CLAUDE_CODE_REMOTE=true`.
2. The `SessionStart` hook in `.claude/settings.json` (matcher `startup|resume`, synchronous, 60 s)
   runs `scripts/cloud-session-init.sh`. It runs `az login --service-principal` unless `az` is already
   signed in as this identity, selects the subscription, compares `terraform version` with
   `.terraform-version`, and prints one line — which reaches the session as context — saying it is the
   read-only identity and that cloud sessions are plan-only. It always exits 0.
3. Terraform needs no sign-in of its own; azurerm and the backend read `ARM_*` directly.
4. **Project threads and multi-repo sessions run no repo hooks.** There, `az` is not signed in until
   `bash scripts/cloud-session-init.sh` is run by hand — which is safe to repeat. A session that finds
   `az account show` failing should run it rather than ask the user to `az login`.

## Verifying a session

```bash
echo "$CLAUDE_CODE_REMOTE"                                  # true
[ -n "$ARM_CLIENT_ID" ] && echo "ARM_CLIENT_ID is set"       # never print the value
bash scripts/cloud-session-init.sh                          # "Azure: signed in as read-only identity ..."
az account show --query '{name:name, principal:user.type}' -o table   # principal: servicePrincipal
terraform version                                           # must equal: cat .terraform-version
```

Then `/tf-plan infra/network`: `init` works against the Entra-auth backend and the plan completes. The
NSG SSH-rule diff is expected — `api.ipify.org` returns the session's egress IP, not the operator's.

Last verified on 2026-10-08 (`az` 2.91.0, Terraform 1.9.8): the script signed `az` in, and `init` and `plan`
for `infra/network`, `infra/dns`, `infra/storage` and `compute/vm` all completed, with no `AuthorizationFailed`.

## Rotating the secret

```bash
# 1. Mint a new secret. Without --append this invalidates the old one at once, which is
#    what you want after a suspected leak.
az ad app credential reset --id <appId> --display-name claude-cloud-<yyyymm> --years 1 --query password -o tsv

# 2. Paste it into ARM_CLIENT_SECRET in the homelab environment (claude.ai); clear the terminal.
# 3. Start a NEW session — a running one keeps the old value — and confirm the hook prints its
#    "signed in" line.
```

To avoid the gap between step 1 and step 2, add `--append`, update the variable, confirm a new session
signs in, then delete the old credential: `az ad app credential list --id <appId> -o table` shows each
credential's key ID and end date, and `az ad app credential delete --id <appId> --key-id <keyId>` removes one.

**Expiry** is one year from creation (the default); put a reminder in a calendar. An expired secret shows
up as the hook printing `az login failed (AADSTS7000222)`, and Terraform fails the same way.

To retire the identity entirely, delete the app registration (`az ad app delete --id <appId>`), which
removes the service principal with it, and clean up the two role assignments it leaves orphaned.

## When `.terraform-version` changes

Dependabot does not touch this file (its config covers GitHub Actions and the Terraform providers), so
a bump is a deliberate change, and the cloud environment is a second place that has to follow it.

1. Change `.terraform-version`. CI follows on its own: `_terraform.yml` reads the file.
2. Change `TF_VERSION` in the environment's setup script in the claude.ai UI **and** in the copy above.
3. Change the literal in `.github/copilot-instructions.md` ("CLI pinned to `.terraform-version` = ...").
4. Saving the setup script invalidates the environment's cache, so the next *new* session rebuilds it
   and starts slowly.
5. Until step 2 is done the SessionStart hook says so at the top of every session —
   `Terraform X installed but .terraform-version pins Y` — and plans are running on a Terraform CI does
   not use. Fix the script, not the pin.

## Known limits

- **Plan-only.** The identity is read-only. Never `apply`, `destroy`, `import`, `state rm`/`state mv` or
  `force-unlock` from a cloud session; applies go through GitHub Actions or a local run as Owner.
  `verify-persistence` refuses to run here for the same reason.
- **Cloudflare is excluded.** No token, and `api.cloudflare.com` is not allowlisted, so `infra/cloudflare`
  cannot be planned. Its plan comes from CI on the PR, or a local run.
- **`infra/identity` and `infra/backup` stay local.** Owner-only bootstraps with no workflow; they are
  not part of the cloud flow or of `/tf-plan all`.
- **Project threads and multi-repo sessions skip repo hooks**, so `az` is not signed in until the script
  is run by hand (Terraform works regardless).
- **The environment cache rebuilds about every 7 days, or whenever the setup script changes.** The first
  session after a rebuild starts slowly; nothing is lost.
- **`terraform init` dirties the working tree.** On a fresh cloud clone it adds `h1:` hashes for the
  session's platform to the tracked `.terraform.lock.hcl` files (observed on 2026-10-08: all four
  modules planned, each lock file gained one or two hash lines). That is churn, not a change anyone
  intended: `git checkout -- '*.terraform.lock.hcl'` after planning, and never commit it unless the
  task is a provider bump.
- **Unlocked plans are advisory.** With `-lock=false` a plan can read state while a CI apply is in
  flight and show a transient diff. Re-plan once the apply has finished.
- **`az` keeps the secret on disk.** `az login --service-principal` takes the secret as an argument
  (briefly visible in the container's process list) and stores it in plaintext in
  `~/.azure/service_principal_entries.json`, mode 0600 — confirmed on 2026-10-08. It sits in the
  container's filesystem for the life of the session, next to the same value in the environment
  variables, so it adds no exposure beyond them.
- **Do not paste raw plan or `az` output into committed files or PR text.** It carries subscription and
  resource IDs, and `main` is mirrored publicly. Summarise instead.

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| Hook: `ARM_* not set on this cloud environment` | The session is not running in the `homelab` environment, or a variable was removed | Start the session in `homelab`; check the variable *names* in the UI |
| Hook: `az login failed (AADSTS7000222)` | The client secret has expired | Rotate it (above) |
| Hook: `az login failed (AADSTS7000215)` | The secret value is wrong: the secret *ID* was pasted instead of its *value*, there is stray whitespace, or it was rotated and the variable not updated | Re-copy it, or rotate |
| Hook: `az login failed (AADSTS700016)` | `ARM_CLIENT_ID` or `ARM_TENANT_ID` does not match the app registration, or the app was deleted | Compare with `az ad sp list --display-name homelab-claude-cloud-reader`; recreate it if it is gone |
| Hook: `az login failed with no AADSTS code` | The network, not the credential: `login.microsoftonline.com` is unreachable | Read the proxy status endpoint; fix the egress policy |
| Hook: `Terraform X installed but .terraform-version pins Y` | The setup script's `TF_VERSION` is stale | *When `.terraform-version` changes* |
| `terraform init`: `Failed to query available provider packages`, or a 403 on a download | `registry.terraform.io` or `releases.hashicorp.com` is not allowed | Allow it |
| `terraform init`: backend `AuthorizationPermissionMismatch`, or an error naming `listKeys` | `ARM_USE_AZUREAD` is not `true`, or the `Storage Blob Data Reader` grant on the `tfstate` container is missing or still propagating (a minute or so) | Check both |
| Plan: `AuthorizationFailed` | The identity lacks the one action the error names | **Report that exact action and stop.** The owner decides whether to grant it. Never widen to `Contributor` |
| Plan: `No value for required variable` | `TF_INPUT=0` turns a prompt into an error: a `TF_VAR_*` is unset, or `-var-file=../../fleet.tfvars` was left off (`compute/vm`, `infra/storage`) | Supply it |
| A tool reports `CONNECT tunnel failed, response 403` | The host is not on the allowlist — by design for `api.cloudflare.com` | Do not work around it |
| The first session after a setup-script change is slow | The environment cache is rebuilding | Wait |

The `AADSTS` meanings are from Microsoft's Entra error reference.

## Related

- [`CLAUDE.md`](../../CLAUDE.md) — *Cloud sessions* under *Local setup*: the rules a session follows.
- [`.claude/hooks/README.md`](../../.claude/hooks/README.md) — the SessionStart hook.
- [`oidc_bootstrap.md`](../oidc_bootstrap.md) — the keyless CI identity this one is the exception to.
- [`technical_reference.md`](../technical_reference.md#credential-inventory-post-e024-36) — the credential inventory, which lists this identity.
