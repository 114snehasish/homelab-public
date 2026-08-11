# Runbook: Bootstrapping the GitHub OIDC Identity

This is the one module in the repo that is **applied locally, by hand, once**. Everything else
goes through GitHub Actions.

## Why this module is special

`infra/identity` creates the Azure identity that GitHub Actions will eventually authenticate
*as*. It cannot deploy itself through CI, because the credential CI would need to run it is the
very thing it creates. That chicken-and-egg is resolved the boring way: one local apply with the
existing service principal, documented here.

There is deliberately **no `deploy-identity.yml`**. The five module workflows stay as they are.

## What it creates

| Resource | Name |
|---|---|
| Resource group | `homelab-identity-rg` |
| User-assigned managed identity | `homelab-github-actions-identity` |
| Federated credential (main) | `homelab-github-main` → subject `repo:114snehasish/homelab:ref:refs/heads/main` |
| Federated credential (PRs) | `homelab-github-pull-request` → subject `repo:114snehasish/homelab:pull_request` |
| Role assignment | `Contributor` on `homelab-rg` |
| Role assignment | `Storage Blob Data Contributor` on the `tfstate` container |
| Role assignment | `Reader` on the `homelab-vm-ssh-key-2` resource |

Both credentials use issuer `https://token.actions.githubusercontent.com` and audience
`api://AzureADTokenExchange`.

