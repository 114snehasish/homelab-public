# Runbook: the data-guard (mount contract v2)

What keeps Docker off a `/data` that is not the real disk, how to read it when it says no, and how
to recover. Design and rationale: [ADR-0009 §3](../adr/0009-tiered-persistence-park-resume.md#3-the-marker-file-is-an-identity-record-not-a-presence-check)
and its #99 amendment. Source: `compute/vm/persist/`, assembled into `custom_data` by
`compute/vm/cloud-init.tf` ([#99](https://github.com/114snehasish/homelab/issues/99)).

## The chain

Every boot, for each (LUN → mount) entry — today exactly one, LUN 10 → `/data`:

| Unit | Does | Fails when |
|---|---|---|
| `homelab-persist-prepare@10.service` | Waits up to 300 s for `/dev/disk/azure/scsi1/lun10`; runs `e2fsck -p` on an existing ext4; formats a disk **only** if it carries no signature at all | no disk; partition 1 is not ext4; signatures but no partition 1; the filesystem needs a human `fsck` |
| `data.mount` | Mounts `lun10-part1` on `/data` | prepare failed |
| `homelab-data-guard@data.service` | Compares `/data/.homelab-persist` with Azure IMDS and `blkid`; blesses a disk prepare formatted *this boot* | see the FATAL table below |
| `homelab-persist.target` | Active only when every guard passed | anything above failed |
| `containerd.service`, `docker.service` | Start only after the target (drop-ins); roots at `/data/containerd` and `/data/docker` | the target failed |

A failure anywhere leaves the node **up and reachable over SSH** with containerd and Docker
stopped. It never drops the boot into emergency mode.

## Status: the first three commands

```bash
systemctl is-active homelab-persist.target     # "active" = safe; anything else = Docker is held down
journalctl -b -u 'homelab-persist-prepare@*' -u 'homelab-data-guard@*' --no-pager
systemctl list-dependencies homelab-persist.target
```

Without SSH, the same lines reach the serial log — the units also log to the console:

```bash
az vm boot-diagnostics get-boot-log -g homelab-rg -n homelab-edge | grep -E 'homelab-(persist-prepare|data-guard)'
```

On a held-down node `docker ps` prints `Cannot connect to the Docker daemon…` and
`systemctl status docker` shows `Dependency failed` — both expected. **Never start `dockerd` or
`containerd` by hand** to get past it: that is the write-to-the-OS-disk failure this exists to prevent.

## FATAL line → cause → recovery

| The line says | Cause | Recovery |
|---|---|---|
| `no data disk at /dev/disk/azure/scsi1/lunN after 300s` | The disk is not attached, or is attached at another LUN | `az vm show -g homelab-rg -n <vm> --query storageProfile.dataDisks`. Re-run `deploy-compute.yml` (the attachment is its own resource), then reboot. |
| `partition 1 (…) holds '…', not ext4` | A foreign disk, or an interrupted first format (GPT, no filesystem) | **Stop and look** first: `sudo wipefs -n /dev/disk/azure/scsi1/lunN /dev/disk/azure/scsi1/lunN-part1`. Only if the disk is certain to hold nothing, `sudo wipefs -a` the partition and then the disk, and reboot — prepare formats it fresh. |
| `has no partition 1 but carries existing signatures` | A filesystem or partition table written straight onto the device | As above. Never automatic. |
| `e2fsck -p … exited N` | Filesystem errors that preen mode will not fix | Snapshot the disk first (`az snapshot create --incremental true …`), then `sudo e2fsck -f /dev/disk/azure/scsi1/lunN-part1` interactively, then reboot. |
| `no marker at /data/.homelab-persist` | This lab never blessed the disk: a restore onto a fresh filesystem, or a disk from elsewhere | Re-bless **only** if it is a restore you performed — see below. |
| `marker fs_uuid=… but the mounted filesystem is …` | A restored or copied marker ([#206](https://github.com/114snehasish/homelab/issues/206)), or the wrong disk | Establish that the data is the right data (`ls /data`), then re-bless. |
| `marker instance=… but IMDS says this node is …` | The right disk on the wrong node, or a node rename | A rename: re-bless. Anything else: detach the disk and find out why it is here. |
| `Azure IMDS unreachable after 12 attempts` | A platform or network fault at boot | Check `curl -s -H Metadata:true 'http://169.254.169.254/metadata/instance?api-version=2021-02-01'`; once it answers, `sudo systemctl restart homelab-persist.target`. |
| `marker schema is '…'` | A marker from a newer contract | Update the contract. Never hand-edit a marker. |

`WARN` lines (`disk_name`, `mount`) do not hold Docker down. They say a name changed since the
marker was written; a re-bless at the next deliberate change clears them.

## Re-bless

The escape hatch for exactly two deliberate cases (ADR-0009 §3): a **restore** onto a fresh
filesystem, and a **node rename**. It rewrites the marker from live IMDS and `blkid` values:

```bash
sudo /usr/local/sbin/write-persist-marker.sh --mount /data --created-by restore --force
sudo systemctl restart homelab-persist.target
systemctl is-active homelab-persist.target containerd docker
```

Never re-bless just to make an error go away on a disk whose origin you have not established —
stopping exactly that is the guard's whole job.

## Things that look wrong but are not

- **Docker starts later on a resume than on a reboot.** The disk attachment is created after the VM
  boots, so prepare logs `waiting up to 300s` and carries on when the disk lands.
- **Containers survive a VM recreate.** containerd and Docker keep their roots on `/data`, so
  `restart: unless-stopped` containers come back by themselves. The flip side: **park must leave
  containers running** — one stopped before park stays stopped after resume.
- **An app whose bind-mount source lives on the OS disk does not come back cleanly** — Caddy's
  `./Caddyfile` sits in `/home/azureuser/apps`. Redeploy it per `apps/README.md` after a recreate,
  until [#40](https://github.com/114snehasish/homelab/issues/40) / [#101](https://github.com/114snehasish/homelab/issues/101)
  move the apps layer.
- **Restarting any unit in the chain restarts the units above it**, Docker included. That is
  `Requires=` working as written; inspect with `systemctl status`, not `restart`.
