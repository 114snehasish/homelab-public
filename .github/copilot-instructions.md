# Copilot instructions

Personal Azure homelab as infrastructure-as-code: **pure Terraform + GitHub Actions**. No
application code, no unit tests, no Makefile. Deeper background lives in `CLAUDE.md`, `docs/`
(conceptual guide, technical reference, OIDC runbook, ADRs, roadmap), and the `.claude/skills/`.

## Layout

Six **independent root modules**, each with its own remote state (backend
`listeninfratfstatesa`, container `tfstate`, key `homelab.<module>.tfstate`):

`infra/identity` · `infra/network` · `infra/dns` · `infra/cloudflare` · `infra/storage` · `compute/vm`

Terraform `>= 1.9` (CLI pinned to `.terraform-version` = `1.9.8`), provider `azurerm ~> 5.0`
(`features {}` only), region `southindia`.

## Commands

There is nothing to build and no test suite — validation is Terraform + linters. Run everything
per module from the repo root:

```bash
terraform -chdir=<module> fmt -check -recursive   # fix with: terraform -chdir=<module> fmt -recursive
terraform -chdir=<module> init -input=false
terraform -chdir=<module> validate
terraform -chdir=<module> plan -input=false        # this is also how you "plan a single module"
```

- `.claude/skills/tf-plan/` wraps this pre-flight for one module or `all` (dependency order).
  A post-edit hook already runs `terraform fmt` on saved `.tf`/`.tfvars` files.
- **Lint (both blocking, repo-wide on any `.tf` change, separate from the module pipelines):**
  `tflint --recursive --config=.tflint.hcl` and Checkov. Silence unavoidable Checkov findings with
  an inline `# checkov:skip=<ID>:<reason>` placed **inside** the resource block (not above it).
- Never run `apply`/`destroy` while planning/reviewing — apply happens only through the gated CI
  workflows (below) or a deliberate local apply.

## Architecture

- **Deploy order matters and is by-name, not state-linked.** Later modules find earlier ones'
  resources through `data` sources keyed on resource *names* (there is no `terraform_remote_state`
  wiring), so renaming a resource silently breaks every downstream module. Order:
  `identity → network → dns → cloudflare → storage → compute/vm`.
- **`infra/identity` is a one-time local bootstrap with no workflow** — it creates the very managed
  identity CI authenticates as, so it can't deploy itself. Runbook: `docs/oidc_bootstrap.md`.
- **"Cattle VM, pet disk".** `compute/vm` is disposable (destroy/recreate is routine); the
  `infra/storage` data disk carries `prevent_destroy = true` and must always survive. cloud-init
  only formats the disk if it is unformatted.
- **CI is layered reusable workflows.** Each `deploy-*.yml` is a thin wrapper over
  `.github/workflows/_terraform.yml`; `deploy.yml` chains all five in order; `destroy.yml`
  (compute → cloudflare only, skipping the pet disk) also wraps `_terraform.yml` with
  `destroy: true`. Every module runs **plan** on push/PR and **applies only** via manual
  `workflow_dispatch` with an apply checkbox (default off). Deploy `push:` triggers are pinned to
  `branches: [main]` — feature branches get their plan from the `pull_request` trigger.

## Auth (keyless OIDC)

- **CI:** authenticates as the `infra/identity` UAMI over OIDC using repo **variables**
  `ARM_CLIENT_ID` / `ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID` (identifiers, not secrets) plus
  `ARM_USE_OIDC=true` and `ARM_USE_AZUREAD=true` (the latter is load-bearing — without it the
  backend tries `listKeys`, which the identity is deliberately denied, and `init` fails). No client
  secret exists anywhere.
- **Local:** `az login` as yourself, then `export ARM_SUBSCRIPTION_ID=<id>`. Keep
  `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` **unset** — if exported they override the
  `az login` session and every plan fails auth.
- Remaining repo secrets are all non-Azure: `DNS_ZONE_NAME`, `RESOURCE_GROUP_NAME`, `CLOUDFLARE_*`,
  mirror tokens.

## Conventions

- Naming: Azure resources `homelab-*` (kebab-case); Terraform resource labels `homelab_*`
  (snake_case).
- Branches: snake_case topical names, PR into `main` (merge commits).
- `infra/dns`, `infra/cloudflare`, and `compute/vm` each need a gitignored `terraform.tfvars`
  copied from `terraform.tfvars.example` — ask for values, never invent them.
- NSG rules live in `infra/network`'s `var.nsg_rules`; the subnet is the single owner of NSG policy
  (ADR-0012), so `compute/vm` has no NIC-level NSG association.
- Update `docs/` when you add or change a module.

## Don't do this

- **Never import, modify, or destroy** the pre-existing, externally-managed resources: RG
  `do-not-delete`, storage account `listeninfratfstatesa` (the state backend), and SSH public key
  `homelab-vm-ssh-key-2` (read by `compute/vm`'s data source).
- **`main` is force-mirrored to a public GitHub repo on every push** (`mirror.yml`) — treat
  everything committed as public and never commit tfvars, keys, or `.env`. A `.claude/` guardrail
  blocks tool access to `.env` files as defense-in-depth.
- cloud-init (`compute/vm/cloud-init.yaml`) is coupled to the data disk LUN: it expects
  `/dev/disk/azure/scsi1/lun10`, so changing `var.data_disk_lun` breaks the mount. The file is read
  with `filebase64` (not `templatefile`), so its `${DISK}1` is a shell expansion — don't switch to
  `templatefile()` without escaping.

## Expected plan noise

The `infra/network` NSG SSH rule whitelists the public IP of whoever runs the plan (fetched live
from api.ipify.org) unless `ssh_source_ip` is set, so **local and CI plans always disagree on that
one rule** — it is not real drift.
