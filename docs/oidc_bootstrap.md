# Runbook: Bootstrapping the GitHub OIDC Identity

This is the one module in the repo that is **applied locally, by hand, once**. Everything else
goes through GitHub Actions.

## Why this module is special

`infra/identity` creates the Azure identity that GitHub Actions will eventually authenticate
*as*. It cannot deploy itself through CI, because the credential CI would need to run it is the
very thing it creates. That chicken-and-egg is resolved the boring way: one local apply as the
subscription owner (`az login`), documented here. It was originally applied with the old service
principal's secret, which E02.4 (#36) has since retired.

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
what each one is for and what it deliberately excludes. Since the E02.3 cutover (#35), **every
Terraform workflow in the repo authenticates as this identity** — there is no client-secret
fallback left in CI, so this module is now a hard dependency of the whole pipeline.

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

### 0b — confirm whoever applies this can hand out roles

```bash
az login
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" --all -o table
```

Creating a role assignment needs `Microsoft.Authorization/roleAssignments/write` — i.e. **Owner
or User Access Administrator**, at each scope being granted. Contributor is not enough, however
much else it can do; this is the one permission Contributor pointedly excludes, so that a
compromised Contributor cannot promote itself.

**This lab's SP did not have it.** That is settled, not hypothetical — the first real apply of
this module failed with a 403 on `roleAssignments/write`. So step 1 below applies as yourself.

> **Historical, as of E02.4 (#36).** That service principal is retired: its client secret was
> rotated and then removed in Entra, so it can no longer authenticate at all. The command above
> is kept because it is still the right check to run against *whatever* identity you are about
> to apply as — substitute your own principal. "Cannot create role assignments" was the last
> confirmed entry in the inventory #36 took before retiring the credential.

## Step 1 — apply locally

Apply this module as **yourself**. Since E02.4 (#36) that is not merely the recommended route,
it is the only one that exists: the service principal this repo used to authenticate with holds
no client secret any more, and the CI identity deliberately has no rights over
`homelab-identity-rg` — nor `roleAssignments/write` anywhere.

```bash
az login
az account set --subscription <subscription_id>

# Load the subscription ID only — NOT the credentials.
export ARM_SUBSCRIPTION_ID=<subscription_id>
unset ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_TENANT_ID
```

> **The `unset` is still the load-bearing line.** `ARM_CLIENT_ID` + `ARM_CLIENT_SECRET` take
> precedence over your `az login` session: with them set, the azurerm provider tries to
> authenticate as the service principal no matter who is logged into the CLI. Before #36 that
> meant silently applying *as the SP*; now that the SP has no secret, it means failing
> authentication outright while looking as though your `az login` did not take. Either unset
> them, or use a fresh shell that never exported them.

`ARM_SUBSCRIPTION_ID` is safe to keep and is still required — it is an identifier, not a
credential. Your account needs Owner or User Access Administrator over the three scopes in step
4, plus the rights to create a resource group and a managed identity.

### Then

```bash
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

### The service-principal path is gone

An earlier version of this runbook offered a second route: source the SP credentials from the
gitignored root env file, after granting that principal User Access Administrator at the three
scopes. E02.4 (#36) removed the credential, so that path no longer exists — and it was always
the worse one, since it widened a long-lived secret for a single one-time apply.

### When it goes wrong

The characteristic failure: `plan` succeeds, then `apply` dies on the first
`azurerm_role_assignment` — having already created the RG, the UAMI and the federated
credentials. The error carries a **403** with `Code="AuthorizationFailed"` and names the action
`Microsoft.Authorization/roleAssignments/write` over one of the three scopes, attributed to the
service principal's client ID rather than to you. (Exact wording varies with the provider
version; those three markers are what identify it.)

That was the retired service-principal path without the User Access Administrator grant — most
often because the shell still carried `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`, so Terraform
authenticated as the SP even though `az login` had been run as a human. Post-#36 the same stale
variables fail at *authentication* instead, since the secret they carry is no longer valid —
different error, same root cause. Fix it the same way: `az login`, run the `unset` above, re-run
`terraform apply`. The partial apply is not a problem:
Terraform recorded what it created, and the re-run adds only the three role assignments.

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
break-glass path is a local apply as the owner via `az login` (roadmap risk **R8**; before E02.4
it was the service principal). If the RG is ever lost, recreate it locally, then re-apply
`infra/identity` to restore the role assignment that went down with it.

### Backend auth: `ARM_USE_AZUREAD` is not optional

Granting blob-data access only pays off if Terraform actually uses it. Left to itself, the
azurerm backend resolves state access by calling `listKeys` on the storage account — which this
identity cannot do — and fails during `terraform init`, before validate or plan. Any OIDC run
must set **both** `ARM_USE_OIDC=true` and `ARM_USE_AZUREAD=true`; `_terraform.yml` does this in
its `Use OIDC federated credentials` step.

## Step 5 — prove it end to end

The identity can only be assumed from a GitHub Actions run, so the functional proof lives in CI.
Since E02.3 (#35), that proof is the ordinary `deploy-*.yml` PR plans: they authenticate as this
UAMI, take a lease on each module's state blob, and read across `homelab-rg` plus the one SSH key
in `do-not-delete`. A green set of PR plans means the identity's *positive* grants are intact.

It needs the repo **variables** `ARM_CLIENT_ID`, `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID` from
step 2 to exist: Settings → Secrets and variables → Actions → *Variables*. Every workflow in the
repo reads the same three — if they are wrong or missing, nothing that touches Azure can run.

### What the PR plans do not prove

Three things, worth knowing before trusting a green check:

- **Only the `:pull_request` credential is exercised.** The `:ref:refs/heads/main` credential is
  used by push-to-`main` runs and by every `workflow_dispatch` — including all applies. A PR
  going green says nothing about it.
- **No ARM write.** Plans only read. `Contributor` on `homelab-rg` is not exercised until an
  apply runs.
- **No state *content* write.** Acquiring the lock is a lease, which does require a write-class
  data action (`Storage Blob Data Reader` cannot lease), but Terraform only writes the state blob
  on apply.

All three close with one action: dispatch `deploy-storage.yml` from `main` with apply checked.
That run uses the `main` credential, performs a real ARM write, and writes state.

### Removed: `oidc-smoke.yml`

A dedicated smoke workflow existed from E02.2 and was deleted in E02.3 (#35) once its five plan
jobs duplicated the `deploy-*.yml` PR plans. Deleting it cost two things that nothing else
covers, both deliberate and both worth re-reading before assuming CI has you covered:

- **Nothing asserts what the identity *cannot* do.** The deleted `negative-access` job proved the
  UAMI could not read RG `do-not-delete`, could not `listKeys` on the state storage account, and
  could not see its own resource group — with a positive control so a broken login could not fake
  a pass. Every remaining check proves the identity *can* do something. A change that quietly
  widens the grants — a broadened scope, a role added out of band, a future module reaching past
  `homelab-rg` — now goes unnoticed.
- **`infra/identity/**` and `_terraform.yml` have no Terraform coverage.** No `deploy-*.yml` path
  filter matches either, so a PR touching only those runs no plan at all.

To restore the assertions, recover the file verbatim from git history:

```
git log --oneline --diff-filter=D -- .github/workflows/oidc-smoke.yml
git show <commit>^:.github/workflows/oidc-smoke.yml > .github/workflows/oidc-smoke.yml
```

The cheap version is to bring back the `negative-access` job alone, on a schedule or as
dispatch-only — it needs no Terraform, just `azure/login@v2` and four `az` calls. If you do,
one rule holds: **never trim a job to turn a red check green.** A failure there means a
prerequisite is genuinely missing — during E02.2 it correctly caught a data disk deleted out of
band, on both auth paths.

## Recovery / re-bootstrap

The UAMI carries `prevent_destroy = true`. To intentionally tear it down you have to remove
that `lifecycle` block first — treat needing to as a signal to stop and think.

Recreating the identity mints a **new `client_id`** and a new `principal_id`. Terraform
re-creates the three role assignments for you in the same apply — they reference the UAMI
directly — but the repo variables are yours to update, or every workflow run fails
authentication. To confirm afterwards, open a trivial PR touching any module directory and check
its plan goes green, or dispatch `deploy-storage.yml` from `main` with apply unchecked.

Since E02.3 (#35) this is a full CI outage, not a degraded mode: every Terraform workflow
authenticates as this identity, so the window between recreating the UAMI and updating the repo
variables is a window in which nothing deploys. Break-glass is a local apply **as the owner**
(`az login`, then `export ARM_SUBSCRIPTION_ID=<id>` with the `ARM_CLIENT_*` variables unset).
That is the escape hatch behind roadmap risk **R8**, and since E02.4 (#36) retired the service
principal it is the only credential outside CI that can still reach Azure — and the only way to
act on Azure at all during that window.

## Branch scoping of the `push:` triggers (closed in E02.3, #35)

Only two subjects are trusted: `:ref:refs/heads/main` and `:pull_request`. A run's subject is
`repo:114snehasish/homelab:ref:refs/heads/<branch>` on push, so **a push run on any branch
other than `main` can only fail at auth.**

`deploy-*.yml` originally triggered on `push:` with a path filter and no branch filter, which
was harmless while CI used a client secret and would have failed every feature-branch push once
OIDC became the only path. #35 closed it by adding `branches: [main]` to all five `push:`
triggers; `pull_request` runs, whose subject matches, are what give a feature branch its plan.
Any workflow added later that touches Azure needs the same treatment.

Keep it that way. A wildcard federated credential is the wrong fix — it would trust every
branch in the repo, including one an attacker with push access could create.

The same rule governs `workflow_dispatch`, which inherits the ref it is dispatched from: run
`deploy.yml`, `destroy.yml` and manual applies **from `main`**. Dispatching from a branch fails
at auth. This is also why a gated apply cannot be proven on a PR — it has to happen after merge.
