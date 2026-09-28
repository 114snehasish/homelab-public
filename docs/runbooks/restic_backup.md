# Runbook: the restic backup service (Tier 2)

What backs `/data` up, how to read it when it fails, how to restore — including from a laptop with
no VM at all — and where the repository password lives. Design and rationale:
[ADR-0009 §6](../adr/0009-tiered-persistence-park-resume.md#6-tier-2-mechanics) and its
[2026-09-28 amendment](../adr/0009-tiered-persistence-park-resume.md#amendment-2026-09-28-100--the-dedicated-backup-account-returns-in-the-persist-rg).
Source: `compute/vm/backup/`, assembled into `custom_data` by `compute/vm/cloud-init.tf`
([#100](https://github.com/114snehasish/homelab/issues/100)).

This is the **logical** backup tier. It is not the disk itself — losing the VM loses nothing, because
the disk survives (RPO 0). This tier exists for the case where the *disk* is lost, corrupted or
wrongly formatted, where RPO is the last nightly snapshot.

## The shape of it

| Thing | Where |
|---|---|
| Repository | `azure:restic:/` in storage account `homelabpersistbackupsa`, container `restic` |
| Account | RG `homelab-persist-rg`, `southindia` — co-regional with the disk and the VM |
| Credential | **none on the VM.** The UAMI `homelab-backup-identity`, `Storage Blob Data Contributor` on that container only |
| Repository password | `/data/.restic-password`, root-owned `0600`. Copies: password manager, and the `secret-files` container of `listeninfratfstatesa` |
| Config | `/etc/homelab/restic.env`, rendered per node by Terraform. Identifiers only |
| Entrypoint | `/usr/local/sbin/restic-backup [init\|nightly\|final]` |
| Timers | `homelab-restic-backup.timer` (nightly 02:30 UTC), `homelab-restic-check.timer` (Sun 04:00 UTC) |

**There is no alerting.** Scope item 4 of #100 specified a Telegram ping on failure and it was
deferred whole to E08 ([#65](https://github.com/114snehasish/homelab/issues/65)). Today a failed run
is a failed systemd unit and nothing else — so `systemctl --failed` is the check, and it is on you to
run it. This is a known, recorded gap, not an oversight.

## Status: the first three commands

```bash
systemctl list-timers 'homelab-restic-*'          # both armed, and when they last ran
systemctl --failed                                 # the only failure signal that exists today
journalctl -u homelab-restic-backup.service -n 50 --no-pager
```

Then the repository itself:

```bash
sudo restic snapshots            # nightly history; `restic` reads /etc/homelab/restic.env? No — see below
```

`restic` invoked bare does **not** pick up the environment: the config is sourced by the wrapper
scripts, not exported system-wide (deliberately — see *Why `AZURE_CLIENT_ID` is not global*). For
ad-hoc restic commands on the VM:

```bash
sudo bash -c 'set -a; . /etc/homelab/restic.env; set +a; restic snapshots'
```

## The chain, and what gates it

```
homelab-persist.target  (from #99: disk prepared, mounted, data-guard passed)
        │ Requires= + After=
        ▼
homelab-restic-backup.service  ──ExecStart──▶  /usr/local/sbin/restic-backup nightly
        ▲
homelab-restic-backup.timer    (OnCalendar=*-*-* 02:30:00, Persistent=true)
```

**The gate is the whole point, and it is why #99 blocked #100.** With `homelab-persist.target` down —
no disk, a disk that failed its marker check, a half-mounted `/data` — the backup unit does not run
at all and ends in `Dependency failed`. A clean-looking snapshot of the wrong filesystem is worse than
no snapshot, because it is a backup you would trust. `ConditionPathIsMountPoint=/data` is a second
check behind that one; the script re-checks the mount and the `.homelab-persist` marker again, because
it is also invoked by hand.

`homelab-restic-check.service` deliberately does **not** require the target: it reads the repository in
blob storage and never touches `/data`. It is the one part of this service that still works while the
data disk is unavailable — which is exactly when you want to know whether the backups are readable.

## First run on a new VM

Cloud-init installs restic and enables both timers, but it cannot create the repository or place the
password. Two manual steps, once per *repository* — not once per VM, because both live on the pet
disk or in blob and survive a park.

```bash
# 1. The password. Generate it ONCE, ever. Regenerating it orphans every existing snapshot.
#    On your laptop:
openssl rand -base64 48 > restic-password
scp restic-password azureuser@<public_ip>:/tmp/restic-password
ssh azureuser@<public_ip> 'sudo install -m 0600 -o root -g root /tmp/restic-password /data/.restic-password && rm -f /tmp/restic-password'

#    Then put the two copies somewhere that is not the disk it protects (R13):
az storage blob upload --account-name listeninfratfstatesa --container-name secret-files \
  --name restic-password --file restic-password --auth-mode login
#    ...and into the password manager. Then delete the local file.
rm -f restic-password

# 2. The repository.
ssh azureuser@<public_ip> 'sudo /usr/local/sbin/restic-backup init'
```

`init` is a separate mode on purpose. An "initialise if missing" branch inside the backup path would
hide the one failure that matters most — a misconfigured repository URL — by silently creating a
second, empty repository and reporting success every night.

**The password copies are deliberately in a different storage account from the repository.**
`secret-files` lives in `listeninfratfstatesa`; the repository lives in `homelabpersistbackupsa`. One
account compromise therefore never yields both the ciphertext and the key that opens it. Interim
until Key Vault ([#49](https://github.com/114snehasish/homelab/issues/49) /
[#50](https://github.com/114snehasish/homelab/issues/50)); a GitHub Actions copy arrives with apps CI
([#40](https://github.com/114snehasish/homelab/issues/40)).

## FATAL line → cause → recovery

| The line says | Cause | Recovery |
|---|---|---|
| `Dependency failed for ...restic-backup` | `homelab-persist.target` is down — the disk is missing or failed its guard | This is the gate working. Fix the disk first: [`data_guard.md`](data_guard.md). Never bypass it to "get a backup" |
| `/data is not a mountpoint` | Invoked by hand while the disk is unmounted | As above |
| `no repository password at /data/.restic-password` | Fresh disk, or the file was lost | Restore it from the password manager or `secret-files` (above). **Do not generate a new one** — it would orphan every snapshot |
| `no repository at azure:restic:/` | Never initialised, or `RESTIC_REPOSITORY` is wrong | `sudo /usr/local/sbin/restic-backup init`, but first confirm the URL — if a repository does exist, creating a second one is the failure this message prevents |
| `Fatal: unable to open config file ... AuthorizationPermissionMismatch` | The identity has no data-plane role, or the wrong identity was selected | `az role assignment list --assignee <backup principal> --all` should show exactly one row, scoped to `/containers/restic`. Then check `AZURE_CLIENT_ID` in `/etc/homelab/restic.env` matches `terraform -chdir=infra/identity output -raw backup_client_id` |
| `ManagedIdentityCredential ... multiple user-assigned identities` | `AZURE_CLIENT_ID` is unset or empty | The VM carries two UAMIs. Both consumers must pin their own — see below |
| `repository is already locked` | A previous run was killed (park timeout, OOM, reboot) | The script runs `restic unlock` every time, which clears **stale** locks automatically. If it persists, a run is genuinely still going: `ps aux \| grep restic` |
| `pre-hook ... failed` | An app's consistency hook returned non-zero | The run aborted deliberately rather than take an inconsistent snapshot. Fix the hook; `/etc/homelab/backup-pre.d/README` has the contract |
| `restic backup reported no summary snapshot_id` | The backup did not complete | Treat as failed. The exit status is non-zero, so #101's park will abort before destroying anything |

## Why `AZURE_CLIENT_ID` is not global

The edge VM carries **two** user-assigned managed identities since #100:
`homelab-edge-dns-identity` (Caddy's DNS-01, ADR-0013) and `homelab-backup-identity` (this service).
With two attached, an unpinned managed-identity token request is ambiguous, so each consumer pins its
own client id in its own environment:

- Caddy → `AZURE_CLIENT_ID` in `apps/caddy/.env`, the **edge DNS** identity
- restic → `AZURE_CLIENT_ID` in `/etc/homelab/restic.env`, the **backup** identity

Exporting either one system-wide would leak it into the other's process and select the wrong
identity — the same bug with the arrow reversed. That is why the wrapper scripts source their file
rather than the unit declaring an `EnvironmentFile`, and why nothing writes these into `/etc/profile`.

The Caddy failure mode is the nastier of the two: nothing breaks at deploy time, and it surfaces weeks
later as a certificate that did not renew.

## Restore

### A single file, on the VM

```bash
sudo bash -c 'set -a; . /etc/homelab/restic.env; set +a; \
  restic restore latest --target /tmp/restore --include /data/caddy/data'
```

### From a laptop, with no VM at all

This is the path that actually matters, and the one
[#206](https://github.com/114snehasish/homelab/issues/206) drills. Two prerequisites, both easy to
get wrong:

**1. You need a blob data role. Subscription Owner is not enough.** Owner is a *control-plane* role
and confers no blob data access; the failure is `AuthorizationPermissionMismatch`, which names
neither the missing role nor the irrelevance of Owner. `infra/identity` grants
`Storage Blob Data Contributor` on the container to whoever applies it
(`var.grant_operator_blob_access`). A different operator needs their own grant first.

**2. There is no account key.** The account sets `shared_access_key_enabled = false`, so there is no
`AZURE_ACCOUNT_KEY` path and no fallback to one. If a SAS is ever needed it must be a
**user-delegation** SAS (Entra-signed) — an account SAS is signed with the key and cannot be minted.

```bash
az login
export AZURE_ACCOUNT_NAME=homelabpersistbackupsa
export RESTIC_REPOSITORY=azure:restic:/
export RESTIC_PASSWORD_FILE=./restic-password        # from the password manager or secret-files

restic snapshots
restic restore latest --target ./restore
```

After restoring onto a **fresh filesystem**, the data-guard will refuse the disk: the restored marker
carries the old `fs_uuid` while the new filesystem has a new one. That is the guard working as
designed. Re-bless it deliberately:

```bash
sudo /usr/local/sbin/write-persist-marker.sh --mount /data --created-by restore --force
```

## What is and is not backed up

Everything under `/data` except `/etc/homelab/restic-excludes`:

- **Excluded:** `/data/docker` and `/data/containerd` (image layers, re-pullable, enormous),
  `/data/.cache` (restic's own cache), `/data/.restic-password` (circular — it would be encrypted
  with itself), `/data/lost+found`.
- **Included, and deliberately so:** `/data/caddy` (certificates and the ACME account),
  `/data/<app>` state, and `/data/k8s-pv` ([#103](https://github.com/114snehasish/homelab/issues/103))
  — a k3s persistent volume is a directory on the pet disk and inherits this backup set by design.

The rule is *exclude what is reproducible or circular, never what is merely large.*

## Retention, and why prune runs nightly

`--keep-daily 7 --keep-weekly 4 --keep-monthly 6`, with `forget --prune` every night.

Nightly prune is only safe because the container is **Hot** (ADR-0009 §6b). On Cool, the 30-day
minimum retention would charge a prorated early-deletion penalty on nearly every pack a prune
deletes — the architecture review's "decouple prune to monthly" advice applies to that case and not
to this one.

`restic-backup final` — the entrypoint #101's park workflow calls — **skips the prune**. Park is
blocked on that run finishing, and a repack is minutes of work whose only benefit is storage cost, on
the one run where the thing being protected is about to be destroyed.

## Protection against the backup service itself (R22)

The VM holds write access to this container and runs `forget --prune` on a timer, so a compromised or
misbehaving VM can delete every backup it has, on schedule. The credential being used as designed *is*
the attack.

Shipped: **blob versioning on, blob and container soft delete at 30 days**, declared in
`infra/backup`. 30 days rather than the 7-day default because the lab is parked for weeks at a time
and a 7-day window would expire unobserved. Recover a deleted or overwritten blob with
`az storage blob undelete` or by listing versions (`--include v`).

Not shipped, and recorded as an open ADR item: the strong form — a custom data-plane role granting
blob read/write/add but **not** `.../blobs/delete`, with `forget --prune` moved off the VM into a
scheduled CI job holding its own identity. `Storage Blob Data Contributor` is the narrowest built-in
that lets restic write, and it can delete.

Version-level immutability was considered and **rejected with a reason**: a time-based retention lock
makes the locked versions undeletable, which makes `prune` impossible for the lock window —
incompatible with `--keep-daily 7`, not merely inconvenient.

## Upgrading restic

The version and its SHA256 are pinned in `compute/vm/cloud-init.yaml`. Nothing watches that pin —
`.github/dependabot.yml` has no ecosystem for it, the same as the Caddy image tags — so a bump is a
deliberate act. **It changes `custom_data`, which is ForceNew: the VM is replaced.** Treat it like any
other cloud-init change, and note that `custom_data` is a budgeted resource (49,621 of 65,535 bytes as
of 2026-09-28).

Do not switch to the distro package. Ubuntu 24.04 ships 0.16.x; managed-identity support landed in
0.17.0, so apt's restic cannot authenticate here at all and fails with an auth error that never
mentions the version.
