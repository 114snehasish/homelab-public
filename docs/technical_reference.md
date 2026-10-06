# Technical Reference: Core Infrastructure

This document serves as the technical API reference for the **current foundational modules** of my homelab. 

As I expand the lab, new modules will be added, but these core components provide the essential runtime environment.

---

## 1. Project Structure (Current State)

```
.
├── apps
│   └── caddy       # [Deployed manually] The single public edge (#39)
├── compute
│   └── vm          # [Ephemeral] The Workload Node
├── infra
│   ├── backup      # [Control plane] The restic repository's account (bootstrapped locally)
│   ├── identity    # [Control plane] CI's Azure identity (bootstrapped locally)
│   ├── network     # [Persistent] The Network Backbone
│   └── storage     # [Persistent] The Data Layer
├── scripts         # [Out-of-band] az bootstrap, deliberately not Terraform (ADR-0009 §2)
├── .github
│   └── workflows   # CI/CD Pipelines
└── docs            # Documentation
```

`apps/` has no Terraform and no CI pipeline yet (CI deploy is `#40`) — see
[§6](#6-deployed-layer-apps).

---

## 2. Core Module: `infra/network`

**Purpose**: Sets up the foundational networking perimeter. I designed this to be the stable backbone that future services will plug into.

### Resources
- `azurerm_resource_group.homelab_rg`: The logistical container for my resources.
- `azurerm_virtual_network.homelab_vnet`: The address space (`var.vnet_address_space`, default 10.0.0.0/16) reserved for the lab.
- `azurerm_subnet.homelab_subnets`: One subnet per entry in `var.subnets`, keyed by subnet name. Today that map holds exactly one entry — `homelab-subnet` = 10.0.0.0/24, the public tier.
- `azurerm_network_security_group.homelab_nsg`: The security boundary.
- `azurerm_network_security_rule.homelab_nsg_rules`: One rule per entry in `var.nsg_rules`, keyed by rule name. Today: `Allow-SSH` at priority 100, `Allow-HTTP` (80) at 110 and `Allow-HTTPS` (443) at 120.
  - **The VM has public 80/443 exposure** (#37). Both are inbound TCP from `*` because a public web endpoint is the point; 80 is kept open for the ACME HTTP-01 fallback and the redirect to HTTPS, not for serving plaintext. Caddy ([§6](#6-deployed-layer-apps), `apps/caddy`) is the only intended listener on either port — anything else bound there is reachable from the internet the moment it starts.
- `azurerm_subnet_network_security_group_association.homelab_nsg_assocs`: One per subnet — the NSG is owned at the subnet layer, per [ADR-0012](adr/0012-workload-tiering-cidr-and-nsg-ownership.md).

### Adding a subnet or a rule
Both are **map entries, not resource blocks** (#161). A subnet needs a name and
`address_prefixes` taken from ADR-0012's CIDR plan; a rule needs an explicit `priority`
— `for_each` iteration order must never be what decides one. A rule that omits
`source_address_prefix` inherits the SSH whitelist default: `var.ssh_source_ip` if set,
otherwise the public IP of whichever machine is running the plan (fetched live from
api.ipify.org), which is why local and CI plans always disagree on that one value.
A rule meant to be reachable from anywhere must therefore say `source_address_prefix = "*"`
explicitly — omitting it silently narrows the rule to one address.

---

## 3. Core Module: `infra/storage`

**One disk per compute node.** `azurerm_managed_disk.homelab_data_disk` iterates the same
`fleet.tfvars` map `compute/vm` uses, so a node added there gets its disk here. The deployed node
pins `disk_name = "homelab-data-disk"` because that is the name the existing disk already carries —
new keys fall back to `${instance}-data-disk`. The two modules are linked by naming convention, not
`terraform_remote_state`: `compute/vm` looks its disk up through a data source, so the fallback
pattern must stay identical on both sides.

**The disks live in `homelab-persist-rg`, not `homelab-rg`** (E15.2,
[#98](https://github.com/114snehasish/homelab/issues/98)) — ADR-0009's first principle is that
nothing precious shares a resource group with anything destroyable. The group is created out-of-band
by `scripts/bootstrap-persist-rg.sh` and only ever read here. The variable is `disk_rg_name`, not
`rg_name`, deliberately: `infra/network` and `compute/vm` both declare `rg_name` meaning
`homelab-rg`, and a repo-wide `TF_VAR_rg_name` would otherwise repoint the pet disk silently — the
same collision `infra/dns` hit and solved by renaming. `compute/vm` declares the same name with the
same default, and a data-disk attachment works across resource groups as long as the region matches.

**Purpose**: Manages the persistent data assets. This is the "Vault" of my architecture.

### Resources
- `azurerm_managed_disk.homelab_data_disk`: The primary persistent store.
  - **Lifecycle**: Protected by `prevent_destroy = true`.
  - **Role**: holds everything that must outlive a VM — app state under `/data/<app>`, plus Docker's and containerd's storage roots (`/data/docker`, `/data/containerd`, #99); architected to exist independently of any specific compute instance.

---

## 4. Core Module: `compute/vm`

**Purpose**: The current execution environment. I designed this module to be highly disposable and replaceable.

### Resources
The module builds **one node per entry in the repo-root `fleet.tfvars`**, via `for_each` over
`var.instances`. The map key *is* the instance name, and every name a node produces derives from
it (#162), so the key `homelab-edge` reproduces the deployed node's names byte-for-byte. Below,
`${instance}` is that key:

- `azurerm_linux_virtual_machine.homelab_vm`: the Ubuntu host — named `${instance}`.
- `azurerm_network_interface.vm_nic`: `${instance}-nic`.
- `azurerm_public_ip.vm_public_ip`: `${instance}-public-ip`.
- ↳ `os_disk`: `${instance}-osdisk`.
- `azurerm_dns_a_record.vm_record`: the A record the VM registers for itself, labelled `${instance}`.
- `azurerm_dns_a_record.wildcard_record`: the zone-wide `*` alias, created only for the node
  flagged `public_edge = true` in `fleet.tfvars` (at most one, enforced by a `validation` block
  on `var.instances`). It lives in this module rather than `infra/dns` because an alias record
  needs the public IP's *resource ID*, and a data-source lookup in `infra/dns` would fail on
  every plan while `destroy.yml` has this module torn down — the #124 failure mode. Alias, not
  a literal IP, so a VM recreate re-points `*` in Azure with no Terraform run. One wildcard is
  also what keeps per-app hostnames out of a publicly mirrored zone (risk R6).
- `azurerm_virtual_machine_data_disk_attachment`: the dynamic link between a disposable VM and
  *its own* persistent disk, at the entry's `data_disk_lun` (default 10).
- ↳ `identity` (dynamic block, E03.3 #39; extended E15.4 #100): `UserAssigned`, attached only to the
  `public_edge` instance — **two** UAMIs from `infra/identity`, `homelab-edge-dns-identity` and
  `homelab-backup-identity`, looked up by `data "azurerm_user_assigned_identity" "edge_dns"` and
  `"backup"`. Adding an identity to an already-deployed VM is an **in-place update**, not a
  replacement, on this repo's pinned `azurerm ~> 5.0` — confirmed against the real VM (`0 to add, 1
  to change, 0 to destroy`; apply completed in 18s, no restart). They give Caddy (`apps/caddy`) a
  credential-free path to the DNS-01 challenge and restic a credential-free path to blob storage; see
  [ADR-0013](adr/0013-caddy-edge-dns01-provider-and-credential-model.md) and ADR-0009 §6a.
  **Two identities make managed-identity auto-selection ambiguous**, so both consumers pin
  `AZURE_CLIENT_ID` in their own environment — Caddy's in its compose env file, restic's in
  `/etc/homelab/restic.env`. Dropping either pin does not fail at deploy time; Caddy's surfaces weeks
  later as a certificate that did not renew.
- ↳ `backup/` (E15.4, #100): the restic backup service — two systemd timers, their units, the
  wrapper scripts and the exclude list, shipped into `custom_data` by `cloud-init.tf` **only** for
  the `public_edge` node, since only that node carries the backup identity. Both units
  `Requires=homelab-persist.target`, so a backup can never run against a `/data` that is the OS disk
  or half-mounted. Runbook: [`runbooks/restic_backup.md`](runbooks/restic_backup.md).

**No NSG association lives here.** Per [ADR-0012](adr/0012-workload-tiering-cidr-and-nsg-ownership.md)
the subnet is the single owner of NSG policy; the NIC-level association this module used to
create was removed in #162. Rules are a property of the tier a node sits in, so they are
edited in `infra/network`'s `var.nsg_rules`.

**Outputs are maps keyed by instance name** — `public_ip` and `ssh_command` describe a fleet, so
read them with `terraform output -json ssh_command | jq -r '."homelab-edge"'`.

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
**One entry in `fleet.tfvars`.** That is the whole authoring surface: no workflow edit, no new
state key, no new concurrency group, no `destroy.yml` leg. `infra/storage` reads the same map and
creates that node's data disk, so the "a managed disk cannot attach to two VMs" constraint is
handled by the disks multiplying in lockstep.

```hcl
instances = {
  homelab-edge  = { disk_name = "homelab-data-disk", public_edge = true }
  homelab-tools = {}
}
```

Cheap is not the same as justified: ADR-0012's "earns its own VM" test and #159's "default fleet
stays at one node" still gate whether a second node *should* exist, and E09 (k3s,
[#22](https://github.com/114snehasish/homelab/issues/22)) may answer that with an agent node
instead of a pet VM.

### Automation (`cloud-init.yaml` + the mount contract)
`custom_data` is assembled by `cloud-init.tf`, not read from one file
([#99](https://github.com/114snehasish/homelab/issues/99)). It `yamldecode()`s `cloud-init.yaml`,
appends the mount contract's files from `persist/` (plus `scripts/write-persist-marker.sh`) to
`write_files` verbatim, renders one `.mount` unit per (LUN → mount) entry and a
`homelab-persist.target`, and `yamlencode()`s the result. Nothing is a Terraform template, so shell
`${…}` needs no escaping, and `data_disk_lun` feeds the rendered units, so the attachment and the
contract can no longer disagree. A plan-time `precondition` holds the result under Azure's
65,535-byte `custom_data` limit. Any change to those files replaces the VM.

On every boot the node then:
1.  **Prepares** the disk at `/dev/disk/azure/scsi1/lun10` (`homelab-persist-prepare@10`): waits up
    to 300 s for it (the attachment lands after first boot), runs `e2fsck -p` on an existing ext4,
    and formats **only** a disk that carries no signature at all — anything else is refused. Only
    then does it link the vetted partition as `/run/homelab-persist/lun10-part1`.
2.  **Mounts** that link on `/data` (`data.mount`), outside early boot, so a missing disk never
    blocks SSH. The mount's `What=` is deliberately not a `/dev` path. That would give systemd its
    own 90 s device job, which fails a disk that attaches after 90 s but inside prepare's wait.
3.  **Verifies** it (`homelab-data-guard@data`): `/data/.homelab-persist` against Azure IMDS and
    `blkid`, per ADR-0009 §3. A disk formatted this boot is blessed automatically once IMDS lists it
    (the guard waits up to 120 s for that, because IMDS lags a fresh attachment).
4.  **Starts the container runtime** only then: `containerd.service` and `docker.service` require
    `homelab-persist.target`, and keep their roots at `/data/containerd` and `/data/docker`.

`boot_diagnostics {}` (managed storage) exposes the serial log, which carries the same prepare and
guard lines. Operating it, every FATAL line, and the re-bless procedure:
[docs/runbooks/data_guard.md](runbooks/data_guard.md).

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

- `azurerm_user_assigned_identity.homelab_edge_dns` (`homelab-edge-dns-identity`, E03.3 #39): a
  second, unrelated UAMI — Caddy's DNS-01 identity, not the CI identity above. No
  `prevent_destroy`: nothing outside this module references its `client_id`, so recreating it
  costs one `infra/identity` re-apply, not a repo-variable update. `compute/vm` looks it up by
  name and attaches it only to the instance with `public_edge = true`. See
  [ADR-0013](adr/0013-caddy-edge-dns01-provider-and-credential-model.md).
- `azurerm_user_assigned_identity.homelab_backup` (`homelab-backup-identity`, E15.4 #100): a third
  UAMI, restic's. Same reasoning as the edge one — user-assigned so it survives the VM being cattle,
  no `prevent_destroy` because nothing outside this module pins its `client_id`. It holds exactly one
  grant, `Storage Blob Data Contributor` on the `restic` **container** in `homelabpersistbackupsa`,
  which `infra/backup` creates. Never the account: the scope states what the credential may reach,
  not what happens to sit beside it today.

### Role assignments (E02.2, #34; extended by E15.0 #205 and E15.4 #100)
The CI identity holds **six** role assignments, each scoped as narrowly as the thing it enables.
Four are listed here; the other two are both `Managed Identity Operator`, one per attachable UAMI,
listed with the identities they scope to — but they are CI grants and `granted_scopes` counts them.

That duplication is why `granted_scopes` became a **list of `{role, scope}` objects** in #100: as a
map keyed by role name, two `Managed Identity Operator` rows are two identical keys and the plan
fails with "Duplicate object attribute key".

| Role | Scope | Enables |
|---|---|---|
| `Contributor` | RG `homelab-rg` | Every resource the five modules deploy. |
| `Storage Blob Data Contributor` | the `tfstate` container in `listeninfratfstatesa` | State read/write plus the blob lease Terraform uses as its lock. |
| `Reader` | the `homelab-vm-ssh-key-2` resource in `do-not-delete` | `compute/vm`'s SSH-key data source — one resource, not the RG around it. |
| `Homelab Persist Disk Writer` (custom) | RG `homelab-persist-rg` | `infra/storage` creates and refreshes the pet disk; `compute/vm` attaches it. See below. |

The scopes are located by read-only data sources; nothing outside `homelab-identity-rg` is ever
managed by this module. Two grants are deliberately absent: anything at subscription scope, and
any role on a *storage account* (which would carry `listKeys`, a bearer credential for every
container in it — the exact credential class E02 exists to eliminate). `listeninfratfstatesa` holds
two containers, `tfstate` and `secret-files`, so the container-scope rule there is load-bearing rather
than stylistic. The same rule is applied to the `restic` container in `homelabpersistbackupsa` even
though that account holds nothing else — and that account additionally sets
`shared_access_key_enabled = false`, which turns the rule into a property no configuration mistake can
undo.

### Custom role definition (E15.0, #205)

`azurerm_role_definition.persist_disk_writer` is the repo's **first and only custom role**. It
exists because Azure ships no `Disk Contributor`: the disk-named built-ins (`Disk Backup Reader`,
`Disk Pool Operator`, `Disk Restore Operator`, `Disk Snapshot Contributor`, `Data Operator for
Managed Disks`) cannot create a managed disk, and the ones that can — `Virtual Machine Contributor`,
`Contributor` — re-widen exactly what ADR-0009 §2 narrows.

```hcl
actions           = ["Microsoft.Compute/disks/read", "Microsoft.Compute/disks/write"]
not_actions       = []
assignable_scopes = [<homelab-persist-rg>]
```

`Microsoft.Compute/disks` has exactly five management-plane operations, so this is precisely the
non-destructive half. **`write` is load-bearing twice**: `infra/storage` creates the disk with it,
and `compute/vm` *attaches* it with it — attaching sets the disk's `managedBy` property, and Azure
has no `disks/join/action` the way it does for subnets and NICs. Scoped to the RG rather than the
disk because a role assignment's scope must already exist and a new fleet node's disk does not yet.

Deliberately omitted: `disks/delete` (a delete happens only on `destroy`, which `prevent_destroy`
already refuses — leaving it out makes retiring a disk a local-owner act); `disks/beginGetAccess`
and `/endGetAccess` (they mint a disk SAS URI, i.e. read the bytes); and
`Microsoft.Resources/subscriptions/resourceGroups/read` (nothing reads the group today — the
symptom if something ever does is an `AuthorizationFailed` at *plan* naming that exact action).

Two implementation rules that are easy to get wrong and are documented in CLAUDE.md's Gotchas: the
assignment references the role by `role_definition_id = …role_definition_resource_id`, never by
`role_definition_name` (which the provider resolves for built-in roles only, via a tenant-wide
filtered List that races RBAC propagation) and never by `.id` (which is `"{guid}|{scope}"`). The
group itself is **not managed here** — `scripts/bootstrap-persist-rg.sh` creates it out-of-band and
this module reads it, so the definition and its assignment both die with the group if it is ever
deleted.

**Two more role assignments, for the edge DNS identity (E03.3, #39):**

| Role | Scope | Principal | Enables |
|---|---|---|---|
| `DNS Zone Contributor` | the `az.snehasish-chakraborty.com` zone | `homelab-edge-dns-identity` | Caddy's only Azure right — write and clean up the ACME DNS-01 TXT challenge. |
| `Managed Identity Operator` | the `homelab-edge-dns-identity` resource | `homelab-github-actions-identity` (the CI identity) | Lets CI's `compute/vm` apply *attach* this identity to the edge VM. Not `Reader`: attaching is the `.../userAssignedIdentities/assign/action` write, which `Reader` does not grant — that gap plans clean and fails only at apply. Not a privilege escalation: CI already holds `Contributor` on `homelab-rg`, which contains the DNS zone. |

Verified against the live subscription after applying: `az role assignment list --assignee
<edge principal_id> --all` returns exactly the one `DNS Zone Contributor` row.

Because a role assignment lives on the scope it grants, CI can manage `homelab-rg` but could
never recreate it after a deletion. That is why `destroy.yml` stops short of `infra/network`,
and why the break-glass local apply matters (roadmap risk **R8**).

The blob grant only works when Terraform authenticates to storage with Entra rather than
account keys — `ARM_USE_AZUREAD=true`, set alongside `ARM_USE_OIDC=true` in `_terraform.yml`'s
OIDC credential step. Without it, `terraform init` fails at `listKeys` before validate runs.

### Outputs
`client_id`, `principal_id`, `tenant_id`, `uami_id`, `identity_rg_name`, `granted_scopes`,
`persist_disk_role_definition_id`. None are secrets — they are identifiers, which is why E02.3 (#35)
moves them into repo **variables** rather than repo secrets. `granted_scopes` is the audit surface:
diff it against `az role assignment list --assignee <principal_id> --all`; it now carries five
entries, having been silently missing `Managed Identity Operator` (E03.3) until E15.0 — which meant
the diff it exists to support had a spurious extra row on the Azure side. Its last key comes from
the role *definition*'s `name`, not the assignment's
`role_definition_name` — that attribute is Computed and unknown at plan time, and an unknown map
**key** renders the entire output as `(known after apply)`, hiding the other three rows in exactly
the plan you want to read them in.

For the edge identity: `edge_dns_client_id`, `edge_dns_uami_id`, `edge_granted_scopes`. Kept as
separate outputs rather than folded into the ones above — the two identities are unrelated, and
`granted_scopes` documents the CI identity specifically. `edge_dns_client_id` exists only as the
`AZURE_CLIENT_ID` fallback for `apps/caddy/.env`, needed if managed-identity auto-selection on the
VM is ever ambiguous (it is not, today — the VM carries exactly one user-assigned identity).

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

## 5b. Control-Plane Module: `infra/backup`

**Purpose**: Holds Tier 2 — the storage account and container the restic repository lives in
(E15.4, #100). Like `infra/identity`, it is **applied locally as Owner and has no workflow**, and for
a related reason: `infra/storage` runs in CI, and creating a storage account in `homelab-persist-rg`
needs `Microsoft.Storage/storageAccounts/write` there — a CI credential able to create the backup
account is able to delete it, which is what ADR-0009 §2 exists to prevent.

State key `homelab.backup.tfstate`. Applying it is a prerequisite of `infra/identity`, because a role
assignment's scope must already exist.

### Resources

- `azurerm_storage_account.homelab_backup` (`homelabpersistbackupsa`): `StorageV2`, `Standard_LRS`,
  `southindia`, access tier **Hot**, `prevent_destroy`.
- `azurerm_storage_container.restic`: one container, private, `prevent_destroy`. Addressed by
  `storage_account_id` and **never** the legacy `storage_account_name` — that argument drives the
  provider through the storage *data* plane, which cannot work with shared keys disabled.

### The three settings that carry the design

| Setting | Why |
|---|---|
| `shared_access_key_enabled = false` | ADR-0009 §6a's "never an account key on the VM" becomes a property of the account rather than a rule. No key works for anybody. It also means an *account* SAS cannot be minted — §6a's fallback must be a **user-delegation** SAS. |
| `blob_properties.versioning_enabled = true` | §6c's R22 mitigation. The VM can delete the backups it writes; a version survives that. |
| `delete_retention_policy.days = 30` (blob and container) | The window must outlast a park, which lasts weeks. The 7-day default would expire unobserved. |

**Why this account exists at all** is the 2026-09-28 ADR amendment. The #205 amendment had the
`restic` container share `listeninfratfstatesa` with `tfstate` and `secret-files`; since versioning
and soft delete are blob-*service* properties, meeting §6c there would have changed behaviour for the
Terraform state. A dedicated account makes §6c reachable, removes a cross-region hop, and shrinks the
blast radius of an account-scoped grant to backups alone.

**Public network access stays enabled and there is no `network_rules` block**, deliberately: #206's
disaster-recovery drill restores from blob alone, with no VM, from whatever machine the operator has.
A private endpoint or default-deny rule would break the one recovery path this account exists to
serve — silently, at the worst possible moment. The compensating controls are the three settings
above plus container-scoped RBAC in `infra/identity`. Checkov's findings to that effect are skipped
inline with that reason rather than suppressed in a baseline file.

Drift is caught **on demand, not continuously** — no workflow plans this module — which is why
#102's drill keeps asserting the same settings as a backstop.

---

## 6. Deployed Layer: `apps/`

**Purpose**: Compose-as-code apps, deployed to the VM manually today (CI deploy is E03.4, #40).
Unlike the five modules above, this layer has no Terraform and no state — it is files on the VM's
`/data` disk plus whatever `docker compose` is currently running. The full pattern and the manual
deploy runbook live in [`apps/README.md`](../apps/README.md); this section is the reference
summary.

### `apps/caddy` — the single public edge (E03.3, #39)

- One `docker-compose.yml` service, `caddy`, built from a repo-local `Dockerfile` (the official
  `caddy` image ships no DNS provider plugins) that adds `caddy-dns/azure` via `xcaddy`. Both
  stages pin an exact Caddy version — this repo's Dependabot config has no `docker` ecosystem, so
  nothing else watches that tag.
- **One wildcard site block** in the Caddyfile — `*.az.snehasish-chakraborty.com` — never a
  per-app top-level block. Caddy takes a site address literally as a certificate subject; a second
  block for a specific hostname would request a separate certificate for it, and that hostname
  would then appear in a public Certificate Transparency log (risk R6, load-bearing since the repo
  is force-mirrored to a public GitHub repo on every push to `main`). Every app hostname is a
  `handle` block with a `host` matcher *inside* the one wildcard site instead.
- **Authenticates to Azure DNS for the ACME DNS-01 challenge as a VM-attached user-assigned
  managed identity** (`homelab-edge-dns-identity`, §5) — no credential file, no secret, anywhere.
  See [ADR-0013](adr/0013-caddy-edge-dns01-provider-and-credential-model.md) for why the issue's
  original Cloudflare-DNS-01 design could not work (`az.snehasish-chakraborty.com` is delegated to
  Azure DNS, not Cloudflare) and why a managed identity rather than a service-principal secret.
- Certs and the ACME account persist at `/data/caddy` on the VM's data disk — survives a
  `docker compose down && up`, and is intended to survive a VM recreate once #99's mount contract
  lands (verification of that specific claim is #99's work, not this issue's).
- Joins the shared external Docker network `web`, created once per VM
  (`docker network create web`) and joined by every app Caddy proxies to — not owned by any single
  app's compose file.

### Deviation from the roadmap's stated ordering

`docs/roadmap.md` states E15's disk migration (#98) and mount contract (#99) should land before
this issue, since Caddy is the first thing to write real state to `/data`. This issue shipped
first instead — the disk was still near-empty at deploy time, and the roadmap now carries the
mitigation this decision depends on: #98's snapshot-swap runbook must stop `apps/caddy` before
snapshotting, so the swap never captures a live ACME writer mid-write.

---

## 7. CI/CD Workflows

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

No caller fans out. `deploy-compute.yml` briefly carried a `strategy: matrix`
with one leg per instance; that came out when `compute/vm` grew `for_each`,
because a node is now an entry in `fleet.tfvars` rather than a matrix leg —
which is the shape #159 had decided on from the start.

`var_file` is what carries that file in: `deploy-compute.yml` passes
`../../fleet.tfvars` and so does `deploy-storage.yml` — paths are relative to
`working_directory`, and both modules sit two levels deep — and `destroy.yml`'s
compute leg passes it too
— without it `plan -destroy` fails on the missing `instances` variable before it
can tear anything down. Both modules declare that variable with **no default**,
so losing the flag is a loud failure rather than a plan that quietly destroys
every node. `destroy.yml` also passes the same `state_key` as the deploy leg, or
a destroy and a deploy of one node could run at once.

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
- **`destroy.yml`** (manual dispatch): tears down billable resources in reverse order — compute → cloudflare. It deliberately **skips storage** (the persistent data disk), **network**, and **dns**. The reason for sparing network changed at E15.2 ([#98](https://github.com/114snehasish/homelab/issues/98)), exactly as ADR-0009 §5 anticipated — the disk moved to `homelab-persist-rg`, so "the network module cannot be destroyed while the disk exists" no longer applies; what remains is that the VNet/subnet/NSG/RG are free to leave up, and that the DNS zone in `homelab-rg` is read by name via data sources with no tolerance for absence; the DNS zone costs a flat ~$0.52/month regardless of usage, so there's no reason to tear it down every cycle — and doing so previously broke `infra/cloudflare`'s and `compute/vm`'s data-source lookups by name between deploy cycles (#124). The `apply_destroy` checkbox (default unchecked) gates the actual destroy; unchecked runs `plan -destroy` dry runs only. Since #153 both of its jobs are thin `uses:` callers of `_terraform.yml`, identical in shape to a `deploy-*.yml` job except for `destroy: true` — so destroy runs at the `.terraform-version` pin, runs `terraform validate`, and shares the deploy path's single OIDC auth step and apply gate rather than duplicating them.

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
