# Runbook: park and resume

How to take the lab down to its parked floor and bring it back, how to check that each did what it
claims, and what to do when one stops halfway. Design and rationale:
[ADR-0009 §5](../adr/0009-tiered-persistence-park-resume.md#5-park-scope-and-the-resume-contract)
and its [2026-10-13 amendment](../adr/0009-tiered-persistence-park-resume.md#amendment-2026-10-13-101--park-and-resume-as-workflows).
Every number below was measured in the [#102](https://github.com/114snehasish/homelab/issues/102)
drill on 2026-11-10/11 unless it says otherwise.

**The model in one line: the VM is cattle, the disk is a pet.** Park destroys the VM, its NIC,
public IP and OS disk. It keeps the data disk, the backups, the DNS zone and the network. Resume
builds a new VM and re-attaches the same disk, and Docker brings every app back by itself.

## The four workflows

| Workflow | Does | Come back with |
|---|---|---|
| `park.yml` | Final backup → graceful stop → deallocate → destroy `compute/vm` → verify. Keeps the Cloudflare NS delegation | `resume.yml` |
| `destroy.yml` | Everything `park.yml` does, **plus** removes the Cloudflare NS delegation. Cannot skip the backup | `deploy.yml` (resume alone leaves public DNS dark, and warns so) |
| `resume.yml` | Apply `compute/vm` → `node-health.sh` on every node via Run Command → edge HTTPS/SAN check from the runner | — |
| `deploy.yml` | Every module in order; its compute leg is the same resume core | — |

All four default to a **dry run**: `apply` unchecked plans only, and never runs a Run Command or
stops anything. All four share one concurrency group with `queue: max`, so a second dispatch waits
its turn rather than interleaving or cancelling. **Dispatch from `main`**: the OIDC federated
credential trusts only `refs/heads/main` and pull requests.

**Park, not destroy, is the normal choice.** The delegation costs nothing to keep, and `destroy.yml`
exists for retiring the lab's public face, not for saving money.

## When to park

Park whenever the lab will sit idle for more than a couple of hours.

- **Parked:** ≈ ₹9.25/day, measured (below).
- **Running:** roughly ₹6 per hour for the VM, public IP and OS disk on top of that. That is read
  from two partial days, 2026-11-09 and 2026-11-10, so it is approximate, not measured.
- **A cycle costs about 10 minutes** of wall time: ~5 min to park, ~4½ min to resume.

Avoid dispatching a park in the nightly backup window (02:30–02:45 UTC). It is safe, since
`park-backup.sh` waits for an in-flight nightly instead of racing its lock, but the park takes longer.

## Park

```bash
gh workflow run park.yml --repo 114snehasish/homelab --ref main -f apply=true
gh run list --repo 114snehasish/homelab --workflow park.yml --limit 1
gh run watch <run-id> --repo 114snehasish/homelab --exit-status
```

Five jobs, in order. A failure in any one leaves everything after it skipped.

| Job | What it proves | Drill |
|---|---|---|
| Preflight | Inputs valid, fleet readable, bypass phrase checked before Azure is touched | 18 s |
| Final backup | `restic-backup final` on every node via Run Command; the snapshot is read back before anything stops | 1 m 22 s |
| Graceful stop + deallocate | `az vm stop` (guest shutdown: Docker stops containers, systemd unmounts `/data`), then `az vm deallocate` | 1 m 23 s |
| Destroy Compute | `terraform destroy` of `compute/vm`. The disk attachment goes first, the VM last | 1 m 17 s |
| Verify + summary | No VM, NIC, public IP, OS disk or A record left in `homelab-rg`; every data disk `Unattached` | 22 s |

**Drill: 5 m 02 s from dispatch to verified** (run 42759721120). The rehearsal park the same morning
took 5 m 16 s (run 42758382469).

### After a park: check it

The job summary lists each node's final snapshot id. Then, as the owner:

```bash
# 1. Order of operations: powerOff, then deallocate, then the disk detach (a VM write), then delete.
az monitor activity-log list -g homelab-rg --offset 30m \
  --query "[?contains(operationName.value,'virtualMachines/') && status.value=='Succeeded'].[eventTimestamp, operationName.value]" -o tsv | sort

# 2. The disk survived, unattached.
az disk show -g homelab-persist-rg -n homelab-data-disk --query "{state:diskState, uniqueId:uniqueId}" -o tsv

# 3. The delegation is still there (park keeps it).
dig +short NS az.snehasish-chakraborty.com @1.1.1.1

# 4. The subscription-wide parked set. CI deliberately cannot list the subscription, so this one
#    is yours. Use -o tsv: `-o table` silently drops a column aliased `type`.
az resource list --query "sort_by([], &resourceGroup)[].[resourceGroup, type, name]" -o tsv
```

**The parked set is exactly this**, and anything else in a `homelab-*` resource group is a leak:

| Resource group | What stays |
|---|---|
| `homelab-rg` | NSG `homelab-nsg-for-vm`, VNet `homelab-vnet`, DNS zone `az.snehasish-chakraborty.com` |
| `homelab-persist-rg` | Disk `homelab-data-disk`, storage account `homelabpersistbackupsa` |
| `homelab-identity-rg` | UAMIs `homelab-github-actions-identity`, `homelab-edge-dns-identity` |
| `do-not-delete` | State account `listeninfratfstatesa`, SSH keys. Pre-existing; never touched |

The subscription also holds resource groups that are not the lab's (`Learning`, `portfolio-rg-dev`,
`rg-114snehasish-9200`, `NetworkWatcherRG`, a Service Health alert group). They billed ₹0 over the
measured window and are not counted.

### The bypass: `skip_backup`

`park.yml` only, and only with `skip_backup_confirm` set to exactly `park-without-backup`. Anything
else fails the run before Azure is touched (proved by run 42627704989).

**It is legitimate for one case: a wedged node whose backup cannot run** — the disk failed its
guard, the VM does not answer Run Command, restic cannot reach blob. The park still stops,
deallocates and destroys through the same pipeline, and the summary says plainly that no final
snapshot exists. The latest backup is then the last nightly, so the RPO for that park is up to 24 h.
It is never a way to save the 1½ minutes a backup takes.

### A half-finished park

If the run fails **after** the backup succeeded (the stop, the destroy or the verify job), the
node is backed up and probably deallocated, so it costs almost nothing in that state. Finish it with
**Re-run failed jobs** on the same run. That does not repeat the backup. Do not dispatch a fresh
park instead: it would take a second final snapshot of a node that may already be stopped.

If a job never started at all, as when GitHub Actions had an incident on 2026-11-09 and park run
42670575051's verify job never ran, re-run it the same way, or do the four checks above by hand.

## Resume

```bash
gh workflow run resume.yml --repo 114snehasish/homelab --ref main -f apply=true
```

| Job | What it proves | Drill |
|---|---|---|
| Start clock | Records the start for the duration in the summary | 3 s |
| Compute | `terraform apply` of `compute/vm`: VM, NIC, public IP, A records, disk attachment | 1 m 04 s |
| Verify nodes + edge | `node-health.sh` on every node via Run Command, then HTTPS + SAN + delegation from the runner | 3 m 05 s |

**Drill: 4 m 22 s from dispatch to verified** (run 42965586037), after ~24 h parked. The rehearsal
resume the morning before took 3 m 57 s (run 42759016996).

### What `node-health.sh` checks, and what a healthy resume prints

```
OK    cloud-init: done
OK    persist: homelab-persist.target active (homelab-data-guard: OK /data: ...)
OK    persist: /data was cleanly unmounted (no journal replay)
OK    docker: active (waited 5s)
OK    container caddy: running since ...
OK    caddy: no ACME order and no unresolved renewal failure since Docker started
summary: 0 fatal
```

The lines that matter most:

- **`no journal replay`** is the proof that park's graceful stop worked. A WARN here means `/data`
  was detached or the VM died mid-write: crash-consistent, not clean. It warned on the 2026-11-09
  resume that followed a pre-#101 teardown, which hot-detached the disk; every resume after a
  graceful park has been clean.
- **`docker: active (waited Ns)`**: cloud-init starts Docker with `--no-block`, so a few seconds'
  wait is normal (5 s in the drill). It fails only if Docker ends in any state but `active`.
- **The Caddy line is two checks.** A fresh ACME order means the cert store on `/data/caddy` did not
  survive. A renewal failure with no later success means Caddy cannot renew (#285). A routine
  renewal (`renewing certificate`) passes; one is due within 30 days of expiry, so a resume after
  a long park may legitimately renew.

### Expected noise, not failures

- `WARN cloud-init: done with recoverable errors` — Azure's own IMDS reprovisioning, unrelated to
  this repo (#236). Seen on some resumes, not others.
- `homelab-data-guard: WARN ... IMDS reports '' at LUN 10` — IMDS lags a just-attached disk. A name
  is reassignable, so the guard does not trust it and does not fail on it (ADR-0009 §3).
- The VM's kernel boot time (`uptime -s`) is earlier than the workflow that created it, by 4 to 55
  minutes. Azure appears to boot images ahead of allocation. Use workflow timestamps for durations.
- Red plan checks on open Dependabot PRs while parked: they read empty Dependabot secrets
  (#138), unrelated to the lab's state.

### After a resume: check it

The IP and the SSH host keys both change on every cycle, so `known_hosts` breaks on both axes:

```bash
ssh-keygen -R <old-ip>
ssh-keygen -R homelab-edge.az.snehasish-chakraborty.com

# Fetch the new host key's fingerprint from the VM's serial console and compare before trusting
# it. The boot log comes back as one JSON string with its newlines escaped, so grep cannot see
# lines in it; decode it first.
az vm boot-diagnostics get-boot-log -g homelab-rg -n homelab-edge \
  | python3 -c 'import json,sys,re; print("\n".join(re.findall(r"SHA256:[A-Za-z0-9+/]+(?=[^\n]*\(ED25519\))", json.load(sys.stdin))))'
ssh-keyscan -t ed25519 homelab-edge.az.snehasish-chakraborty.com 2>/dev/null | ssh-keygen -lf -
```

Trust the key only if the two fingerprints match. Your NSG SSH allow rule is keyed to *your* IP,
not the VM's, so it needs no change.

Then the data, as the drill did:

- A file you checksummed before the park has the same checksum.
- `docker inspect caddy` shows `RestartCount=0` and its `Caddyfile` mount under `/data/apps/caddy`.
- The served certificate's serial is unchanged (unless a renewal was due) and its only SAN is
  `DNS:*.az.snehasish-chakraborty.com` (R6):

```bash
openssl s_client -connect test.az.snehasish-chakraborty.com:443 -servername test.az.snehasish-chakraborty.com </dev/null 2>/dev/null \
  | openssl x509 -noout -serial -startdate -enddate -ext subjectAltName
```

### If resume fails

- **Docker never starts, or `persist:` is FATAL:** the disk is missing or failed its guard. That is
  the guard working; [`data_guard.md`](data_guard.md) has every FATAL line and its recovery.
  Never bypass it to "get the lab up".
- **A container is FATAL:** `docker logs <name>` on the node. A bind source outside `/data` is the
  known cause — an app must live at `/data/apps/<app>` (#101).
- **The disk itself is lost or corrupt:** that is a restore from blob, not a resume. That path is
  [#206](https://github.com/114snehasish/homelab/issues/206), **and it has not been drilled yet**, so
  this runbook deliberately does not describe it. [`restic_backup.md`](restic_backup.md) covers
  reading the repository from a laptop.

## The backup tier while parked (R22)

Nothing reconciles `homelabpersistbackupsa`'s protective settings continuously: `infra/backup` has
no CI. A park is a good moment to assert them:

```bash
az storage account blob-service-properties show --account-name homelabpersistbackupsa -g homelab-persist-rg \
  --query "{versioning:isVersioningEnabled, blobSoftDeleteDays:deleteRetentionPolicy.days, containerSoftDeleteDays:containerDeleteRetentionPolicy.days}"
az storage account show -n homelabpersistbackupsa -g homelab-persist-rg --query "{sharedKey:allowSharedKeyAccess, tier:accessTier}"
```

Expect versioning `true`, both retentions `30`, `sharedKey` `false`, tier `Hot`. All held at every
check in the drill.

Park's final snapshots are tagged `final`, and since #288 retention groups by tag, so a later
nightly no longer forgets them. From a laptop: `restic snapshots --tag final`.

## Measured numbers

### Parked cost

From Azure Cost Analysis, **actual billed cost**, averaged over **31 consecutive fully parked days,
2026-10-09 to 2026-11-08**. The daily rate is measured; the monthly column is that rate × 30.

| Line | ₹/day | ₹/mo (×30) | ADR-0009 §8 computed |
|---|---|---|---|
| Data disk `homelab-data-disk` (20 GiB StandardSSD, billed at the 32 GiB tier) | 7.48 | 224.38 | 204 |
| DNS zone `az.snehasish-chakraborty.com` | 1.55 | 46.35 | 43 |
| `homelabpersistbackupsa` (all meters, storage and transactions) | 0.15 | 4.35 | 30 |
| #98 rollback snapshot (deleted 2026-11-10) | 0.08 | 2.27 | not counted |
| `listeninfratfstatesa` (Terraform state) | 0.00 | 0.03 | 0 |
| **Total** | **9.25** | **277.38** | **277** |

Today's parked set, without the snapshot, is **≈ ₹275/mo: inside the ≤ ₹400 target with ≈ ₹125
headroom.** ADR-0009 §8's amendment explains why the total matches the computed one while the lines
do not.

Two things void this number, and both are owned elsewhere:

- **R19:** a NAT Gateway (#164) left up after park costs more than this whole table. Once Phase 2
  lands, a park is only comparable with this one if the same run verifies the gateway is gone.
- **Fleet size:** the disk is per node. Ten nodes, each with a disk, park at ≈ ₹2,040/mo in disks
  alone (ADR-0009 §5, 2026-11-10 amendment; #165 decides which nodes get one).

### Durations

| | Drill | Rehearsal |
|---|---|---|
| Park, dispatch → verified | 5 m 02 s | 5 m 16 s |
| Resume, dispatch → verified | 4 m 22 s (after ~24 h parked) | 3 m 57 s |

## What the drill proved, and what it did not

**Proved:** the disk survived a park and a day parked, byte for byte; Caddy's certificate store
survived, so no ACME order was placed; the graceful stop leaves `/data` clean; Docker brings Caddy
back with no manual step; the final backup gates the destroy; the parked set and its cost are what
the ADR said they would be, to within a rupee.

**Not proved:**

- **That the backups restore.** This drill proves Tier 1 persisted; it never read a byte back from
  Tier 2 into a working lab. That is #206.
- **The first nightly under `--group-by host,paths,tags`** had not run when this was written.
- **More than one node.** Park is fleet-wide but the fleet is one node; #168 drills the fleet.

## The drill record (2026-11-10/11)

| Step | When (UTC) | Evidence |
|---|---|---|
| Rehearsal park, to deploy #288's fixes | 2026-11-10 04:50:35 → 04:55:51 | run 42758382469, final snapshot `a0211ca8…` |
| Rehearsal resume | 04:56:57 → 05:00:53 | run 42759016996, node-health 0 fatal, `docker: active (waited 5s)` |
| Marker planted on `/data` | 05:02:31 | 116 bytes, sha256 `7592d3cf…330751d` |
| Drill park | 05:03:46 → 05:08:48 | run 42759721120, final snapshot `2f8fe0e1…`; powerOff 05:06:00, deallocate 05:06:32, detach 05:07:41, delete 05:07:43 |
| Parked | ~24 h | parked set as above; R22 settings held |
| Drill resume | 2026-11-11 05:24:43 → 05:29:05 | run 42965586037, node-health 0 fatal |
| Verified | 05:30:37 | marker and stored-certificate checksums identical; cert serial unchanged; 0 ACME log lines; e2fsck `clean`; `RestartCount=0` |

**This is the habit, not a one-off.** E11.3 ([#78](https://github.com/114snehasish/homelab/issues/78))'s
monthly automated drill should evolve from this manual one: the same marker-checksum, certificate
and journal-replay checks, run on a schedule, with the parked-cost read moved to its own job once
Cost Analysis has caught up.
