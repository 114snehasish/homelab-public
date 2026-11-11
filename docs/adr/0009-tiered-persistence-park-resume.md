# ADR-0009: Tiered persistence and the park/resume lifecycle

- **Status**: Accepted — the parked-cost table in section 8 is computed from published retail prices and is superseded by the measured figure [#102](https://github.com/114snehasish/homelab/issues/102) records. **Amended 2026-09-12 ([#205](https://github.com/114snehasish/homelab/issues/205)): §1, §2, §6a, §6c and §8 — there is no separate backup storage account; the `restic` container lives in the existing state storage account `listeninfratfstatesa`, and the out-of-band script creates only the resource group.** See [§2's amendment block](#amendment-2026-09-12-205--no-separate-backup-storage-account). **Amended again 2026-09-12 ([#98](https://github.com/114snehasish/homelab/issues/98)): §2 and §3 — the migration was an `az resource move`, not a snapshot-swap, and ran with the lab parked.** See [§2's second amendment block](#amendment-2026-09-12-98--the-migration-was-a-resource-group-move-not-a-snapshot-swap). **Amended again 2026-09-13 ([#99](https://github.com/114snehasish/homelab/issues/99)): §3, §4, §7 and Consequences — the mount contract as built, both Docker storage roots on `/data`, and the park restart-policy trap.** See [§3's amendment block](#amendment-2026-09-13-99--the-contract-as-built). **Amended again 2026-09-28 ([#100](https://github.com/114snehasish/homelab/issues/100)): §1, §2, §6a, §6c, §8 and Consequences — the 2026-09-12 (#205) amendment is *reversed* for the storage account. A dedicated backup account `homelabpersistbackupsa` is created in `homelab-persist-rg` by a new local-apply module `infra/backup`; `do-not-delete` and `listeninfratfstatesa` are not touched at all, and §6c is therefore met in full.** See [§2's third amendment block](#amendment-2026-09-28-100--the-dedicated-backup-account-returns-in-the-persist-rg). **Amended again 2026-10-13 ([#101](https://github.com/114snehasish/homelab/issues/101)): §4 and §5 — park is backup → graceful stop → deallocate → destroy, the apps layer moved to `/data/apps`, `destroy.yml` became park plus the Cloudflare leg, and CI reaches nodes through Azure Run Command (new risk R23).** See [§5's amendment block](#amendment-2026-10-13-101--park-and-resume-as-workflows). **Amended again 2026-11-10 ([#102](https://github.com/114snehasish/homelab/issues/102)): §5 — why park keeps the data disk rather than restoring from T2, and the per-node disk cost that leaves open at fleet scale.** See [§5's second amendment block](#amendment-2026-11-10-102--why-park-keeps-the-disk-and-the-fleet-cost-it-leaves-open). **Amended again 2026-11-11 ([#102](https://github.com/114snehasish/homelab/issues/102)): §8 — the parked cost is measured at ≈ ₹275/mo over 31 parked days and supersedes the computed table.** See [§8's amendment block](#amendment-2026-11-11-102--measured-and-it-supersedes-the-table-above).
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
| **T0 — control** | Terraform state; DNS zone `az.snehasish-chakraborty.com`; the backup storage account `homelabpersistbackupsa` and its `restic` container; Key Vault (E05); both UAMIs and every role assignment; VNet/subnet/NSG | `do-not-delete`, `homelab-rg`, `homelab-identity-rg`, `homelab-persist-rg` | out-of-band script (§2), `infra/dns`, `infra/backup`, `infra/identity`, `infra/network` | **yes** |
| **T1 — hot block** | The pet disk: live databases, app state, Prometheus/Loki history, Caddy's cert store and ACME account (`/data/caddy`), k3s PVs (`/data/k8s-pv`) | `homelab-persist-rg`, attached at LUN 10, mounted `/data` | `infra/storage` (Terraform) | **yes** |
| **T2 — cold logical** | restic repository: encrypted, deduplicated, versioned snapshots of `/data` | `restic` container in `homelabpersistbackupsa` (RG `homelab-persist-rg`) | account and container by `infra/backup`; snapshots by `#100`, running on the VM | **yes** |
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

> **⚠️ Superseded in part by the [2026-09-28 (#100) amendment](#amendment-2026-09-28-100--the-dedicated-backup-account-returns-in-the-persist-rg)
> below.** Everything this block says about the **resource group** — created out-of-band by
> `scripts/bootstrap-persist-rg.sh`, never Terraform-managed — stands and is shipped. Everything it
> says about the **storage account** is reversed: a dedicated backup account
> `homelabpersistbackupsa` *does* exist, in `homelab-persist-rg`, created by `infra/backup`, and
> `listeninfratfstatesa` is not touched. The block is kept as written because the three costs it
> records are exactly why the decision was revisited. Read it as history, not as the current design.

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
  `secret-files` too. **This cost is withdrawn by the 2026-09-28 amendment** — `infra/backup`
  declares all five properties in Terraform, so a plan re-asserts them; `#102`'s assertion stays as
  the backstop, because that module has no CI workflow.

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
nothing else. It has no blob rights there and no `Microsoft.Storage/*` at all — the data-plane grant
on the `restic` container belongs to the VM's own backup identity (§6a), never to CI. What CI cannot
do: delete the resource group, the storage account, the container, or any disk. `#205` proves the
negatives by observation, not by reading role definitions.

#### Amendment (2026-09-28, #100) — the dedicated backup account returns, in the persist RG

**The 2026-09-12 (#205) amendment above is reversed for the storage account, and only for that.** Its
resource-group half — `homelab-persist-rg` created out-of-band, never Terraform-managed, plus the
scoped CI disk grant — stands unchanged and is already shipped.

**Decision: a dedicated backup storage account `homelabpersistbackupsa` in `homelab-persist-rg`,
holding one container, `restic`, and nothing else. `do-not-delete` and `listeninfratfstatesa` are not
touched at all.** It is created by a new root module `infra/backup`, applied **locally as Owner**,
with deliberately no workflow — the same shape `infra/identity` already has, and for the same reason:
CI's custom role in that RG is `disks/read` + `disks/write`, and granting it
`Microsoft.Storage/storageAccounts/write` would let CI delete the backup account, which is precisely
what §2 exists to prevent.

The #205 arrangement was reasoned as "the lab does not need a second protected account to hold one
more container". True as far as it went, and it bought three problems, each recorded in that
amendment as an accepted cost:

1. **Cross-region.** The state account is in `centralindia`, the lab in `southindia`, so every backup
   write and every restore read crossed a region — on the tier whose entire purpose is recovery.
2. **Versioning and soft delete are account-level.** Meeting §6c's R22 mitigation meant changing the
   protective settings of the account holding `tfstate` and `secret-files`. That is a change to a
   *Never touch* resource, which made §6c effectively unreachable rather than merely awkward.
3. **`secret-files` shares that account.** One mistaken account-scoped grant would have handed an
   internet-facing edge VM the Terraform state and that container along with the backups.

A dedicated account dissolves all three at once, and the resource group it belongs in is the one this
lab already created to hold what must outlive everything else. The disk was never the only thing that
belonged there. The result is also schematically clearer: `do-not-delete` is the pre-existing estate
inherited from outside this repo, and `homelab-persist-rg` is *this lab's* persistence.

**Three consequences follow, and all three are improvements:**

- **§6c is now met in full** — blob versioning enabled, blob and container soft delete at 30 days, as
  §6c specified all along. The "consciously accept a weaker posture" escape hatch that amendment
  created is no longer needed and is withdrawn.
- **Account keys are disabled outright** (`shared_access_key_enabled = false`). §6a's rule "never an
  account key" stops being a policy someone can forget and becomes a property of the account: no
  account key works, for anybody, ever. This could never have been done to `listeninfratfstatesa`,
  whose `tfstate` backend depends on key access being *available* even though this repo's CI does not
  use it.
- **The protective settings are reconciled by a plan again.** The Consequences section below recorded
  it as a defect that Terraform would never notice versioning or soft delete being switched off.
  `infra/backup`'s `blob_properties` block makes both plan-detectable. Honest limit: that module has
  no CI workflow, so drift is caught on demand rather than continuously — the same standing as
  `infra/identity` today.

**One thing gets worse and is recorded rather than hidden.** T1 and T2 are co-regional again, both in
`southindia`, so a regional loss takes both. #205's cross-region split was a side effect of reusing
the state account, never a disaster-recovery strategy, and §5's accepted residual risk is unchanged —
what changes is that co-regional is now a deliberate choice. `Standard_LRS` was chosen over `GRS`
against the ≤ ₹400/mo parked budget; GRS remains the obvious lever if that risk is ever re-priced.

**The bootstrap order grows by one step**, and it is load-bearing because a role assignment's scope
must already exist:

`scripts/bootstrap-persist-rg.sh` → `infra/dns` → **`infra/backup`** → `infra/identity` →
`infra/network` → `infra/storage` → `compute/vm`. Four of those are local applies as Owner.

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

#### Amendment (2026-09-13, #99) — the contract as built

**`#99` implements this section as a chain of systemd units, and settles what the table above left
open.** Per (LUN → mount) entry, every boot: `homelab-persist-prepare@<lun>.service` → the disk's
`.mount` unit → `homelab-data-guard@<mount>.service` → `homelab-persist.target`, which
`containerd.service` and `docker.service` require through drop-ins. Sources are in
`compute/vm/persist/`, assembled into `custom_data` by `compute/vm/cloud-init.tf` without
`templatefile()`. Every FATAL line and its recovery, the re-bless command included, is in
[`docs/runbooks/data_guard.md`](../runbooks/data_guard.md).

- **Automatic blessing is scoped to one filesystem and one boot.** Prepare formats only a disk that
  carries no signature at all, and records the new filesystem's UUID in
  `/run/homelab-persist/lun<N>.formatted`. The guard calls `write-persist-marker.sh --created-by
  cloud-init` only when the marker is absent **and** that UUID is the mounted filesystem's. `/run`
  is tmpfs, so an unmarked disk that was not formatted this boot — a restore, a disk from elsewhere —
  is never blessed without a human.
- **Three more rows.** `mount` ≠ the guarded mount point → **warn**: it is reassignable by
  configuration, like `disk_name`. `schema` ≠ `1` → **fatal**. IMDS still unreachable after ~60 s of
  retries → **fatal**: an identity that cannot be checked is not trusted.
- **The marker is parsed as `key=value` data, never sourced.** It lives on the data disk and is read
  as root at boot.
- **The disk can arrive after boot, by design.** `azurerm_virtual_machine_data_disk_attachment` is
  created only once the VM exists, so on the first boot of every recreated VM — every resume — the
  disk appears seconds to minutes late. Prepare waits up to 300 s for it. A short device timeout would
  fail resumes, not just disk-less boots (and `x-systemd.device-timeout=` is ignored outside fstab
  anyway). For the same reason the `.mount` unit's `What=` is not the `/dev/disk/azure/…` path: any
  `What=` under `/dev` makes systemd queue its own device job with a 90 s timeout, which the #99 test
  VM showed failing the mount and Docker on a disk attached at +120 s, well inside prepare's
  wait. Prepare instead links the partition it vetted as `/run/homelab-persist/lun<N>-part1`, and
  the mount uses that link, which gets no device job. IMDS lags the attachment as well:
  `storageProfile/dataDisks` can leave a just-attached disk out for about a minute, so before an
  automatic bless the guard waits up to 120 s for IMDS to list the LUN. The writer refuses a LUN
  that IMDS does not list. On the verify path a missing name costs only a `disk_name` warning.
- **The boot survives a missing or rejected disk; only the container runtime does not.** The mount
  unit is ordered after `local-fs.target` rather than before it, so nothing in early boot waits on it:
  the node stays reachable over SSH, and the units also log to the serial console that the VM's
  `boot_diagnostics` exposes.

### 4. What persists, and what resets every cycle

**Persists.** *T0:* Terraform state; the DNS zone and its static records; the backup storage account
and restic repository; both user-assigned identities and every role assignment; VNet, subnet, NSG and
the resource groups themselves; Key Vault once E05 lands. *T1, on `/data`:* app state and live
databases; Prometheus and Loki history; Caddy's certificates and ACME account; k3s PVs; and, since
`#99`, Docker's and containerd's storage — images, snapshots, volumes, networks and containers.

**Resets every cycle.** Everything below is destroyed by park and rebuilt by resume. The point of
listing it is that each line is something a future change could accidentally depend on.

| Resets | Consequence, and who owns it |
|---|---|
| **Public IP address** | Park destroys it; resume mints a new one. The wildcard `*` record is an alias to the public IP resource (`target_resource_id`), so it re-points with **no Terraform run in `infra/dns`** — that elegance is the reason nothing else may pin the literal address. **Nothing may hard-code the IP**: not a firewall allow-list, not a monitoring target, not a bookmark. |
| **SSH host keys** | Regenerated on every fresh OS disk. Combined with the new address above, `known_hosts` breaks on **both** axes every cycle — `ssh-keygen -R` for the old host and address belongs in the resume runbook (`#102`), not in the reader's muscle memory. |
| **Tailscale machine state** | Every resume registers a **brand-new tailnet node**. Park weekly and within two months the tailnet is a graveyard of dead machines with MagicDNS names drifting `homelab-edge-1`, `-2`, … — silently breaking anything that addresses the node by name. Caused here, **owned by E06** ([#54](https://github.com/114snehasish/homelab/issues/54)); the mitigation is named so E06 inherits it rather than rediscovering it: **ephemeral auth keys** (the node is reaped automatically on disconnect) plus a **pinned `--hostname`**. |
| **OS disk and everything on it** | Installed packages, the Docker and containerd binaries, journald history. Anything that must survive lives on `/data` — since `#99` that includes all of Docker's storage (next row). |
| **Docker containers, images and layers** — *no longer resets, since `#99`* | `data-root` is `/data/docker` and containerd's root is `/data/containerd`, both behind the data-guard. **Both** roots, because Docker Engine 29+ keeps image content and container snapshots under containerd's root, which `data-root` does not move: moving `data-root` alone would persist containers without the snapshots they point at, and none would restart after a recreate. Two consequences. **Park must leave containers running** — `restart: unless-stopped` does not bring back a container that was explicitly stopped, so a `docker compose stop` or `down` before park means it stays down after resume ([#101](https://github.com/114snehasish/homelab/issues/101)). And **a bind-mount source outside `/data` does not survive** — which is why [#101](https://github.com/114snehasish/homelab/issues/101) moved the apps layer to `/data/apps/<app>`, after Caddy's `./Caddyfile` under `/home/azureuser/apps` came back as a root-owned directory on the 2026-10-06 resume. Park stops containers only through a graceful OS shutdown, never `docker compose stop`/`down` (§5's 2026-10-13 amendment). |
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

#### Amendment (2026-10-13, #101) — park and resume as workflows

**`#101` builds this section as four dispatchable workflows over two call-only cores, and settles
six things the section left open or got subtly wrong.** The decisions were taken one by one against
the 2026-09-08 architecture review's findings on `#101` (B3, D7, D8, D9), re-checked against the code
as it stood after `#99` and `#100`.

```
park.yml ────┐                          resume.yml ─┐
             ├─▶ _park.yml ─▶ _terraform.yml        ├─▶ _resume.yml ─▶ deploy-compute.yml ─▶ _terraform.yml
destroy.yml ─┘   (+ infra/cloudflare leg)          deploy.yml ─┘   (network → dns → cloudflare → storage → _resume)
```

1. **The park sequence is backup → graceful stop → deallocate → destroy.** The section said "final
   restic run, then destroy". Two facts made the middle step mandatory. azurerm 5.8.0 deletes a VM
   without powering it off first (verified in the provider's delete path), and Terraform destroys
   `azurerm_virtual_machine_data_disk_attachment` *before* the VM — so a bare destroy **hot-detaches
   `/data` from a running node**, leaving T1 crash-consistent at best. `az vm stop` requests a
   graceful guest shutdown by default: Docker stops every container, systemd unmounts `/data` cleanly,
   and only then does anything detach. `az vm deallocate` follows, so a destroy that is delayed or
   cancelled leaves a node that bills almost nothing. The backup runs **first, with apps up**, because
   the pre-hooks need running apps (`pg_dump`) and because it is then the same code path the nightly
   exercises every day.
2. **§4's "park must leave containers running" is precise now: park must never *user-stop* a
   container.** The review suggested `docker compose down` before the backup; that is exactly the trap
   §4 records, since `restart: unless-stopped` never restarts a container a user stopped. A graceful OS
   stop is not that: moby sets a container's manually-stopped flag only when the daemon is *not* shutting
   down (`daemon/kill.go`), so containers stopped by the shutdown come back by themselves when Docker
   starts on the resumed node. Resume checks it, and also checks that `e2fsck` found a clean filesystem
   rather than replaying a journal.
3. **The apps layer moved to `/data/apps/<app>`.** §4's Docker row already predicted it: bind sources
   on the OS disk did not survive, and on 2026-10-06 Docker recreated Caddy's missing `Caddyfile` as a
   root-owned directory and the container failed to start (exit 127 once, `RestartCount` 0, left
   `exited` — this said "restart-looped" until #102 checked). With compose files, `Caddyfile` and `.env` on
   the pet disk, a resume needs **no app redeploy step** — the boot contract `#99` already built
   restarts everything. No boot-time `compose up` unit was added; a restored disk (`#206`) has no
   Docker state (restic excludes it) and is where such a unit would earn its place.
4. **Park scope stays `compute/vm` only; `destroy.yml` = park + the Cloudflare delegation.** The two
   paths share `_park.yml`, so `destroy.yml` — which before `#101` destroyed compute with no backup at
   all — can no longer bypass the backup. Removing the delegation while the Azure zone survives is safe;
   the dangerous order (zone gone, delegation still pointing at it) is a takeover risk, and nothing in
   CI deletes the zone.
5. **"No backup, no park" has exactly one deliberate bypass.** `park.yml`'s `skip_backup`, honoured
   only when `skip_backup_confirm` is `park-without-backup`, still stops and destroys through the same
   pipeline, and its summary says plainly that no final snapshot exists and how to read the repository
   from a laptop (CI holds no rights on the `restic` container and is not given any). `destroy.yml`
   cannot skip the backup. A half-finished park — backed up and deallocated, destroy failed — is
   finished with *Re-run failed jobs*, which does not repeat the backup.
6. **Park is fleet-wide.** `compute/vm` builds every `fleet.tfvars` entry, so park backs up, stops and
   destroys every node; per-node park is `#167`. Restic ships only to the public-edge node — a scoping
   choice in `#100`, not a principle of this ADR — so a node without the backup contract **fails its
   backup and aborts the park** rather than being destroyed unbacked. Making restic fleet-wide (one
   shared repository, snapshots per host, staggered prunes, R22 widening to every node) is `#166`'s.

**Concurrency.** The four dispatchers hold `concurrency: {group: homelab-terraform, queue: max}`; the
cores declare no top-level group, because a called workflow sharing its caller's group is reported to
be cancelled as a deadlock and GitHub does not document called-workflow concurrency. Terraform still
runs only through `_terraform.yml`, so the per-state-blob `tf-` job group keeps protecting the state —
the lifecycle group *supplements* it (review finding 4).

**CI reaches nodes through Azure managed Run Command.** Park's backup and resume's checks need to run
something on a node, and in 2026-10 nothing else could: the NSG admits SSH from one whitelisted IP, CI
holds no SSH key, and Tailscale (E06) is unbuilt. Run Command is authorised by Azure RBAC alone (the
CI identity's Contributor on `homelab-rg`), needs no key and no NSG change, and its scripts
(`scripts/lifecycle/`) are shipped per run, so they cost nothing against the `custom_data` budget. It
is delivered as a VM extension, so `compute/vm` sets `allow_extension_operations = true`. **That is a
posture change, recorded as roadmap R23**: the CI identity can now run root commands inside a running
node. It is not new *reach* — Contributor on `homelab-rg`, `disks/write` in the persist RG and
Managed Identity Operator over the edge identity already let CI build a VM that holds the pet disk and
that identity — but it removes the friction and the visible VM churn of doing so.

**Not done, and recorded:** Telegram notifications on completion — deferred to E08 (`#65`), the same
call `#100` made; GitHub's own failed-run notification and the job summaries cover a human-dispatched
workflow. The subscription-wide "only the parked set remains" check — CI deliberately cannot list the
subscription, so `_park.yml` asserts what it can see (no VM, NIC, public IP, OS disk or A record left
in `homelab-rg`; data disks `Unattached`) and `#102`'s drill records the full check.

#### Amendment (2026-11-10, #102) — why park keeps the disk, and the fleet cost it leaves open

**This section said park destroys `compute/vm` only, but never recorded the obvious alternative: a
final backup makes T2 complete at park time, so why not delete the disk too and restore it on
resume?** The question came up during `#102`'s drill, and the answer belongs here rather than in
someone's memory. The disk stays, for five reasons:

1. **T2 is the second copy, not a substitute for T1.** With the disk kept, a parked lab holds two
   independent copies of `/data`. Deleting it leaves the restic repository as the only one — LRS,
   same region, and unreadable if its password is lost (R13).
2. **Restore-from-blob is unproven.** [#206](https://github.com/114snehasish/homelab/issues/206) has
   not run. Resume today is a re-attach with RPO 0; deleting the disk would make the one path never
   exercised the path every resume takes.
3. **T2 does not hold what a resume needs.** restic excludes `/data/docker` and `/data/containerd`, so
   a restored disk has no images and no containers, and nothing starts them — the 2026-10-13
   amendment above deliberately added no boot-time `compose up`.
4. **A restored disk fails the data-guard on purpose** (§3): its filesystem UUID is new, so Docker
   stays down until a human re-blesses the marker. Every resume would need that manual step.
5. **CI cannot delete a disk, by design** (§2: the custom role omits `disks/delete`). Deleting disks
   on park means handing CI the one right §2 exists to withhold.

**What this leaves open is fleet scale, and it is not small.** §8 prices **one** disk at ₹204/mo
(≈ ₹6.8/day). [#165](https://github.com/114snehasish/homelab/issues/165) (E17.6) gives *every*
`fleet.tfvars` entry its own disk, so ten nodes would park at ≈ ₹2,040/mo in disks alone — five
times the ≤ ₹400 target, before any other line. The levers, in the order they should be considered:

- **Not every node needs a pet disk.** A node with no state of its own — a k3s worker whose cluster
  state Argo CD rebuilds from git (§4) — is cattle all the way down. `#165` should make the disk
  per-node opt-in rather than one per entry.
- **Right-size the disk.** The edge disk holds ~2.3 GB of a 20 GiB disk billed at 32 GiB (§7); each
  smaller tier roughly halves the price. Verify current prices before choosing.
- **Snapshot-and-delete on park,** only for nodes whose state restic fully covers, and only once
  `#206` has proven the restore. Incremental snapshots bill on used bytes, so it is cheap — but it
  meets the `create_option` read-back trap (CLAUDE.md), the re-bless step above, and CI's missing
  `disks/delete`, so it is a design change, not a flag.

**Decision for now:** the single edge disk stays; ₹204/mo is inside the budget. The per-node
question is `#165`'s to settle before it merges, and §8's measured figure (`#102`) is per disk so
it scales honestly.

### 6. Tier 2 mechanics

#### 6a. restic authenticates as a managed identity, never an account key

An account key on the VM is the easy path and is **excluded**. `infra/identity/main.tf` already
records why, about the state container:

> *"Deliberately NOT a role on the storage account, which would also confer listKeys — the key is a
> bearer credential for every container in the account, which is exactly what OIDC is replacing."*

Putting an account key on the internet-facing edge VM would undo E02's posture in the one place that
holds every backup.

*The separate identity below, and the `AZURE_CLIENT_ID` pin that went with it, were reversed by the
2026-11-09 amendment at the end of this section. The container scope and the refusal of account keys
stand.*

**Decision: a third user-assigned managed identity, `homelab-backup-identity`, holding `Storage Blob
Data Contributor` scoped to the `restic` container — not the storage account.** Same container-scope
reasoning as the `tfstate` grant. Since the 2026-09-28 amendment the container lives in its own
account, `homelabpersistbackupsa`, which holds nothing else — so an account-scoped grant here would
be *merely* wider than needed rather than catastrophic. It is still refused: the scope is the
container, because the rule is about what the credential can reach, not about what happens to be
next to it today. That account additionally sets `shared_access_key_enabled = false`, which turns
"never an account key on the VM" from a rule into a property of the account.
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

##### Amendment (2026-11-09, #285) — one identity, because the pin never worked

**The paragraph above predicted the failure correctly and prescribed a fix that could not work.**
`caddy-dns/azure` v0.6.0 uses `libdns/azure` v0.5.0, whose `client.go` calls
`azidentity.NewManagedIdentityCredential(nil)`: it names no client id and never reads
`AZURE_CLIENT_ID`. Setting `client_id` in the Caddyfile is no way out either, because setting any of
`tenant_id`/`client_id`/`client_secret` selects `NewClientSecretCredential`. So this plugin works only
on a VM carrying exactly one user-assigned identity. `#100` attached a second one, and on 2026-11-09,
the first start inside Let's Encrypt's renewal window, every renewal failed with IMDS's *"Multiple
user assigned identities exist"*. Caddy kept serving its existing certificate, which expires
2026-12-06, so nothing looked wrong. `#100`'s evidence had proved Caddy could *load* a certificate,
not renew one, and `node-health.sh` reported OK for the same reason.

**Decision: the edge VM carries exactly one user-assigned identity, `homelab-edge-dns-identity`,
holding both `DNS Zone Contributor` on the zone and `Storage Blob Data Contributor` on the `restic`
container.** `homelab-backup-identity`, its grant and CI's `Managed Identity Operator` over it are
removed. The name now understates the identity; renaming it would replace it and mint a new client id
for no functional gain, and `#286` would restore the narrow meaning. restic still receives
`AZURE_CLIENT_ID`, now naming this identity, because its scripts require the variable.
`node-health.sh` now reports FATAL when a failed renewal has no later success.

**What this costs.** One identity holds DNS and backup rights, so the audit trail can no longer tell
them apart, and a token minted for either purpose is valid for both.

**It gives up less isolation than it appears to.** IMDS serves a token for *any* identity attached to
the VM to any process that names its client id, so a compromised container on this VM could already
request the backup identity's token. The two-identity design separated the audit trail and nothing
else; it never isolated Caddy from the backups, and this ADR should not have implied that it did. R22
and its mitigation, blob versioning plus 30-day soft delete (§6c), are unchanged in substance.

**Follow-ups.** `#286` forks `libdns/azure` to honour a client id and splits the identities again.
`#166` must decide what identity a private node carries, since this one holds DNS rights a private
node should not get.

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

**Shipped now (by `infra/backup`, per the 2026-09-28 amendment):** blob versioning and soft delete,
retention **30 days**, on an account that holds backups and nothing else. The window is not arbitrary
— the lab is *parked for weeks at a time*, so a 7-day window would expire unobserved while nobody is
looking at anything. 30 days exceeds a realistic detection window for a lab that is only
intermittently attended. Per §2 these settings are no longer reconciled by any Terraform plan, so
`#102`'s drill and the park runbook assert them.

> **Corrected by the 2026-09-12 amendment; the objection withdrawn 2026-09-28.** This section said
> "on the container", which is technically wrong: blob versioning (`isVersioningEnabled`) and soft
> delete (`deleteRetentionPolicy`) are **blob-service properties, i.e. account-level** — there is no
> per-container form of either. That correction stands and is worth keeping, because it is the kind
> of thing that is rediscovered expensively.
>
> What no longer stands is the consequence it drew. While the container lived in
> `listeninfratfstatesa`, applying this mitigation would have changed behaviour for `tfstate` and
> `secret-files` too — a change to a *Never touch* resource, which is why "consciously accept a
> weaker R22 posture" was offered as an alternative. The 2026-09-28 amendment gives the repository
> its **own** account, so account-level and backup-only are now the same scope. **This section is met
> in full and the weaker-posture escape hatch is withdrawn.** For the record, `listeninfratfstatesa`
> remains as it was on 2026-09-12 — blob soft delete 7 days, container soft delete 7 days, versioning
> off — and `#100` deliberately did not touch it.

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
| Docker `data-root` + containerd root (`#99`): images, snapshots, volumes, container logs | 8 GB | images dominate; container logs capped at 10 MB × 3 per container |
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
| `restic` container in `homelabpersistbackupsa` — Hot LRS, `southindia`, ~10 GB repo × 1.5 for versions/soft-delete ≈ 15 GB | `$0.36` | **₹30** |
| Blob transactions while parked (nothing is running) | ~`$0.00` | ₹0 |
| Inter-region egress | `$0.00` | ₹0 |
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

**The egress line is zero, and as of the 2026-09-28 amendment it is zero while running too.** The
2026-09-12 amendment put the repository in `listeninfratfstatesa` (`centralindia`) while the lab runs
in `southindia`, so every backup write and every restore read crossed a region — small at lab volumes,
but non-zero and slower on the one path whose purpose is recovery. `homelabpersistbackupsa` is in
`southindia`, co-regional with the disk and the VM, so that charge does not arise. **`#102`'s
open item to measure it is therefore void, not outstanding.** The trade taken in exchange is recorded
in §5 and in the 2026-09-28 amendment: co-regional means a regional loss takes both tiers.

Transient lines not counted: the 7-day fallback snapshot `#98` retains after the migration, and the
running cost of the VM/NIC/public IP while the lab is *not* parked (the Standard static public IP
alone is `$0.005`/hr ≈ ₹310/mo — more than everything in the table above, and the reason park is
worth automating).

This table is computed from published retail prices, not observed spend.
[#102](https://github.com/114snehasish/homelab/issues/102)'s acceptance criterion is *"parked monthly
run-rate confirmed ≤ ₹400 (or the ADR's number corrected to reality)"* — when that measurement
exists, it supersedes this table and this ADR is edited to match.

#### Amendment (2026-11-11, #102) — measured, and it supersedes the table above

**Measured: ≈ ₹275/mo for today's parked set, inside the ≤ ₹400 target.** Source: Azure Cost
Analysis, actual billed cost, averaged over **31 consecutive fully parked days, 2026-10-09 to
2026-11-08**. The daily rate is measured; the monthly figure is that rate × 30.

| Line item | Computed above | Measured ₹/day | Measured ×30 |
|---|---|---|---|
| Data disk (billed on the provisioned 32 GiB tier, not the ~2.3 GB used) | ₹204 | 7.48 | **₹224.38** |
| `homelabpersistbackupsa`, all meters (storage, versions, transactions) | ₹30 | 0.15 | **₹4.35** |
| Azure DNS zone | ₹43 | 1.55 | **₹46.35** |
| Terraform state (`listeninfratfstatesa`) | ₹0 | 0.00 | ₹0.03 |
| `#98`'s rollback snapshot (deleted 2026-11-10) | not counted | 0.08 | ₹2.27 |
| **Total** | **≈ ₹277** | **9.25** | **₹277.38**; ≈ ₹275 without the snapshot |

**The total agrees to the rupee, and that is a coincidence: two line items are wrong in opposite
directions.**

- **The fixed lines bill about 10% above the estimate.** The disk ($2.40) and the zone ($0.50)
  imply about ₹93/USD, not the stated ₹85. Every USD figure in this ADR and in `docs/roadmap.md`
  converted at ₹85 is low by the same proportion, R19's NAT Gateway (~₹2,800/mo if left up) included.
- **The backup line is about 7× too high.** It assumed a ~10 GB repository × 1.5. The real
  repository is small: restic excludes Docker's and containerd's roots, which hold almost all of
  `/data`'s bytes, and what remains is Caddy's state and the apps layer. §6b's revisit trigger
  (~100 GB) is nowhere near.
- **Blob transactions while parked are inside the backup line** and are negligible, as computed.
  Nothing runs while parked, so nothing writes.

**Headroom is ≈ ₹125**, and the two things that would consume it are recorded elsewhere: R19 (the
NAT Gateway, `#164`) and the per-node disk at fleet scale (§5's 2026-11-10 amendment, `#165`).
Procedure, checks and every drill timing: [`docs/runbooks/park_resume.md`](../runbooks/park_resume.md).

## Consequences

- **Positive.** The disk can no longer be destroyed as collateral: it sits in a resource group no
  Terraform module manages, and CI's grant there cannot delete. Docker can no longer silently write
  app state to an ephemeral OS disk. Park cannot run without a verified backup. Every one of the
  seven open decisions the architecture review raised now has an answer a later child can implement
  rather than invent.
- **The bootstrap grows, and rebuild ordering gets longer.** A from-scratch rebuild is now: the
  out-of-band `az` script → `infra/dns` → `infra/backup` → `infra/identity` (which reads the DNS zone
  per ADR-0013, the backup account per §6a, and grants into the persist RG) → `infra/network` →
  `infra/storage` → `compute/vm`. **Four** of those steps are local applies as Owner, since the
  2026-09-28 amendment added `infra/backup`. In a repo whose modules are otherwise coupled only by
  naming convention, that ordering is real and is only written down in prose — here and in
  `docs/oidc_bootstrap.md`.
- **The guard is fail-closed, which means this ADR deliberately creates a "the lab will not come up"
  mode.** A disk that fails the marker check leaves Docker stopped. That is the flagship guarantee
  and it is also a new way to be down; the re-bless procedure in §3 is the documented recovery, and
  it must be in the runbook before `#99` ships, not after the first time it fires — it shipped with
  `#99`, in [`docs/runbooks/data_guard.md`](../runbooks/data_guard.md).
- **The backup account's protective settings are reconciled again, on demand.** This bullet used to
  read "unreconciled": while the container lived in `listeninfratfstatesa`, Terraform would never
  notice versioning or soft delete being switched off, and `#102`'s drill was the only check. Since
  the 2026-09-28 amendment `infra/backup` declares both in a `blob_properties` block, so a plan
  detects the drift. The honest limit is that the module has **no CI workflow** — drift is caught
  whenever someone runs a plan, not continuously — so `#102`'s assertion is still worth keeping as
  the backstop, it is simply no longer the only thing standing there.
- **Everything is LRS, on both tiers, and since the 2026-09-28 amendment both are in `southindia`
  again.** The 2026-09-12 arrangement had T2 in `centralindia`, which was a side effect of reusing the
  state account rather than a disaster-recovery strategy — and two regions do not help against the
  failure actually being designed for, which is the repository being deleted by its own credential
  (R22). Co-regional is now the deliberate choice: it removes the egress and the slower restore, and
  it leaves §5's regional-loss gap exactly where §5 already put it, as an accepted residual risk for a
  homelab. `Standard_LRS` over `GRS` is the budget call; GRS is the lever if that risk is re-priced.
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
- [x] Raise blob soft-delete retention to 30 days and enable versioning, or consciously accept a weaker R22 posture — **resolved by the 2026-09-28 amendment, and neither branch was taken.** The repository moved to its own account (`homelabpersistbackupsa`), where versioning and 30-day blob and container soft delete are declared in `infra/backup` and apply to backups only. `listeninfratfstatesa` was not touched.
- [x] ~~Measure the `southindia` → `centralindia` egress~~ — **void.** The 2026-09-28 amendment makes T2 co-regional with T1, so the charge does not arise. [#102](https://github.com/114snehasish/homelab/issues/102) drops this measurement rather than reporting zero.
- [x] Verify restic against the real storage account with a **user-assigned** managed identity, and pin the restic version, before [#100](https://github.com/114snehasish/homelab/issues/100) ships — verified end-to-end against `homelabpersistbackupsa` on 2026-09-28, with `shared_access_key_enabled = false` so no account-key path existed even as a fallback. Pinned at **0.19.1**. Evidence on #100.
- [x] ~~Confirm that attaching a second UAMI does not break Caddy's DNS-01, and add `AZURE_CLIENT_ID` to `apps/caddy/.env` in the same change ([#100](https://github.com/114snehasish/homelab/issues/100), §6a)~~ — **this was ticked wrongly.** `#100` proved Caddy could load a certificate, not renew one, and the second UAMI did break renewal. Resolved by [#285](https://github.com/114snehasish/homelab/issues/285): the edge VM carries one identity and the pin is gone (§6a, 2026-11-09 amendment).
- [x] Replace §8's computed table with the figure measured in [#102](https://github.com/114snehasish/homelab/issues/102), or correct the design if reality disagrees — **measured ≈ ₹275/mo over 31 parked days** (§8, 2026-11-11 amendment). The design stands; two line items and the exchange rate were corrected.
- [ ] Decide per node whether a fleet entry gets a pet disk, before [#165](https://github.com/114snehasish/homelab/issues/165) merges — one disk per entry parks ten nodes at ≈ ₹2,040/mo in disks alone (§5, 2026-11-10 amendment).
- [ ] R22 strong form: custom no-delete data role for the VM + `forget --prune` in a scheduled CI job with its own identity ([#100](https://github.com/114snehasish/homelab/issues/100), §6c). Still open — `#100` shipped the versioning/soft-delete half only.
- [ ] Restic on every fleet node, not just the public edge — one shared repository with per-host snapshots, staggered `forget --prune` (the exclusive lock collides), and R22 widening to every node. Owned by [#166](https://github.com/114snehasish/homelab/issues/166); until then park aborts on a node without the backup contract (§5, 2026-10-13 amendment).
- [ ] Park and resume completion notifications, deferred to E08 ([#65](https://github.com/114snehasish/homelab/issues/65)) with the timers' alerting below. The subscription-wide parked-set check is [#102](https://github.com/114snehasish/homelab/issues/102)'s.
- [ ] `_terraform.yml`'s job-level `tf-` concurrency group keeps GitHub's default `queue: single`, so a *pending* park destroy can be cancelled by a newer queued plan. Park deallocates first, so that state is cheap, and Re-run failed jobs completes it. Revisit if it ever happens in practice.
- [ ] Failure alerting for the backup and check timers. `#100`'s scope item 4 specified a Telegram curl and it was **deferred whole to E08** ([#65](https://github.com/114snehasish/homelab/issues/65)) rather than built as a one-off — a failed run currently surfaces as a failed systemd unit in journald and pages nobody. Recorded so the gap is a decision rather than an oversight. Note [#207](https://github.com/114snehasish/homelab/issues/207)'s scope item 4 refers to "`#100`'s Telegram-curl pattern", which does not exist.
