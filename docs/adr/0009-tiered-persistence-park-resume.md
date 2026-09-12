# ADR-0009: Tiered persistence and the park/resume lifecycle

- **Status**: Accepted — the parked-cost table in section 8 is computed from published retail prices and is superseded by the measured figure [#102](https://github.com/114snehasish/homelab/issues/102) records. **Amended 2026-09-12 ([#205](https://github.com/114snehasish/homelab/issues/205)): §1, §2, §6a, §6c and §8 — there is no separate backup storage account; the `restic` container lives in the existing state storage account `listeninfratfstatesa`, and the out-of-band script creates only the resource group.** See [§2's amendment block](#amendment-2026-09-12-205--no-separate-backup-storage-account). **Amended again 2026-09-12 ([#98](https://github.com/114snehasish/homelab/issues/98)): §2 and §3 — the migration was an `az resource move`, not a snapshot-swap, and ran with the lab parked.** See [§2's second amendment block](#amendment-2026-09-12-98--the-migration-was-a-resource-group-move-not-a-snapshot-swap).
- **Date**: 2026-09-08
- **Deciders**: repo owner
- **Related**: [#96](https://github.com/114snehasish/homelab/issues/96) (E15, parent) · [#97](https://github.com/114snehasish/homelab/issues/97) (this ADR) · [#205](https://github.com/114snehasish/homelab/issues/205) · [#98](https://github.com/114snehasish/homelab/issues/98) · [#99](https://github.com/114snehasish/homelab/issues/99) · [#100](https://github.com/114snehasish/homelab/issues/100) · [#101](https://github.com/114snehasish/homelab/issues/101) · [#102](https://github.com/114snehasish/homelab/issues/102) · [#206](https://github.com/114snehasish/homelab/issues/206) · [#207](https://github.com/114snehasish/homelab/issues/207) · [#103](https://github.com/114snehasish/homelab/issues/103) · [ADR-0012](0012-workload-tiering-cidr-and-nsg-ownership.md) · [ADR-0013](0013-caddy-edge-dns01-provider-and-credential-model.md) · [#20](https://github.com/114snehasish/homelab/issues/20) (E07) · [#164](https://github.com/114snehasish/homelab/issues/164) · [#165](https://github.com/114snehasish/homelab/issues/165) · [#54](https://github.com/114snehasish/homelab/issues/54) (E06) · [#124](https://github.com/114snehasish/homelab/issues/124)

## Context

The lab's operating model is **compute is ephemeral, storage is not**. It is not a 24×7 service: it
runs in deploy → experience → park cycles, and the only things that survive a cycle are the
persistence layer and a near-free control plane. Parked cost target: **≤ ₹400/mo**.

What exists today does not encode that. `compute/vm/cloud-init.yaml` is a `runcmd` bash blob that
guesses `/dev/sdc`, falls back to a LUN path, formats if `blkid` shows no `TYPE=`, and mounts with
`nofail` — so a VM that comes up **without** its disk boots happily and lets Docker write app state
onto the OS disk, which is destroyed on the next park. The disk itself lives in `homelab-rg`
alongside every disposable resource, protected only by `prevent_destroy`, one commit deep. There are
no logical backups of any kind, no k8s volume story, and — since `#39` shipped — Caddy's ACME account
and certificates are already real state on that disk.

This ADR is the first child of E15 and constrains every other one. Two things put it ahead of the
epic's original 2026-07-05 scope:

- **A full-epic architecture review (2026-09-08) raised seven decisions with no home**, each of which
  a later child would otherwise have to invent under time pressure: the marker-file contract shared
  by `#98`/`#99`, how restic authenticates to blob storage, whether the backup container is Hot or
  Cool, `public IP` missing from the resets-every-cycle inventory, Tailscale node sprawl, a new risk
  **R22**, and disk capacity/retention math. Sections 3, 6a, 6b, 4, 4, 6c and 7 below answer them in
  that order.
- **[#205](https://github.com/114snehasish/homelab/issues/205) (E15.0) did not exist when `#97` was
  written.** It is blocked on this ADR and blocks `#98`, because `infra/storage` cannot create the
  persist resource group: creating an RG is a subscription-level write, and CI holds `Contributor`
  on `homelab-rg` and nothing wider. Section 2 settles the principle `#205` implements.

## Decision

### 1. Three tiers, and the block-storage-only rule

| Tier | What | Where it lives | Who creates it | Survives a park |
|---|---|---|---|---|
| **T0 — control** | Terraform state; DNS zone `az.snehasish-chakraborty.com`; the `restic` container in the existing state storage account `listeninfratfstatesa`; Key Vault (E05); both UAMIs and every role assignment; VNet/subnet/NSG | `do-not-delete`, `homelab-rg`, `homelab-identity-rg`, `homelab-persist-rg` | out-of-band script (§2), `infra/dns`, `infra/identity`, `infra/network` | **yes** |
| **T1 — hot block** | The pet disk: live databases, app state, Prometheus/Loki history, Caddy's cert store and ACME account (`/data/caddy`), k3s PVs (`/data/k8s-pv`) | `homelab-persist-rg`, attached at LUN 10, mounted `/data` | `infra/storage` (Terraform) | **yes** |
| **T2 — cold logical** | restic repository: encrypted, deduplicated, versioned snapshots of `/data` | `restic` container in `listeninfratfstatesa` (RG `do-not-delete`) | `#100`, running on the VM | **yes** |
| *(untiered)* | The VM, NIC, public IP, OS disk | `homelab-rg` | `compute/vm` | **no — destroyed by park** |

**Block storage only for anything holding a live database file.** Azure Files was considered and
rejected: SQLite and Postgres depend on POSIX advisory locking and `fsync` semantics that SMB does
not reproduce faithfully, and the failure mode is silent database corruption rather than an error.
This is a rule about the *file*, not the app — a SQLite file on a share is out of bounds even if the
app tolerates it, and `pg_dump` output on a share is fine because it is not live.

**k3s persistent volumes are the same rule applied to k3s** ([#103](https://github.com/114snehasish/homelab/issues/103)):
`local-path-provisioner` backed by `/data/k8s-pv`, so a PV is a directory on T1 and inherits the
mount guard, the backup set and the park lifecycle without any separate machinery. The cost is that a
PV is bound to one node, which is correct for a fleet ADR-0012 fixes at one node by default.

### 2. Blast radius: the persist RG, and what CI may do inside it

The principle has two halves, and E15's existing text only states the first:

1. **Nothing precious shares a resource group with anything destroyable.**
2. **The identity that deploys the destroyable things must not be able to destroy the precious
   ones.** A blast radius drawn only around resource groups still leaves one credential holding both
   sides of the line.

**`homelab-persist-rg` is created out-of-band by a committed, idempotent `az` script
(`scripts/bootstrap-persist-rg.sh`), and is never managed by Terraform.** It is read through `data`
blocks only. This is the pattern the repo already runs on: RG `do-not-delete`, the storage account
`listeninfratfstatesa` and the SSH key `homelab-vm-ssh-key-2` are all pre-existing, never imported,
and listed under CLAUDE.md's *Never touch*. The persist RG joins that list.

#### Amendment (2026-09-12, #205) — no separate backup storage account

**As originally written this section also had the script create a dedicated backup storage account
and its `restic` container inside `homelab-persist-rg`. That is superseded: no separate backup
storage account will exist. The `restic` container lands in the existing state storage account
`listeninfratfstatesa` (RG `do-not-delete`), and `#100` owns creating it.** The script's scope
shrinks to the resource group alone.

The reasoning is that the lab does not need a second protected storage account to hold one more
container. `listeninfratfstatesa` is already the most protected object in the estate — pre-existing,
never Terraform-managed, already on *Never touch* — and §6a's container-scoped grant is exactly the
mechanism that makes co-tenancy safe. A second account would duplicate that protection rather than
add to it.

Four consequences, verified against the live account on 2026-09-12 and recorded here so `#100`
inherits them rather than discovering them:

- **The account is in `centralindia`; the lab is in `southindia`.** Every backup write and every
  restore read now crosses an Azure region. That adds inter-region egress that §8's table has no
  line for, and makes the recovery path measurably slower — on the tier whose entire purpose is
  recovery. The rejected separate account would have been co-regional. This is the real cost of the
  decision and it is accepted knowingly, at lab data volumes.
- **Blob versioning and soft delete are account-level settings, not per-container.** §6c is wrong
  where it implies otherwise, and is corrected below. Live state today: blob soft delete **enabled
  at 7 days**, container soft delete **enabled at 7 days**, versioning **off**. Meeting §6c's R22
  mitigation therefore means changing the blob-service properties of an account that also holds
  `tfstate` — a change to a *Never touch* resource, which must be a decision rather than a side
  effect of `#100`. Enabling versioning on `tfstate` is arguably a win in its own right (state blob
  history), but it is not free and it is not this ADR's call to make silently.
- **That account also holds a container named `secret-files`**, previously undocumented anywhere in
  the repo. Container-scoped RBAC contains this correctly — the edge VM's backup identity would hold
  rights on `restic` and nothing else — but it raises the stakes on §6a's rule considerably: an
  account-scoped grant there would hand an internet-facing VM both the Terraform state and that
  container. §6a is no longer merely a good habit.
- **CLAUDE.md's *Never touch* entry for `listeninfratfstatesa` now names all of its containers**, so
  the next person granting access to one can see what else is in the blast radius.

#### Amendment (2026-09-12, #98) — the migration was a resource-group move, not a snapshot-swap

**`#98` specified a snapshot-swap: `az snapshot create` → create a new disk from the snapshot in the
persist RG → detach/attach → verify → delete the old disk. It was executed instead as a single
`az resource move` of the existing disk object.** The snapshot was still taken, as the rollback
artifact, and retained 7 days.

The reason is a Terraform property the original plan did not account for. **`create_option` is
ForceNew *and* is read back from Azure** — the provider's read sets it from
`creationData.CreateOption`. A disk created from a snapshot reads back `"Copy"`, while
`infra/storage` declares `"Empty"`, so the post-import plan wants a destroy-and-recreate and
`prevent_destroy` turns that into a hard `Instance cannot be destroyed` error. (This was reproduced
deliberately before the move, and it is the same class of failure the 2026-09-08 review predicted for
the RG change itself.) Escaping it would have meant either an `ignore_changes` on a Required
attribute or a per-instance `source_resource_id` knob — a permanent scar in the module recording a
one-off migration.

A resource-group move has none of that. It is pure control-plane metadata: `Microsoft.Compute/disks`
is movable, the region does not change, and the disk object, its bytes, its `uniqueId`
(`4f243f04-…`) and its `timeCreated` (2026-09-07) are all preserved — verified before and after.
`create_option` stays `"Empty"`, so the post-import plan is genuinely `No changes.` The Terraform
seam is still manual, because the ARM ID embeds the resource group: `terraform state rm` then
`terraform import` at the new id, which is the one window where the disk is unmanaged.

**Three conditions made this the cheap option, and they are worth stating because they will not all
hold next time.** The disk was **unattached** — the lab was parked, and an attached disk can only
move together with its VM. Neither resource group carried a lock. And nothing else was running
against either group, which a move write-locks for its duration (~3 minutes here).

**Two consequences for the rest of E15:**

- **There is no old disk to delete.** `#98`'s closing step and the note that CI deliberately lacks
  `Microsoft.Compute/disks/delete` both become moot for this migration — nothing was left behind but
  the rollback snapshot.
- **The `docker compose down` gate in §5 and the roadmap's E15/E03 ordering note did not apply.**
  That step exists so a snapshot is never taken under a live ACME writer; with the lab parked there
  was no VM, no running Caddy and no writer. It remains the correct instruction for any migration
  performed against a running node.

This was chosen over creating them in `infra/identity` (local Owner apply) or `infra/storage` (CI):

- **`prevent_destroy` is a guardrail inside Terraform, and it is one commit deep.** A resource
  Terraform never manages cannot be destroyed by editing HCL at all. For the resources that must
  outlive every other thing in the lab, that is a strictly stronger guarantee than a lifecycle
  meta-argument.
- **It keeps `infra/identity` about identity.** `#205` reduces to *role assignments whose scopes are
  data sources of pre-existing resources* — the exact shape of the `tfstate_blob_contributor` grant
  already in `infra/identity/main.tf`, whose scope is built by string-append precisely because the
  container is not a resource this repo manages.

**The two things this costs, stated rather than discovered later:**

- **Out-of-band means *not Terraform-managed*, not *undocumented*.** The `az` script is committed and
  idempotent, so the resources are reproducible from the repo. That is an improvement on
  `do-not-delete`, which has no script at all.
- **Nothing reconciles the account's protective settings any more.** Under Terraform, blob
  versioning, soft-delete retention, TLS-only, no-public-blob-access and the Hot default tier would
  be re-asserted by every `plan`; on `listeninfratfstatesa` they are set once and never checked
  again — and were never Terraform-managed in the first place. Those are exactly the **R22**
  mitigations in §6c, so they get an explicit verification step rather than trust: an assertion of
  versioning + soft-delete retention in `#102`'s drill checklist and in the park runbook. Per the
  amendment above these settings are account-level, so that assertion covers `tfstate` and
  `secret-files` too.

**The disk stays in Terraform.** It is created per fleet node by `infra/storage`'s `for_each` over
`fleet.tfvars` and multiplies with the fleet in E17.6 ([#165](https://github.com/114snehasish/homelab/issues/165)),
so it cannot go out-of-band without giving up the one-entry-adds-a-node property. That is what forces
the grant below.

**CI's grant inside the persist RG is narrower than `Contributor`, and no built-in role fits.**
`infra/storage` needs `Microsoft.Compute/disks/read` and `/write` at RG scope — a role assignment's
scope must already exist, and a *new* node's disk does not, so the grant cannot be scoped to the disk
itself. Checked against Microsoft's built-in role catalogue: **there is no `Disk Contributor` role.**
The only disk-named built-ins are `Disk Backup Reader`, `Disk Pool Operator`, `Disk Restore
Operator`, `Disk Snapshot Contributor` and `Data Operator for Managed Disks`, none of which can
create a managed disk; the alternatives are `Virtual Machine Contributor` or `Contributor`, both of
which re-widen exactly what this section narrows. **So the grant is a custom role definition**, whose
creation needs `Microsoft.Authorization/roleDefinitions/write` (Owner or User Access Administrator) —
the same bootstrap constraint `infra/identity` already documents for itself.

**Pinned by `#205` (2026-09-12), role `Homelab Persist Disk Writer`:**

```
actions           = ["Microsoft.Compute/disks/read", "Microsoft.Compute/disks/write"]
not_actions       = []
assignable_scopes = [<the persist RG>]
```

`Microsoft.Compute/disks` has exactly five management-plane operations — `read`, `write`, `delete`,
`beginGetAccess/action`, `endGetAccess/action` — so this is precisely the non-destructive half of the
set. Note that **`write` is load-bearing twice**: `infra/storage` creates the disk with it, and
`compute/vm` *attaches* the disk with it, because attaching sets the disk's `managedBy` property and
Azure has no `disks/join/action` the way it does for subnets and NICs. The two `GetAccess` actions
are omitted along with `delete`: they mint a disk SAS URI, i.e. read the bytes, which is the worst
single action to hand a CI credential over the one disk holding every live database in the lab.

**`Microsoft.Compute/disks/delete` is deliberately omitted from that role.** CI never needs it: a
delete happens only on `destroy`, and `prevent_destroy` already refuses. Leaving it out means
retiring a node's disk is a deliberate local-owner act, and `prevent_destroy` becomes belt-and-braces
rather than the only thing standing between a bad plan and the data.

What CI can therefore do in `homelab-persist-rg`: create, read and update managed disks, and
read/write/delete blobs in the `restic` container (data plane, §6a). What it cannot do: delete the
resource group, the storage account, the container, or any disk. `#205` proves the negatives by
observation, not by reading role definitions.

### 3. The marker file is an identity record, not a presence check

`#99`'s data-guard exists so Docker can never start against a `/data` that is not the real disk. A
presence check — `test -f /data/.homelab-persist` — proves only that *a* formatted disk is mounted,
which stops being sufficient the moment E17.6 gives the fleet several. And `#99` writes the marker
*on first format only*, while `#98` lands against an **already-formatted** disk, so on the one disk
the guard exists to protect, that write path never fires.

**Contract.** Path `/data/.homelab-persist`, `key=value`, one pair per line, ASCII:

```
schema=1
instance=homelab-edge
disk_name=homelab-data-disk
fs_uuid=<blkid -s UUID -o value of the mounted partition>
mount=/data
created=2026-09-08T00:00:00Z
created_by=cloud-init|migration-runbook|restore
```

The guard compares those values against the live machine — `instance` against Azure IMDS
`compute/name`, `disk_name` against IMDS `compute/storageProfile/dataDisks[].name`, `fs_uuid`
against `blkid` on the device actually mounted at `mount`.

| Condition | Result |
|---|---|
| Marker absent on a mounted `/data` | **fatal** — the disk is not one this lab blessed |
| `fs_uuid` ≠ the mounted filesystem's UUID | **fatal** — the strongest signal; a filesystem UUID is not reassignable by mistake |
| `instance` ≠ IMDS instance name | **fatal** — the right disk on the wrong node |
| `disk_name` ≠ the attached disk's name | **warn**, logged to journald — a name is reassignable and a disk can legitimately be recreated from a snapshot under a different name while carrying the same filesystem |

Three consequences that would otherwise be found the hard way:

- **`#98`'s migration passes the guard unchanged, by construction.** This was written of a
  snapshot-swap — a snapshot preserves the filesystem, so `fs_uuid` survives it — and holds *more*
  strongly for the resource-group move `#98` actually performed: nothing was copied at all, so the
  filesystem, its UUID, the disk name `homelab-data-disk` and the node are all literally unchanged.
  The migration therefore needs one added runbook step — **write the marker** onto the
  already-formatted disk — and nothing else. Because the lab was parked for the move, that step runs
  *after* the disk is reattached and mounted rather than before, reading `fs_uuid` from `blkid` and
  `instance`/`disk_name` from live IMDS. `scripts/write-persist-marker.sh` is that writer, and
  `#99`'s format path should call it with `--created-by cloud-init` rather than reimplement it.
- **A restore to a fresh disk ([#206](https://github.com/114snehasish/homelab/issues/206)) fails the
  guard on purpose.** The restored marker carries the old `fs_uuid`; the new filesystem has a new
  one. So the contract includes a documented **re-bless** step that rewrites the marker from live
  IMDS + `blkid` values, used for exactly two deliberate cases: a restore, and a node rename. Without
  it, the guard blocks the DR drill it exists to make trustworthy.
- **`mount` is a field, not an assumption.** Per ADR-0012's instruction to shape the v2 contract for
  a *set* rather than one LUN → one mount point, a second disk on the same node gets its own marker
  at its own mount point and the guard iterates. That costs nothing today and avoids rewriting `#99`
  a second time in E17.6.

### 4. What persists, and what resets every cycle

**Persists.** *T0:* Terraform state; the DNS zone and its static records; the backup storage account
and restic repository; both user-assigned identities and every role assignment; VNet, subnet, NSG and
the resource groups themselves; Key Vault once E05 lands. *T1, on `/data`:* app state and live
databases; Prometheus and Loki history; Caddy's certificates and ACME account; k3s PVs.

**Resets every cycle.** Everything below is destroyed by park and rebuilt by resume. The point of
listing it is that each line is something a future change could accidentally depend on.

| Resets | Consequence, and who owns it |
|---|---|
| **Public IP address** | Park destroys it; resume mints a new one. The wildcard `*` record is an alias to the public IP resource (`target_resource_id`), so it re-points with **no Terraform run in `infra/dns`** — that elegance is the reason nothing else may pin the literal address. **Nothing may hard-code the IP**: not a firewall allow-list, not a monitoring target, not a bookmark. |
| **SSH host keys** | Regenerated on every fresh OS disk. Combined with the new address above, `known_hosts` breaks on **both** axes every cycle — `ssh-keygen -R` for the old host and address belongs in the resume runbook (`#102`), not in the reader's muscle memory. |
| **Tailscale machine state** | Every resume registers a **brand-new tailnet node**. Park weekly and within two months the tailnet is a graveyard of dead machines with MagicDNS names drifting `homelab-edge-1`, `-2`, … — silently breaking anything that addresses the node by name. Caused here, **owned by E06** ([#54](https://github.com/114snehasish/homelab/issues/54)); the mitigation is named so E06 inherits it rather than rediscovering it: **ephemeral auth keys** (the node is reaped automatically on disconnect) plus a **pinned `--hostname`**. |
| **OS disk and everything on it** | Installed packages, the Docker engine, journald history. Anything that must survive moves to `/data` — which is what `#99`'s optional `data-root` move is about. |
| **Docker containers, images and layers** | Re-pulled on resume unless `data-root` moves to `/data/docker`; that choice is a capacity question, settled in §7. |
| **k3s cluster state** | Deliberately not persisted: Argo CD re-bootstraps the cluster from git (E09). The PVs under `/data/k8s-pv` are T1 and do survive. |
| **The NSG's SSH allow rule** | Already drifts today — it whitelists the public IP of whatever machine last ran plan/apply. Dies with E06. |
| **NAT Gateway**, once it exists | [#164](https://github.com/114snehasish/homelab/issues/164) owns its teardown *in park from day one*. See §8 — leaving it up voids the entire parked-cost budget. |

### 5. Park scope, and the resume contract

**Park destroys `compute/vm` only** — the VM, NIC, public IP and OS disk, which are ~95% of the
running bill. Not `infra/network`, `infra/dns`, `infra/cloudflare`, `infra/storage` or
`infra/identity`; not the persist RG.

**No backup, no park.** Park's first act is the final restic run, and it must verify the snapshot id
before any `destroy` plan is applied. A park attempt whose backup step fails aborts *before* anything
is destroyed (`#101`).

**The reason `infra/network` survives park changes with `#98`, and the ADR records the change rather
than leaving stale reasoning in place.** Today `destroy.yml` spares it because *the disk lives inside
`homelab-rg`*. Once `#98` moves the disk to `homelab-persist-rg`, that reason evaporates. The network
module still must not be destroyed, for two different reasons: the VNet, subnet, NSG and resource
group cost nothing to leave running, and the DNS zone in `homelab-rg` is looked up **by name via data
sources with no tolerance for absence** in `infra/cloudflare` and `compute/vm` — which is what caused
the recurring plan failures in [#124](https://github.com/114snehasish/homelab/issues/124).

**Resume contract.** `terraform apply` on `compute/vm` → wait for cloud-init → the mount guard passes
→ app health checks. **No ACME re-issuance**, because the cert store is on T1; an ACME order appearing
in Caddy's logs after a resume is a failure signal, not a nuisance, and `#102`/`#206` check for it
explicitly.

**RPO and RTO, stated precisely.** `#97`'s own scope says *"RPO for unplanned VM death = last restic
run"*, which understates the design — the disk survives the VM:

| Failure | Recovery source | RPO |
|---|---|---|
| VM dies or is destroyed; disk intact | Re-apply `compute/vm`; T1 is untouched | **0** |
| Disk lost, corrupted, or wrongly formatted | restic restore from T2 | **≤ 24 h** — the last nightly snapshot |
| Backup repository unreadable (R13) | Nothing in this ADR | total loss of T2; T1 is the only copy |
| Region or subscription-level loss | Nothing in this ADR | **not covered** |

That last row is the honest gap: **T1 is a single LRS copy, and the T2 restic repository is LRS in
the same region.** Three replicas in one datacenter is not a disaster-recovery story. E07
([#20](https://github.com/114snehasish/homelab/issues/20)) is the crash-consistent disaster layer and
is also regional; nothing in this lab currently survives losing `southindia`. That is an accepted
residual risk for a homelab, recorded so it is a decision rather than an assumption.

### 6. Tier 2 mechanics

#### 6a. restic authenticates as a managed identity, never an account key

An account key on the VM is the easy path and is **excluded**. `infra/identity/main.tf` already
records why, about the state container:

> *"Deliberately NOT a role on the storage account, which would also confer listKeys — the key is a
> bearer credential for every container in the account, which is exactly what OIDC is replacing."*

Putting an account key on the internet-facing edge VM would undo E02's posture in the one place that
holds every backup.

**Decision: a second user-assigned managed identity, `homelab-backup-identity`, holding `Storage Blob
Data Contributor` scoped to the `restic` container — not the storage account.** Same container-scope
reasoning as the `tfstate` grant, and since the 2026-09-12 amendment it is *literally* the same
account: `restic` now shares `listeninfratfstatesa` with `tfstate` and `secret-files`. An
account-scoped grant here would hand the internet-facing edge VM the Terraform state and that third
container along with the backups. The comment already at `infra/identity/main.tf` above
`tfstate_blob_contributor` states the rule; it now guards three containers rather than one.
restic supports this: its Azure backend uses the Azure SDK
credential chain and its documentation states that *"if run on Azure, restic will automatically use
service accounts configured via the standard environment variables or Workload / Managed
Identities"*. A **container-scoped SAS with a short expiry** is the acceptable fallback if that path
fails in practice; an account key is not.

**The hard consequence, which `#100` must handle in the same change.** ADR-0013 attached
`homelab-edge-dns-identity` to the edge VM and depends on `libdns/azure` *falling back to managed
identity when `tenant_id`/`client_id`/`client_secret` are all left empty*. That fallback is
unambiguous only while the VM carries **one** user-assigned identity. Attaching a second one makes
the IMDS token request ambiguous, and the failure would surface weeks later as a silent certificate
renewal failure. **So `#100` must pin `AZURE_CLIENT_ID` explicitly for both consumers** — adding it
to `apps/caddy/.env` in the same PR that attaches the backup identity. Both values are client ids:
identifiers, not secrets, exactly like the two entries already in that file.

#### 6b. The `restic` container is **Hot**, not Cool

E15's existing text (the epic, `#98`, and `docs/roadmap.md`) specifies Cool. That is wrong for this
workload, and the numbers say so rather than intuition. Published retail prices, `southindia`,
General Block Blob v2, LRS:

| | Hot | Cool |
|---|---|---|
| Data stored | `$0.0238` /GB-mo | `$0.015` /GB-mo |
| Write operations | `$0.05` /10K | `$0.10` /10K (**2×**) |
| Read operations | `$0.004` /10K | `$0.01` /10K (**2.5×**) |
| Data retrieval | none | `$0.01` /GB |
| Early deletion | none | `$0.015` /GB, prorated over 30 days |

Cool carries a **30-day minimum retention**: a blob deleted, overwritten or re-tiered before 30 days
have elapsed is charged the remainder. `restic forget --keep-daily 7 --prune` repacks and deletes
pack files continuously, overwhelmingly **inside** that window — Cool's penalty applies to nearly
every prune this design performs, by design rather than by accident. Enabling soft delete does not
avoid it: Microsoft's documentation is explicit that a soft-deleted blob is simply not yet
*considered* deleted, so the penalty is deferred to when retention expires, not waived.

The saving being bought with all of that, at the ~15 GB billed size §8 assumes: `15 × $0.0088` =
`$0.13`/mo ≈ **₹11/mo**. Against 2× write operations on every backup, 2.5× read operations and a
per-GB retrieval charge on every `restic check` and every restore — i.e. Cool makes the *recovery*
path both slower and more expensive, which is the wrong thing to economise on in a backup tier.

**Decision: Hot, with no lifecycle rule.** A lifecycle rule tiering to Cool after 30 days was
considered and rejected as complexity that buys the same ₹11. **Stated revisit trigger, so this is
testable rather than a matter of taste: reconsider if the repository exceeds ~100 GB**, where the
storage delta reaches ~₹75/mo and starts to matter against the ₹400 budget. `#100`'s acceptance
criterion — *"blob spend matches the ADR's math"* — is checked against §8's table.

#### 6c. R22 — the backup credential can destroy the backups

**R13** covers the repository password being *lost*. **R22** is different and newly recorded: the VM
holds write access to the `restic` container and runs `forget --prune` on a timer, so a compromised
or simply misbehaving VM can delete every backup it has, on schedule. That VM is the lab's only
public-facing host, running an internet-exposed edge. The credential being used as designed is the
attack.

**Shipped now:** blob versioning and soft delete, retention **30 days**. The window is not arbitrary
— the lab is *parked for weeks at a time*, so a 7-day window would expire unobserved while nobody is
looking at anything. 30 days exceeds a realistic detection window for a lab that is only
intermittently attended. Per §2 these settings are no longer reconciled by any Terraform plan, so
`#102`'s drill and the park runbook assert them.

> **Corrected by the 2026-09-12 amendment.** This section said "on the container", which is wrong:
> blob versioning (`isVersioningEnabled`) and soft delete (`deleteRetentionPolicy`) are
> **blob-service properties, i.e. account-level** — there is no per-container form of either. Since
> the `restic` container now lives in `listeninfratfstatesa`, applying this mitigation changes
> behaviour for `tfstate` and `secret-files` as well. Live state of that account on 2026-09-12: blob
> soft delete **enabled at 7 days**, container soft delete **enabled at 7 days**, versioning
> **off** — so `#100` must raise retention to 30 days and switch versioning on *for the whole
> account*, or consciously accept a weaker R22 posture than this section specifies. It is listed as
> an open item rather than assumed.

**Target state, recorded as an open item rather than pretended:** split the credential so the VM
cannot delete at all — a **custom data-plane role** granting blob read/write/add but **not**
`.../blobs/delete` (no built-in expresses this; `Storage Blob Data Contributor` is the narrowest
built-in that lets restic write, and it can delete), with `forget --prune` moved off the VM into a
scheduled CI job holding its own identity. That leaves the VM append-oriented and the pruning
credential somewhere an attacker on the edge cannot reach.

**Version-level immutability is the strong form and is rejected, with a reason:** a time-based
retention lock makes the locked versions undeletable, which makes `prune` impossible for the lock
window. It is incompatible with `--keep-daily 7` retention, not merely inconvenient.

**Honest cost.** Versioning plus soft delete on a repository that prunes continuously multiplies
stored bytes — every pruned pack keeps a version for 30 days. §8's table carries a **1.5×**
multiplier for that rather than pretending the mitigation is free.

### 7. Capacity and retention

`disk_size_gb = optional(number, 20)`, and nothing in the epic owns sizing, retention, or what
happens when the disk fills. Two findings:

**A 20 GiB StandardSSD_LRS disk bills at the E4 tier — 32 GiB — at `$2.40`/mo.** Azure rounds up to
the next disk size tier (E1=4, E2=8, E3=16, E4=32 GiB), so **12 GiB of capacity is already paid
for**. Growing to 32 costs nothing; `#207`'s online-growth work makes claiming it a `fleet.tfvars`
number change plus a reboot.

**Budget against 32 GiB:**

| On `/data` | Budget | Bounded by |
|---|---|---|
| Caddy certs + ACME account | < 10 MB | fixed |
| App state and SQLite databases | ~2 GB | app count |
| Prometheus TSDB | 4 GB | **retention policy, below** |
| Loki | 2 GB | **retention policy, below** |
| k3s PVs (`/data/k8s-pv`) | 2 GB | workload |
| Docker `data-root`, if `#99` moves it | 8 GB | images dominate |
| restic cache (`#207`, pinned off the OS disk) | 1 GB | repo size |
| **Total** | **~19 GB of 32 GiB** | ~40% headroom |

**Bounded retention is the fix, not a bigger disk** — Prometheus and Loki grow without bound by
design, so any disk size is a date rather than a solution. The policy, concrete so `#207` can
implement it and E08 inherits rather than invents:

- **Prometheus:** `--storage.tsdb.retention.time=30d` **and** `--storage.tsdb.retention.size=4GB`.
  Both, because only the size cap actually protects the disk — a cardinality explosion fills it well
  inside 30 days.
- **Loki:** `retention_period: 168h` (7 days) with the compactor performing deletion, capped ~2 GB.
  Logs are the largest unbounded risk and the least valuable at age.

The 80%-usage alert (`#207`) is the backstop for everything this table gets wrong.

### 8. Parked-cost budget: line-item math

At a **stated ₹85/USD** — the rate `docs/roadmap.md`'s R19 already implies (`$0.045`/hr →
~₹2,800/mo). Everything below is what remains running after `park.yml` completes.

| Line item | USD/mo | ₹/mo |
|---|---|---|
| Data disk — 20 GiB StandardSSD_LRS, billed at E4 (32 GiB) | `$2.40` | **₹204** |
| `restic` container in `listeninfratfstatesa` — Hot LRS, ~10 GB repo × 1.5 for versions/soft-delete ≈ 15 GB | `$0.36` | **₹30** |
| Blob transactions while parked (nothing is running) | ~`$0.00` | ₹0 |
| Inter-region egress, `southindia` → `centralindia` (see below) | — | — |
| Azure DNS public zone (first 25 zones) + query volume at lab scale | `$0.50` | **₹43** |
| Terraform state blobs (`do-not-delete`, pre-existing, < 1 MB) | ~`$0.00` | ₹0 |
| VNet, subnet, NSG, all resource groups, both UAMIs, every role assignment | `$0.00` | ₹0 |
| **Total** | **`$3.26`** | **≈ ₹277** |

**≈ ₹123 of headroom** against the ≤ ₹400 target — which is thinner than it looks, and one specific
thing eats it:

**R19 forward-reference.** A NAT Gateway ([#164](https://github.com/114snehasish/homelab/issues/164))
bills hourly at ~`$0.045`/hr. Per `docs/roadmap.md` that is ~₹230/mo of running cost even when it is
destroyed on park, and ~₹2,800/mo if it is ever left up — which swamps this entire budget on its own,
several times over. **The budget lives here and the teardown lives in `#164`**, so the two must not
be reasoned about separately: E17.5 owns NAT Gateway teardown *in park from day one*, or this table
is fiction.

**The egress line is zero while parked and non-zero while running.** Per the 2026-09-12 amendment the
`restic` repository lives in `listeninfratfstatesa`, which is in `centralindia` while the lab runs in
`southindia`, so every backup write and every restore read crosses a region. Parked, nothing runs and
nothing is transferred, which is why the total above is unaffected. Running, it is a per-GB charge on
the nightly delta rather than on the repository size, so at lab volumes it is small — but it is not
zero, and it makes a full restore both slower and billable. `#102`'s measurement is what settles the
real figure; this line exists so the measurement is not mistaken for a discrepancy.

Transient lines not counted: the 7-day fallback snapshot `#98` retains after the migration, and the
running cost of the VM/NIC/public IP while the lab is *not* parked (the Standard static public IP
alone is `$0.005`/hr ≈ ₹310/mo — more than everything in the table above, and the reason park is
worth automating).

This table is computed from published retail prices, not observed spend.
[#102](https://github.com/114snehasish/homelab/issues/102)'s acceptance criterion is *"parked monthly
run-rate confirmed ≤ ₹400 (or the ADR's number corrected to reality)"* — when that measurement
exists, it supersedes this table and this ADR is edited to match.

## Consequences

- **Positive.** The disk can no longer be destroyed as collateral: it sits in a resource group no
  Terraform module manages, and CI's grant there cannot delete. Docker can no longer silently write
  app state to an ephemeral OS disk. Park cannot run without a verified backup. Every one of the
  seven open decisions the architecture review raised now has an answer a later child can implement
  rather than invent.
- **The bootstrap grows, and rebuild ordering gets longer.** A from-scratch rebuild is now: the
  out-of-band `az` script → `infra/dns` → `infra/identity` (which reads the DNS zone, per ADR-0013,
  and now also grants into the persist RG) → `infra/network` → `infra/storage` → `compute/vm`. Three
  of those steps are local applies as Owner. In a repo whose modules are otherwise coupled only by
  naming convention, that ordering is real and is only written down in prose — here and in
  `docs/oidc_bootstrap.md`.
- **The guard is fail-closed, which means this ADR deliberately creates a "the lab will not come up"
  mode.** A disk that fails the marker check leaves Docker stopped. That is the flagship guarantee
  and it is also a new way to be down; the re-bless procedure in §3 is the documented recovery, and
  it must be in the runbook before `#99` ships, not after the first time it fires.
- **The backup account's protective settings are unreconciled.** §2's second condition. Terraform
  will never notice if versioning or soft delete is turned off, so the drill checks it. Since the
  2026-09-12 amendment that account is `listeninfratfstatesa` and the settings are account-level, so
  the drill's assertion covers the state blobs too.
- **Everything is LRS, on both tiers — and since the 2026-09-12 amendment, no longer in one
  region.** T1 is in `southindia`, T2 in `centralindia`. That is a side effect of reusing the state
  account, not a disaster-recovery strategy: two regions do not help when the *failure* being
  designed for is the repository being deleted by its own credential (R22). §5's accepted residual
  risk is unchanged; what changed is that the backup path now pays egress to cross a region it was
  never trying to cross.
- **This overturns text already merged in three places** — `#98` (Cool tier), `#205`
  (`Disk Contributor`, and Terraform-managed persist resources) and `docs/roadmap.md`'s E15 section.
  `docs/roadmap.md` is corrected in the same PR, following ADR-0013's precedent; `#98` and `#205`
  carry comments naming exactly which acceptance criteria changed, so neither is discovered mid-
  implementation.
- **Public mirror (R6).** `main` is force-mirrored publicly, so this ADR is public. Everything in it
  is non-secret by construction: resource group and container names, role names, retention windows
  and published retail prices. No client ids, no account names, no host detail.

## Open items

- [x] Pin the exact action list for the custom disk role — done in [#205](https://github.com/114snehasish/homelab/issues/205), recorded in §2. The negatives are proven *by definition reading* (`az role definition list` asserts two actions and one assignable scope); the **behavioural** proof still has no home, because no CI workflow plans `infra/identity` — it arrives with [#98](https://github.com/114snehasish/homelab/issues/98), the first change that makes CI touch the persist RG.
- [ ] Raise blob soft-delete retention to 30 days and enable versioning on `listeninfratfstatesa`, or consciously accept a weaker R22 posture ([#100](https://github.com/114snehasish/homelab/issues/100), §6c amendment). These are account-level and therefore also change `tfstate` and `secret-files`.
- [ ] Measure the `southindia` → `centralindia` egress the amendment introduces and fold it into §8 ([#102](https://github.com/114snehasish/homelab/issues/102)).
- [ ] Verify restic against the real storage account with a **user-assigned** managed identity, and pin the restic version, before [#100](https://github.com/114snehasish/homelab/issues/100) ships — the current stable docs describe managed-identity support but do not document how a user-assigned identity is selected. Verified, not projected (ADR-0013's standard).
- [ ] Confirm that attaching a second UAMI does not break Caddy's DNS-01, and add `AZURE_CLIENT_ID` to `apps/caddy/.env` in the same change ([#100](https://github.com/114snehasish/homelab/issues/100), §6a).
- [ ] Replace §8's computed table with the figure measured in [#102](https://github.com/114snehasish/homelab/issues/102), or correct the design if reality disagrees.
- [ ] R22 strong form: custom no-delete data role for the VM + `forget --prune` in a scheduled CI job with its own identity ([#100](https://github.com/114snehasish/homelab/issues/100), §6c).
