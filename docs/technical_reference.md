# Technical Reference: Core Infrastructure

This document serves as the technical API reference for the **current foundational modules** of my homelab. 

As I expand the lab, new modules will be added, but these core components provide the essential runtime environment.

---

## 1. Project Structure (Current State)

```
.
├── compute
│   └── vm          # [Ephemeral] The Workload Node
├── infra
│   ├── identity    # [Control plane] CI's Azure identity (bootstrapped locally)
│   ├── network     # [Persistent] The Network Backbone
│   └── storage     # [Persistent] The Data Layer
├── .github
│   └── workflows   # CI/CD Pipelines
└── docs            # Documentation
```

---

## 2. Core Module: `infra/network`

**Purpose**: Sets up the foundational networking perimeter. I designed this to be the stable backbone that future services will plug into.

### Resources
- `azurerm_resource_group.homelab_rg`: The logistical container for my resources.
- `azurerm_virtual_network.homelab_vnet`: The address space (`var.vnet_address_space`, default 10.0.0.0/16) reserved for the lab.
- `azurerm_subnet.homelab_subnets`: One subnet per entry in `var.subnets`, keyed by subnet name. Today that map holds exactly one entry — `homelab-subnet` = 10.0.0.0/24, the public tier.
- `azurerm_network_security_group.homelab_nsg`: The security boundary.
- `azurerm_network_security_rule.homelab_nsg_rules`: One rule per entry in `var.nsg_rules`, keyed by rule name. Today: `Allow-SSH` at priority 100.
- `azurerm_subnet_network_security_group_association.homelab_nsg_assocs`: One per subnet — the NSG is owned at the subnet layer, per [ADR-0012](adr/0012-workload-tiering-cidr-and-nsg-ownership.md).