The identity gets its own resource group rather than living in `homelab-rg`, because E02.2
(#34) grants it Contributor over `homelab-rg` — an identity that can delete itself is one bad
apply away from locking CI out of Azure.

The three role assignments are E02.2 (#34); see [Step 4](#step-4--the-rbac-grants-e022) for
what each one is for and what it deliberately excludes. The workflow cutover is still #35 —
nothing in CI authenticates as this identity yet, apart from the plan-only
`oidc-smoke.yml`.

## Step 0 — prerequisites (out-of-band, once)

### 0a — register the resource provider

```bash
az provider show --namespace Microsoft.ManagedIdentity --query registrationState -o tsv
# if it is not "Registered":
az provider register --namespace Microsoft.ManagedIdentity
```

The azurerm 5.x provider defaults `resource_provider_registrations = "none"` (see CLAUDE.md), so
Terraform will **not** register this for you. Skipping this step fails the apply with an error
that talks about an unsupported API version rather than a missing registration.

### 0b — confirm the bootstrap SP can hand out roles

```bash
az role assignment list --assignee "$ARM_CLIENT_ID" --all -o table
```

Creating a role assignment needs `Microsoft.Authorization/roleAssignments/write` — i.e. **Owner
or User Access Administrator**, at each scope being granted. Contributor is not enough, however
much else it can do; this is the one permission Contributor pointedly excludes, so that a
compromised Contributor cannot promote itself.

If the SP in `.env` is only Contributor, you have two options: grant it User Access
Administrator over the three scopes, or run the apply as yourself (`az login` with your own
admin account, unset the `ARM_*` vars) — the resources are identical either way.

Keep the output of that command: E02.4 (#36) needs an inventory of the old SP's
subscription-level rights before it retires the credential, and #34's PR description is where
it gets recorded.

## Step 1 — apply locally

```bash
# Azure credentials come from the gitignored root .env (ARM_CLIENT_ID,
# ARM_CLIENT_SECRET, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID)
set -a; source .env; set +a

cd infra/identity
terraform init
terraform plan     # from scratch: 7 to add, 0 to change, 0 to destroy
terraform apply
```

No `terraform.tfvars` is needed — every variable has a default.

Seven resources: the RG, the UAMI, two federated credentials, three role assignments. On a
subscription where E02.1 already applied, only the three role assignments are new. Whatever the
count, the plan must show **0 to change and 0 to destroy** — `listeninfratfstatesa`, RG
`do-not-delete` and the SSH key are read through data sources and must never appear as managed
resources.

The service principal doing this apply needs rights to create a resource group and a managed
identity at subscription scope — the same SP that already runs every module today — **plus** the
role-assignment rights from step 0b, which it may well not have.

## Step 2 — record the outputs

```bash
terraform output
```

`client_id`, `tenant_id` (plus your subscription ID) become the **repo variables** in E02.3
(#35) — Settings → Secrets and variables → Actions → *Variables*, not Secrets. They are
identifiers, not credentials. `principal_id` is what E02.2 (#34) attaches role assignments to.

## Step 3 — verify

```bash
az identity show -g homelab-identity-rg -n homelab-github-actions-identity -o table

az identity federated-credential list \
  -g homelab-identity-rg \
  --identity-name homelab-github-actions-identity \
  --query "[].{name:name, subject:subject, issuer:issuer, audience:audiences[0]}" -o table
```

Both subjects must appear exactly as listed in the table above. Then confirm the grants:

```bash
az role assignment list --assignee <principal_id> --all \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

Exactly three rows, matching `terraform output granted_scopes`. **Nothing at subscription
scope** — a `/subscriptions/<id>` scope with no resource group after it means something granted
this identity far more than #34 intends; find out what before going near #35.

> Before #34, this command had to return *nothing at all* — that was E02.1's acceptance
> criterion, and it is what makes the E02.1 checkpoint safely inert.

## Step 4 — the RBAC grants (E02.2)

| Role | Scope | Why |
|---|---|---|
| `Contributor` | RG `homelab-rg` | Manage every resource the five modules deploy — VNet, NSG, DNS zone, disk, VM. The lab's entire blast radius, and no wider. |
| `Storage Blob Data Contributor` | `…/listeninfratfstatesa/blobServices/default/containers/tfstate` | Read, write and lease (state lock) the `homelab.<module>.tfstate` blobs. |
| `Reader` | `…/do-not-delete/providers/Microsoft.Compute/sshPublicKeys/homelab-vm-ssh-key-2` | `compute/vm` reads this key by name; without it, every VM plan fails on the data source. |

What is deliberately **not** granted, and why it matters:

- **No role on the storage account** — only on one container inside it. An account-scoped role
  brings `listKeys`, and a storage account key is a bearer credential for every container in
  the account. That is the class of credential this epic exists to delete.
- **No read over RG `do-not-delete`** — the SSH key grant is scoped to the single key resource,
  not the RG that happens to hold it.
- **No rights over `homelab-identity-rg`** — CI cannot modify or delete the identity it runs
  as, which is the entire reason that RG exists separately.
- **Nothing at subscription scope.** This works only because azurerm 5.x defaults
  `resource_provider_registrations = "none"`; under 4.x the provider registered resource
  providers at subscription scope on every run and would fail here.

### The consequence to remember: CI cannot recreate `homelab-rg`

`infra/network` declares `azurerm_resource_group.homelab_rg`, but a role assignment scoped to a
resource group is stored *on* that resource group and dies with it — and creating one is a
subscription-level write regardless. So CI can manage the existing `homelab-rg` and could never
bring it back after a deletion.

This is tolerable by design: `destroy.yml` deliberately never destroys `infra/network`, and the
break-glass path is a local apply with the SP from `.env` (roadmap risk **R8**). If the RG is
ever lost, recreate it locally, then re-apply `infra/identity` to restore the role assignment
that went down with it.

### Backend auth: `ARM_USE_AZUREAD` is not optional

Granting blob-data access only pays off if Terraform actually uses it. Left to itself, the
azurerm backend resolves state access by calling `listKeys` on the storage account — which this
identity cannot do — and fails during `terraform init`, before validate or plan. Any OIDC run
must set **both** `ARM_USE_OIDC=true` and `ARM_USE_AZUREAD=true`; `_terraform.yml` does this in
its `Use OIDC federated credentials` step.

## Step 5 — prove it end to end

The identity can only be assumed from a GitHub Actions run, so the functional proof lives in
CI: **`.github/workflows/oidc-smoke.yml`**, plan-only, with no apply path at all.

- It runs automatically on any PR touching `infra/identity/**`, `_terraform.yml`, or the smoke
  workflow itself. PR runs are what work pre-merge — their OIDC subject is
  `repo:114snehasish/homelab:pull_request`, which matches a federated credential, whereas a
  feature-branch push run's subject matches neither (see the known gap below).
- It can also be dispatched manually, once the file is on `main`.
- Five jobs plan the five modules as the UAMI; a sixth asserts what the identity *cannot* do —
  read RG `do-not-delete`, list the storage account keys, or see its own resource group — with
  a positive control (`az group show -n homelab-rg`) so a broken login cannot masquerade as a
  pass.

It needs the repo **variables** `ARM_CLIENT_ID`, `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID` from
step 2 to exist. Set them before the first run: Settings → Secrets and variables → Actions →
*Variables*. E02.3 (#35) reads the same three.

If that command returns any role, something outside this module granted it; investigate before
proceeding to #34.

## Recovery / re-bootstrap

The UAMI carries `prevent_destroy = true`. To intentionally tear it down you have to remove
that `lifecycle` block first — treat needing to as a signal to stop and think.

Recreating the identity mints a **new `client_id`** and a new `principal_id`. Terraform
re-creates the three role assignments for you in the same apply — they reference the UAMI
directly — but the repo variables are yours to update, or every workflow run fails
authentication. Re-run `oidc-smoke.yml` afterwards; that is exactly the regression it is there
to catch.

Break-glass throughout E02: local applies keep working with the SP in `.env` regardless of the
state of OIDC. That is the escape hatch behind roadmap risk **R8**.

## Known gap to close in E02.3 (#35)

The `deploy-*.yml` workflows trigger on `push:` with a path filter but **no branch filter**, so
a push to any feature branch starts a plan run. The OIDC subject for such a run is
`repo:114snehasish/homelab:ref:refs/heads/<branch>`, which matches neither federated credential.

Once #35 flips authentication to OIDC, those feature-branch push runs will fail at auth while
the paired `pull_request` run for the same commit succeeds — confusing, but not dangerous.

The fix belongs in #35, not here: add `branches: [main]` to the `push:` triggers, since
`pull_request` runs already cover feature branches. Adding a wildcard federated credential is
the wrong answer — it would trust every branch in the repo, including one an attacker could
push.
