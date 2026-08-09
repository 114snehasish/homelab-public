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

Both credentials use issuer `https://token.actions.githubusercontent.com` and audience
`api://AzureADTokenExchange`.

The identity gets its own resource group rather than living in `homelab-rg`, because E02.2
(#34) grants it Contributor over `homelab-rg` — an identity that can delete itself is one bad
apply away from locking CI out of Azure.

**After this module applies, the identity has zero permissions.** GitHub can prove who it is to
Azure, and Azure lets it do nothing at all. That is the intended end state of E02.1 (#33); RBAC
arrives in #34, and the workflow cutover in #35. Nothing about CI changes when this lands.

## Step 0 — register the resource provider (out-of-band, once)

```bash
az provider show --namespace Microsoft.ManagedIdentity --query registrationState -o tsv
# if it is not "Registered":
az provider register --namespace Microsoft.ManagedIdentity
```

The azurerm 5.x provider defaults `resource_provider_registrations = "none"` (see CLAUDE.md), so
Terraform will **not** register this for you. Skipping this step fails the apply with an error
that talks about an unsupported API version rather than a missing registration.

## Step 1 — apply locally

```bash
# Azure credentials come from the gitignored root .env (ARM_CLIENT_ID,
# ARM_CLIENT_SECRET, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID)
set -a; source .env; set +a

cd infra/identity
terraform init
terraform plan     # expect 4 to add, 0 to change, 0 to destroy
terraform apply
```

No `terraform.tfvars` is needed — every variable has a default.

The service principal doing this apply needs rights to create a resource group and a managed
identity at subscription scope. That is the same SP that already runs every module today, so no
new grant should be required.

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

Both subjects must appear exactly as listed in the table above. Then confirm the identity is
genuinely inert:

```bash
az role assignment list --assignee <principal_id> --all -o table
# MUST return nothing — this is E02.1's acceptance criterion
```

If that command returns any role, something outside this module granted it; investigate before
proceeding to #34.

## Recovery / re-bootstrap

The UAMI carries `prevent_destroy = true`. To intentionally tear it down you have to remove
that `lifecycle` block first — treat needing to as a signal to stop and think.

Recreating the identity mints a **new `client_id`**. After any recreate you must re-apply #34's
role assignments and update the repo variables from #35, or every workflow run fails
authentication.

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
