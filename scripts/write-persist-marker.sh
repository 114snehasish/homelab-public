#!/usr/bin/env bash
#
# write-persist-marker.sh — write /data/.homelab-persist (ADR-0009 §3)
#
# The marker is an IDENTITY RECORD, not a presence check: #99's data-guard
# compares its fields against the live machine (IMDS, blkid) and refuses to let
# Docker start when they disagree, so that a node can never silently write app
# state onto an OS disk that is about to be destroyed.
#
# This script exists because #99 writes the marker ON FIRST FORMAT ONLY, and the
# deployed disk is already formatted — so on the one disk the guard exists to
# protect, that write path never fires. E15.2 (#98) therefore writes it by hand,
# once, and this is that writer. It is deliberately a PURE WRITER: comparing the
# marker against live state is the guard's job (#99), not this file's.
#
# Three callers, distinguished only by --created-by:
#   migration-runbook  E15.2 (#98), this disk, once      (the default)
#   cloud-init         #99's format path, on a new disk
#   restore            #206's DR drill, after a restore onto a fresh filesystem
#
# The last two are RE-BLESS cases and need --force: a restored marker carries the
# OLD fs_uuid while the new filesystem has a new one, which is the guard working
# as designed. Rewriting it from live values is the documented escape hatch, and
# it is deliberately an explicit flag rather than silent overwrite behaviour.
#
# Runs ON THE VM, as root:
#   sudo ./write-persist-marker.sh [--mount /data] [--created-by <who>] [--force]

set -euo pipefail

MOUNT="/data"
CREATED_BY="migration-runbook"
FORCE=0

log() { printf '  %s\n' "$*"; }
fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount)      MOUNT="${2:?--mount needs a path}"; shift 2 ;;
    --created-by) CREATED_BY="${2:?--created-by needs a value}"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    usage 0 ;;
    *)            printf 'unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
  esac
done

case "$CREATED_BY" in
  cloud-init | migration-runbook | restore) ;;
  *) fail "--created-by must be one of: cloud-init, migration-runbook, restore (ADR-0009 §3)." ;;
esac

[[ "$(id -u)" -eq 0 ]] || fail "must run as root — the marker is root-owned 0644 on the data disk."
command -v blkid >/dev/null 2>&1 || fail "blkid is not on PATH."
command -v findmnt >/dev/null 2>&1 || fail "findmnt is not on PATH."

MARKER="${MOUNT%/}/.homelab-persist"

# A marker written onto the OS disk because the data disk never mounted is the
# exact failure #99 exists to catch; refusing here keeps this script from
# manufacturing the lie the guard is meant to detect.
mountpoint -q "$MOUNT" || fail "${MOUNT} is not a mountpoint. Refusing to write a marker onto the OS disk."

if [[ -e "$MARKER" && "$FORCE" -ne 1 ]]; then
  printf '\n%s already exists:\n\n' "$MARKER"
  sed 's/^/  /' "$MARKER"
  printf '\nRe-blessing an existing marker is a deliberate act (a restore onto a fresh\nfilesystem, or a node rename). Re-run with --force if that is what this is.\n\n'
  exit 1
fi

# --- fs_uuid: the strongest field, and the one the guard treats as fatal -----
# Read from the device actually mounted at $MOUNT rather than from any LUN path,
# so a marker can never describe a disk other than the one being written to.
DEVICE="$(findmnt -n -o SOURCE --target "$MOUNT")"
FS_UUID="$(blkid -s UUID -o value "$DEVICE")"
[[ -n "$FS_UUID" ]] || fail "could not read a filesystem UUID from ${DEVICE}."

# --- instance + disk_name: from Azure IMDS, never from hostname --------------
# hostname is editable by anyone on the box; IMDS is the platform's own answer.
IMDS_URL="http://169.254.169.254/metadata/instance?api-version=2021-02-01"
IMDS="$(curl -fsS -m 10 -H 'Metadata: true' "$IMDS_URL")" ||
  fail "could not reach Azure IMDS at 169.254.169.254."

INSTANCE="$(printf '%s' "$IMDS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["compute"]["name"])')"
[[ -n "$INSTANCE" ]] || fail "IMDS returned no compute/name."

# Resolve the mounted device back to its LUN, then ask IMDS what disk is at that
# LUN. Going device -> LUN -> name (rather than trusting a hardcoded LUN) is what
# keeps this correct when E17.6 puts a second disk on a node: /dev/disk/azure/
# scsi1/lunN symlinks point at whole devices, so compare against the partition's
# parent.
PARENT="/dev/$(lsblk -no PKNAME "$DEVICE" 2>/dev/null || true)"
[[ -b "$PARENT" ]] || PARENT="$DEVICE" # unpartitioned filesystem straight on the disk

LUN=""
for link in /dev/disk/azure/scsi1/lun*; do
  [[ -e "$link" ]] || continue
  if [[ "$(readlink -f "$link")" == "$PARENT" ]]; then
    LUN="${link##*/lun}"
    break
  fi
done
[[ -n "$LUN" ]] || fail "could not map ${PARENT} back to an Azure data-disk LUN."

DISK_NAME="$(printf '%s' "$IMDS" | LUN="$LUN" python3 -c '
import json, os, sys
lun = int(os.environ["LUN"])
disks = json.load(sys.stdin)["compute"]["storageProfile"]["dataDisks"]
print(next((d["name"] for d in disks if int(d["lun"]) == lun), ""))
')"
[[ -n "$DISK_NAME" ]] || fail "IMDS lists no data disk at LUN ${LUN}."

CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Atomic: a half-written marker is a marker the guard would reject, and it would
# reject it at boot, on the node, with docker held down.
TMP="$(mktemp "${MOUNT%/}/.homelab-persist.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
schema=1
instance=${INSTANCE}
disk_name=${DISK_NAME}
fs_uuid=${FS_UUID}
mount=${MOUNT}
created=${CREATED}
created_by=${CREATED_BY}
EOF
chown root:root "$TMP"
chmod 0644 "$TMP"
mv -f "$TMP" "$MARKER"
trap - EXIT

printf '\nWrote %s\n\n' "$MARKER"
sed 's/^/  /' "$MARKER"
printf '\n'
log "device : ${DEVICE} (LUN ${LUN}, parent ${PARENT})"