### Adding a subnet or a rule
Both are **map entries, not resource blocks** (#161). A subnet needs a name and
`address_prefixes` taken from ADR-0012's CIDR plan; a rule needs an explicit `priority`
— `for_each` iteration order must never be what decides one. A rule that omits
`source_address_prefix` inherits the SSH whitelist default: `var.ssh_source_ip` if set,
otherwise the public IP of whichever machine is running the plan (fetched live from
api.ipify.org), which is why local and CI plans always disagree on that one value.

---

## 3. Core Module: `infra/storage`

**Purpose**: Manages the persistent data assets. This is the "Vault" of my architecture.

### Resources
- `azurerm_managed_disk.homelab_data_disk`: The primary persistent store.
  - **Lifecycle**: Protected by `prevent_destroy = true`.
  - **Role**: currently hosts Docker data volumes; architected to exist independently of any specific compute instance.

---

## 4. Core Module: `compute/vm`

**Purpose**: The current execution environment. I designed this module to be highly disposable and replaceable.

### Resources
Every name this module *produces* derives from `var.instance_name` (default `homelab-vm`), so
the module is no longer welded to one node (#162):

- `azurerm_linux_virtual_machine.homelab_vm`: the Ubuntu host — named `${instance_name}`.
- `azurerm_network_interface.vm_nic`: `${instance_name}-nic`.
- `azurerm_public_ip.vm_public_ip`: `${instance_name}-public-ip`.
- ↳ `os_disk`: `${instance_name}-osdisk`.
- `azurerm_dns_a_record.vm_record`: the A record the VM registers for itself, labelled `${instance_name}`.
- `azurerm_virtual_machine_data_disk_attachment`: The dynamic link between the disposable VM
  and the persistent storage, at `var.data_disk_lun` (default 10).

**No NSG association lives here.** Per [ADR-0012](adr/0012-workload-tiering-cidr-and-nsg-ownership.md)
the subnet is the single owner of NSG policy; the NIC-level association this module used to
create was removed in #162. Rules are a property of the tier a node sits in, so they are
edited in `infra/network`'s `var.nsg_rules`.

**Outputs are scalars, not maps.** `public_ip` and `ssh_command` describe one node. They become
maps keyed by instance name in E17.6/E17.7 ([#165](https://github.com/114snehasish/homelab/issues/165)/[#166](https://github.com/114snehasish/homelab/issues/166)).

### State: partial backend config
Alone among the six modules, `compute/vm/backend.tf` carries **no `key`**. The state blob is
selected at `init` time (E17.4, [#163](https://github.com/114snehasish/homelab/issues/163)) so
one module directory can serve several instances, each with its own state:

```bash
terraform -chdir=compute/vm init -input=false -backend-config="key=homelab.compute.tfstate"
```

CI passes the same value as `_terraform.yml`'s `state_key` input. Locally, add `-reconfigure`
when switching instances inside one checkout, or Terraform reuses the cached backend and you
plan the wrong one. Keeping a literal `key` here *as well* was rejected: the file would carry a
lie, and a bare `init` would silently target instance zero.

### Adding a second instance
The CI half is done: a second instance is a matrix entry in `deploy-compute.yml` (its own
`state_key`, its own `instances/<name>.tfvars` — see `compute/vm/instances/README.md`), and
`_terraform.yml` keys the state blob, the concurrency group and the sticky PR comment off that
`state_key`, so two instances plan concurrently without colliding.

What is still missing is on the Terraform side: a managed disk cannot attach to two VMs
([#165](https://github.com/114snehasish/homelab/issues/165)), and this module's scalar outputs
plus the fleet-wide `destroy` in `.claude/skills/verify-persistence/` have to become
per-instance ([#166](https://github.com/114snehasish/homelab/issues/166)). A second node also
has to pass ADR-0012's "earns its own VM" test first — the default fleet stays at one.

### Automation (`cloud-init.yaml`)
The bootstrapping script is designed to:
1.  Detect the persistent storage at **LUN 10** (`var.data_disk_lun` and this file are a
    coupled pair — the LUN path `/dev/disk/azure/scsi1/lun10` is hardcoded in the script, so
    changing the variable alone breaks the mount).
2.  Safely mount it to `/data` (avoiding destructive formatting).
3.  Initialize the container runtime.

It is read with `filebase64(var.cloud_init_file)` and **not** `templatefile()`: the script's
`PARTITION="${DISK}1"` is a *shell* expansion, which `templatefile()` would try to interpolate
as Terraform (it would need escaping as `$${DISK}1`). The rewrite that revisits this is
[#99](https://github.com/114snehasish/homelab/issues/99).

---

## 5. Control-Plane Module: `infra/identity`

**Purpose**: Holds the Azure identity that GitHub Actions federates into, replacing the
long-lived service-principal secret with keyless OIDC (epic #15). Unlike every other module,
this one is **applied locally, once** — it cannot deploy itself through CI, because the
credential CI would need is the thing it creates. See the
**[🔑 OIDC Bootstrap Runbook](oidc_bootstrap.md)** for the procedure.

### Resources
- `azurerm_resource_group.homelab_identity_rg` (`homelab-identity-rg`): a dedicated RG, *not*
  `homelab-rg` — E02.2 (#34) grants this identity Contributor over `homelab-rg`, and an
  identity able to delete itself could lock CI out of Azure.
- `azurerm_user_assigned_identity.homelab_github_oidc` (`homelab-github-actions-identity`):
  protected by `prevent_destroy = true`, since recreating it mints a new `client_id` and
  invalidates both the role assignments and the repo variables that depend on it.
- `azurerm_federated_identity_credential.homelab_github_main` — subject
  `repo:114snehasish/homelab:ref:refs/heads/main` (covers dispatch-gated applies, which are
  always dispatched from `main`).
- `azurerm_federated_identity_credential.homelab_github_pull_request` — subject
  `repo:114snehasish/homelab:pull_request`.

Both credentials use issuer `https://token.actions.githubusercontent.com` and audience
`api://AzureADTokenExchange`.

### Role assignments (E02.2, #34)
Three `azurerm_role_assignment`s, each scoped as narrowly as the thing it enables:

| Role | Scope | Enables |
|---|---|---|
| `Contributor` | RG `homelab-rg` | Every resource the five modules deploy. |
| `Storage Blob Data Contributor` | the `tfstate` container in `listeninfratfstatesa` | State read/write plus the blob lease Terraform uses as its lock. |
| `Reader` | the `homelab-vm-ssh-key-2` resource in `do-not-delete` | `compute/vm`'s SSH-key data source — one resource, not the RG around it. |

The scopes are located by read-only data sources; nothing outside `homelab-identity-rg` is ever
managed by this module. Two grants are deliberately absent: anything at subscription scope, and
any role on the *storage account* (which would carry `listKeys`, a bearer credential for every
container in it — the exact credential class E02 exists to eliminate).

Because a role assignment lives on the scope it grants, CI can manage `homelab-rg` but could
never recreate it after a deletion. That is why `destroy.yml` stops short of `infra/network`,
and why the break-glass local apply matters (roadmap risk **R8**).

The blob grant only works when Terraform authenticates to storage with Entra rather than
account keys — `ARM_USE_AZUREAD=true`, set alongside `ARM_USE_OIDC=true` in `_terraform.yml`'s
OIDC credential step. Without it, `terraform init` fails at `listKeys` before validate runs.

### Outputs
`client_id`, `principal_id`, `tenant_id`, `uami_id`, `identity_rg_name`, `granted_scopes`. None
are secrets — they are identifiers, which is why E02.3 (#35) moves them into repo **variables**
rather than repo secrets. `granted_scopes` is the audit surface: diff it against
`az role assignment list --assignee <principal_id> --all`.

### Current state
Since E02.3 (#35) this identity carries **all** CI traffic: every `deploy-*.yml` and
`destroy.yml` authenticates as it, with no client-secret fallback anywhere in the pipeline.
E02.4 (#36) made that permanent — the leftover `ARM_*`/`AZURE_*` secrets are deleted from repo
settings and the old service principal's client secret is rotated out and removed in Entra, so
this UAMI is not merely the primary path to Azure from CI, it is the only one. Losing or
recreating it is therefore a full CI outage until the repo variables are updated; break-glass is
a local apply as the owner (`az login`) — see the recovery section of the bootstrap runbook.

The `oidc-smoke.yml` workflow that previously exercised it was deleted in the same change, once
its five plan jobs duplicated the `deploy-*.yml` PR plans. Two coverage gaps followed: nothing
now asserts what the identity *cannot* do (the `negative-access` job was the only such check),
and a PR touching only `infra/identity/**` runs no Terraform, since no `deploy-*.yml` path
filter matches it. Both are recoverable from git history if wanted.

There is still no `deploy-identity.yml`; the module's `.tf` files are covered by the repo-wide
`lint.yml` gate.

---

## 6. CI/CD Workflows

### Per-module pipelines

Each module has its own workflow, runnable standalone (push or pull_request with path filter, or manual dispatch) and callable as a reusable workflow (`workflow_call`):
- **`deploy-network.yml`**: Deploys the backbone.
- **`deploy-dns.yml`**: Creates the Azure DNS zone.
- **`deploy-cloudflare.yml`**: Delegates the subdomain from Cloudflare to Azure DNS.
- **`deploy-storage.yml`**: Provisions the vaults.
- **`deploy-compute.yml`**: Launches the nodes.

All five workflows — `deploy-network.yml`, `deploy-dns.yml`,
`deploy-cloudflare.yml`, `deploy-storage.yml`, and `deploy-compute.yml` —
are thin wrappers: their `jobs:` block only declares triggers/inputs, then
delegates the actual init → validate → plan → dispatch-gated apply sequence
to **`_terraform.yml`**, a `workflow_call`-only reusable workflow
parameterized by `working_directory` (module path), `apply`, an
optional `ssh_source_ip` (network only), `destroy` (`destroy.yml`
only — see below), and — since E17.4
([#163](https://github.com/114snehasish/homelab/issues/163)) —
`state_key` and `var_file`. `_terraform.yml` pins the
Terraform CLI version from the repo-root `.terraform-version` file and
runs its job under a `tf-<state_key or working_directory>` concurrency
group, so two runs touching the same **state blob** queue instead of racing.

`working_directory` used to be four identities at once — the checkout path,
the state identity, the lock identity and the PR-comment identity — which is
why no module could be planned twice. E17.4 split them:

- **`state_key`** (default empty) becomes `terraform init
  -backend-config="key=…"`. Empty means the module hardcodes its key in
  `backend.tf` and `init` runs bare, which is still true of all five modules
  except `compute/vm`.
- The **concurrency group** now derives from the state key when there is one,
  because the blob lease is the thing actually being protected. A module that
  passes no `state_key` keeps exactly the group it had before.
- The **sticky PR comment** is keyed by the same identity. Keyed by directory
  alone, two legs of one module found each other's comment through
  `includes(marker)` and raced to overwrite it.
- **`var_file`** appends `-var-file=…` to the plan (resolved relative to
  `working_directory`). It outranks the job-level `TF_VAR_*` `env:` block, so
  one instance can override a repo-wide value.

`deploy-compute.yml` is the only caller that fans out: its `uses:` job carries
a `strategy: matrix` with one entry per instance (one today, deliberately),
each supplying `name`, `state_key` and `var_file`. `deploy.yml →
deploy-compute.yml → _terraform.yml` is 3 of GitHub's 4 workflow-nesting
levels, so the matrix fits at this level and an extra wrapper workflow would
not. `destroy.yml`'s compute job passes the same `state_key` — it must, or a
destroy and a deploy of one node could run at once — and stays a single leg
until #166 adds a second instance.

All five also list `.github/workflows/_terraform.yml` in their `push` and
`pull_request` path filters (#153): without it, a PR that changed only the
shared workflow matched no filter and ran no Terraform at all, so the file
every module's CI depends on was the one file CI never exercised.

`destroy` (boolean, default `false`) switches the plan step to
`terraform plan -destroy`. It has no apply gate of its own — the saved plan
file is applied by the same `inputs.apply` step in either direction, which
keeps one gate to reason about on the only path that deletes real resources.

Since E02.3 (#35) there are **no per-module conditional steps** in
`_terraform.yml` at all. Every module authenticates the same way — one
unconditional step exporting `ARM_USE_OIDC`, `ARM_USE_AZUREAD` and the three
`ARM_*` identifiers from repo variables — and every `TF_VAR_*` value lives in
the shared job-level `env:` block.

Two `if: inputs.working_directory == ...` steps used to sit here, and both
were removed rather than relocated:

- The `AZURE_*` (dns/cloudflare) versus `ARM_*` (network/storage/compute)
  credential split disappeared with the client secret itself — one identity
  now serves all five modules. E02.4 (#36) then deleted both secret sets from
  repo settings outright, so the split is not merely unused, it is gone.
- `infra/dns` declared `rg_name`, colliding with the same-named variable in
  `infra/network`, `infra/storage` and `compute/vm`, so its value could not be
  set as a static `env:` entry without silently overriding those three
  modules' defaults. It was renamed `dns_rg_name` — which is what
  `compute/vm` already calls the same concept — so it now reads the
  `TF_VAR_dns_rg_name` entry the workflow already set for every module.
  The general rule: rename the colliding variable in the module; don't route
  around the collision in the pipeline.

Auth is still written via `$GITHUB_ENV` rather than a static `env:` entry.
The fork that once made this necessary is gone, but the property still holds —
a static entry silently wins over a same-named value written later to
`$GITHUB_ENV`, so anything added here would fail confusingly.

### Credential inventory (post-E02.4, #36)

The authoritative list of what exists and where. Diff repo Settings against it; anything else
under Azure is drift.

| Name | Where it lives | Notes |
|---|---|---|
| `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` | Repo **variables** (Settings → Secrets and variables → Actions → *Variables*) | Identifiers, not credentials. Read as `vars.*` in `_terraform.yml`. No same-named secrets remain — #36 deleted them. |
| `DNS_ZONE_NAME`, `RESOURCE_GROUP_NAME` | Repo secrets | Non-Azure-credential config, consumed as `TF_VAR_*`. |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID` | Repo secrets | The last real API credential in CI; migrates to Key Vault in E05.4. |
| `PUBLIC_REPO_URL`, `PUBLIC_REPO_TOKEN` | Repo secrets | `mirror.yml` only. |
| Local Azure auth | `az login` on the operator's machine | Owner identity + `ARM_SUBSCRIPTION_ID`. This is also the break-glass path (risk **R8**). |

Gone as of E02.4 (#36): `ARM_CLIENT_SECRET`, the whole duplicate `AZURE_*` set, and the old
service principal's client secret in Entra (rotated, then removed). Nothing in
`.github/workflows/` references a client secret — the consequence worth internalising is that
the OIDC cutover is **not** a one-commit rollback any more, because there is no working secret
to roll back to.

On `pull_request` events, `_terraform.yml` also posts the plan as a
**sticky** PR comment (one comment per module, identified by a hidden
`<!-- tf-plan: <working_directory> --> ` marker and updated in place on
every push, rather than piling up a new comment each time) — so a PR
touching several modules gets one comment per module, not one shared
comment. `terraform apply` is structurally disabled on `pull_request`
events regardless of the `apply` input, so PR runs only ever plan. The
`infra/network` comment carries an extra note explaining that its NSG
SSH-rule diff (see CLAUDE.md's ipify gotcha) is expected noise, not real
drift, until #54 (E06.4) removes the ipify data source.

### Overall pipelines

- **`deploy.yml`** (manual dispatch): calls the five per-module workflows in dependency order — network → dns → cloudflare → storage → compute — with `secrets: inherit`. The `apply_terraform` checkbox gates apply in every module job; unchecked runs a plan-only dry run across all five modules.
- **`destroy.yml`** (manual dispatch): tears down billable resources in reverse order — compute → cloudflare. It deliberately **skips storage** (the persistent data disk), **network**, and **dns**: the disk lives inside `homelab-rg`, so the network module cannot be destroyed while the disk exists, and the remaining VNet/subnet/NSG/RG are free; the DNS zone costs a flat ~$0.52/month regardless of usage, so there's no reason to tear it down every cycle — and doing so previously broke `infra/cloudflare`'s and `compute/vm`'s data-source lookups by name between deploy cycles (#124). The `apply_destroy` checkbox (default unchecked) gates the actual destroy; unchecked runs `plan -destroy` dry runs only. Since #153 both of its jobs are thin `uses:` callers of `_terraform.yml`, identical in shape to a `deploy-*.yml` job except for `destroy: true` — so destroy runs at the `.terraform-version` pin, runs `terraform validate`, and shares the deploy path's single OIDC auth step and apply gate rather than duplicating them.

Both overall pipelines share the `homelab-terraform` concurrency group so a deploy and a destroy can never run at the same time. That group is workflow-level; each `_terraform.yml` job additionally takes the per-module `tf-<working_directory>` group, which is what actually leases the module's state blob — destroy included, as of #153.

### Lint gate

**`lint.yml`** runs on every push/PR touching any `.tf` file (repo-wide, not per-module — unlike the deploy workflows, static analysis doesn't need Azure credentials or a backend). Two independent jobs:
- **TFLint**, configured by the repo-root `.tflint.hcl` (`terraform` ruleset preset + `azurerm` ruleset), run with `--recursive` so one invocation covers all five root modules.
- **Checkov**, `bridgecrewio/checkov-action`, `-d . --framework terraform`, scanning the whole tree in one pass.

Both are blocking (`soft_fail: false`). The baseline (E01.6) was triaged rather than left soft-failing: real findings were fixed (missing `required_version`, an unconstrained `http` provider, two dead variables, a missing `allow_extension_operations = false`), and the three checkov findings that need infra this repo doesn't have yet — customer-managed disk encryption (needs Key Vault, E05) and no public IP on the VM NIC (needs Tailscale first, E06) — or don't apply to this architecture (disk export/Private Link) carry inline `# checkov:skip=<ID>:<reason>` comments next to the resource.

### Dependency updates

**`dependabot.yml`** watches `github-actions` (root) weekly, plus one `terraform` entry per root module (Dependabot doesn't recurse into subdirectories on its own) — also weekly.

Dependabot-authored PRs carry a sharp edge: workflow runs triggered by
`dependabot[bot]` (the `pull_request` run and the branch-push run alike)
read **Dependabot secrets** — a separate store from Actions secrets, and
none are configured there. Every `CLOUDFLARE_*`/`DNS_ZONE_NAME`/
`RESOURCE_GROUP_NAME` reference resolves to an empty string, so the
Terraform job fails before producing a real plan; only TFLint/Checkov
produce real signal on such a PR. A maintainer push to the PR branch (an
empty commit is fine) re-triggers CI as that maintainer, restoring
repository secrets and producing the real plan comment — this is how the
azurerm 4→5 PRs (#143–#147) were driven to a meaningful CI result. The
standing fix is to mirror the secrets into Settings → Secrets and
variables → Dependabot (#138, roadmap R17).

E02.3 (#35) changed the likely failure mode, and #138 has not been
re-tested since. Azure authentication no longer reads secrets at all —
the three `ARM_*` identifiers are repo *variables*, which Dependabot runs
can read — but Dependabot runs get a read-only `GITHUB_TOKEN`, so the job
may now fail earlier, unable to mint the OIDC token that `id-token: write`
requires, rather than at backend auth in `terraform init`. Treat the exact
error on the next Dependabot PR as new information; don't assume mirroring
the secrets alone will turn the check green.

### Repo hygiene

`.github/ISSUE_TEMPLATE/epic.md` and `child.md` mirror the roadmap's existing issue-body format (see `docs/roadmap.md`'s epic table and "Working agreement"). `.github/pull_request_template.md` encodes the roadmap's PR checklist. `.github/CODEOWNERS` (`* @114snehasish`) covers the whole repo.
