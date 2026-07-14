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
- `azurerm_virtual_network.homelab_vnet`: The address space (10.0.0.0/16) reserved for the lab.
- `azurerm_subnet.homelab_subnet`: The initial subnet for compute nodes.
- `azurerm_network_security_group.homelab_nsg`: The security boundary.

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
- `azurerm_linux_virtual_machine.homelab_vm`: The current Ubuntu host.
- `azurerm_virtual_machine_data_disk_attachment`: The dynamic link between the disposable VM and the persistent storage.

### Automation (`cloud-init.yaml`)
The bootstrapping script is designed to:
1.  Detect the persistent storage at **LUN 10**.
2.  Safely mount it to `/data` (avoiding destructive formatting).
3.  Initialize the container runtime.

---

## 5. CI/CD Workflows

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
parameterized by `working_directory` (module path), `apply`, and an
optional `ssh_source_ip` (network only). `_terraform.yml` pins the
Terraform CLI version from the repo-root `.terraform-version` file and
runs its job under a `tf-<working_directory>` concurrency group, so two
runs touching the same module's state queue instead of racing.

Two per-module quirks are handled inside `_terraform.yml` with conditional
steps keyed on `inputs.working_directory`, rather than the shared
job-level `env:` block, since a static `env:` entry can't be scoped to one
caller without leaking to the others — and, for credentials specifically,
a static entry can silently win over a same-named value set later via
`$GITHUB_ENV`, so there is no static fallback declared at all for the
four variables below:
- `infra/dns` and `infra/cloudflare` authenticate with the `AZURE_*`
  secrets rather than `ARM_*` (see CLAUDE.md) via a dedicated `$GITHUB_ENV`
  step, mutually exclusive with the one that sets `ARM_*` for
  network/storage/compute; retiring that split is tracked separately
  (E02.4).
- `infra/dns`'s `rg_name` variable is populated from the
  `RESOURCE_GROUP_NAME` secret for `infra/dns` only, since `rg_name` is
  also declared (same default) by `infra/network`, `infra/storage`, and
  `compute/vm`.

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
- **`destroy.yml`** (manual dispatch): tears down billable resources in reverse order — compute → cloudflare. It deliberately **skips storage** (the persistent data disk), **network**, and **dns**: the disk lives inside `homelab-rg`, so the network module cannot be destroyed while the disk exists, and the remaining VNet/subnet/NSG/RG are free; the DNS zone costs a flat ~$0.52/month regardless of usage, so there's no reason to tear it down every cycle — and doing so previously broke `infra/cloudflare`'s and `compute/vm`'s data-source lookups by name between deploy cycles (#124). The `apply_destroy` checkbox (default unchecked) gates the actual destroy; unchecked runs `plan -destroy` dry runs only.

Both overall pipelines share the `homelab-terraform` concurrency group so a deploy and a destroy can never run at the same time.

### Lint gate

**`lint.yml`** runs on every push/PR touching any `.tf` file (repo-wide, not per-module — unlike the deploy workflows, static analysis doesn't need Azure credentials or a backend). Two independent jobs:
- **TFLint**, configured by the repo-root `.tflint.hcl` (`terraform` ruleset preset + `azurerm` ruleset), run with `--recursive` so one invocation covers all five root modules.
- **Checkov**, `bridgecrewio/checkov-action`, `-d . --framework terraform`, scanning the whole tree in one pass.

Both are blocking (`soft_fail: false`). The baseline (E01.6) was triaged rather than left soft-failing: real findings were fixed (missing `required_version`, an unconstrained `http` provider, two dead variables, a missing `allow_extension_operations = false`), and the three checkov findings that need infra this repo doesn't have yet — customer-managed disk encryption (needs Key Vault, E05) and no public IP on the VM NIC (needs Tailscale first, E06) — or don't apply to this architecture (disk export/Private Link) carry inline `# checkov:skip=<ID>:<reason>` comments next to the resource.

### Dependency updates

**`dependabot.yml`** watches `github-actions` (root) weekly, plus one `terraform` entry per root module (Dependabot doesn't recurse into subdirectories on its own) — also weekly.

### Repo hygiene

`.github/ISSUE_TEMPLATE/epic.md` and `child.md` mirror the roadmap's existing issue-body format (see `docs/roadmap.md`'s epic table and "Working agreement"). `.github/pull_request_template.md` encodes the roadmap's PR checklist. `.github/CODEOWNERS` (`* @114snehasish`) covers the whole repo.
