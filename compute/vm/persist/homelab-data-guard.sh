#!/usr/bin/env bash
#
# homelab-data-guard — prove a mounted data disk is the one this lab blessed
# (#99, ADR-0009 §3)
#
# Runs as homelab-data-guard@<escaped mount>.service once that disk is mounted.
# homelab-persist.target requires every guard, and docker.service and
# containerd.service require the target — so a FATAL here is what stops Docker
# from ever writing to a /data that is not the real disk.
#
# The marker (<mount>/.homelab-persist) is written only by
# write-persist-marker.sh, and is compared field by field with the live machine:
#
#   marker absent      FATAL  unless prepare formatted THIS filesystem THIS boot -> bless it
#                             (after waiting up to 120s for IMDS to list the disk)
#   schema != 1        FATAL  a marker this guard does not understand
#   fs_uuid            FATAL  the strongest signal; a filesystem UUID is not reassigned by mistake
#   instance           FATAL  the right disk on the wrong node (vs IMDS compute/name)
#   disk_name          WARN   names are reassignable (a restore under a new name)
#   mount              WARN   reassignable by configuration
#   IMDS unreachable   FATAL  after ~60s of retries; an identity that cannot be checked is not trusted
#
# The marker is PARSED, never sourced: it lives on the data disk and is read as
# root at boot, so executing it would hand root to anyone able to write /data.
#
# Usage (normally via systemd):  homelab-data-guard <mountpoint>

set -euo pipefail

TAG="homelab-data-guard"
MOUNT="${1:-}"
WRITER="/usr/local/sbin/write-persist-marker.sh"
IMDS_URL="http://169.254.169.254/metadata/instance?api-version=2021-02-01"

fatal() {
  printf '%s: FATAL %s: %s\n' "$TAG" "${MOUNT:-?}" "$*"
  exit 1
}
warn() { printf '%s: WARN %s: %s\n' "$TAG" "$MOUNT" "$*"; }

[[ "$MOUNT" == /* ]] || fatal "usage: ${TAG} <absolute mountpoint>."
[[ "$(id -u)" -eq 0 ]] || fatal "must run as root."
MARKER="${MOUNT%/}/.homelab-persist"

mountpoint -q "$MOUNT" || fatal "not a mountpoint. Refusing to vouch for the OS disk underneath it."

# --- The filesystem actually mounted here --------------------------------------
DEVICE="$(findmnt -n -o SOURCE --mountpoint "$MOUNT")"
LIVE_UUID="$(blkid -p -s UUID -o value "$DEVICE" 2>/dev/null || true)"
[[ -n "$LIVE_UUID" ]] || fatal "could not read a filesystem UUID from ${DEVICE}."

# Device -> LUN, resolved the way write-persist-marker.sh resolves it (keep the
# two in step): the scsi1/lunN links point at whole disks, so match the parent.
PARENT="/dev/$(lsblk -no PKNAME "$DEVICE" 2>/dev/null || true)"
[[ -b "$PARENT" ]] || PARENT="$DEVICE"
LUN=""
for link in /dev/disk/azure/scsi1/lun*; do
  [[ -e "$link" && "$link" != *-part* ]] || continue
  if [[ "$(readlink -f "$link")" == "$PARENT" ]]; then
    LUN="${link##*/lun}"
    break
  fi
done
[[ -n "$LUN" ]] || fatal "could not map ${DEVICE} back to an Azure data-disk LUN."

# --- The platform's answer: IMDS, never the hostname ---------------------------
read_imds() { # sets LIVE_INSTANCE and LIVE_DISK_NAME ("" while IMDS lists no disk at $LUN)
  local attempt imds=""
  for ((attempt = 1; attempt <= 12; attempt++)); do
    imds="$(curl -fsS -m 5 -H 'Metadata: true' "$IMDS_URL" 2>/dev/null)" && break
    imds=""
    sleep 5
  done
  [[ -n "$imds" ]] || fatal "Azure IMDS unreachable after 12 attempts (~60s): this disk's identity cannot be checked."

  LIVE_INSTANCE="$(printf '%s' "$imds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["compute"]["name"])')" ||
    fatal "IMDS returned no compute/name."
  LIVE_DISK_NAME="$(printf '%s' "$imds" | LUN="$LUN" python3 -c '
import json, os, sys
lun = int(os.environ["LUN"])
disks = json.load(sys.stdin)["compute"]["storageProfile"]["dataDisks"]
print(next((d["name"] for d in disks if int(d["lun"]) == lun), ""))
')" || fatal "IMDS returned no storageProfile/dataDisks."
}
read_imds

# --- A disk with no marker -------------------------------------------------------
if [[ ! -e "$MARKER" ]]; then
  FLAG="/run/homelab-persist/lun${LUN}.formatted"
  if [[ -f "$FLAG" && "$(<"$FLAG")" == "$LIVE_UUID" ]]; then
    # IMDS lags a fresh attach: storageProfile/dataDisks left a just-attached
    # disk out for up to a minute on the #99 test VM, and the writer refuses to
    # bless a LUN that IMDS does not list. Only this path waits. On the verify
    # path a missing name is a disk_name WARN at worst.
    IMDS_DISK_WAIT="${HOMELAB_GUARD_IMDS_DISK_WAIT_SECONDS:-120}"
    deadline=$((SECONDS + IMDS_DISK_WAIT))
    if [[ -z "$LIVE_DISK_NAME" ]]; then
      printf '%s: %s: IMDS lists no data disk at LUN %s yet; waiting up to %ss before blessing\n' \
        "$TAG" "$MOUNT" "$LUN" "$IMDS_DISK_WAIT"
    fi
    while [[ -z "$LIVE_DISK_NAME" ]] && ((SECONDS < deadline)); do
      sleep 5
      read_imds
    done
    [[ -n "$LIVE_DISK_NAME" ]] ||
      fatal "IMDS still lists no data disk at LUN ${LUN} after ${IMDS_DISK_WAIT}s, so freshly formatted filesystem ${LIVE_UUID} is not blessed yet. This boot can still bless it: once IMDS lists the disk, sudo systemctl start docker.service (docs/runbooks/data_guard.md)."
    "$WRITER" --mount "$MOUNT" --created-by cloud-init ||
      fatal "could not bless freshly formatted filesystem ${LIVE_UUID}: ${WRITER} failed."
    rm -f "$FLAG"
    printf '%s: OK %s: blessed freshly formatted filesystem %s at LUN %s (created_by=cloud-init)\n' \
      "$TAG" "$MOUNT" "$LIVE_UUID" "$LUN"
  else
    fatal "no marker at ${MARKER} (filesystem ${LIVE_UUID}, LUN ${LUN}): this lab never blessed this disk. Only if it is a restore or a deliberate re-bless: sudo ${WRITER} --mount ${MOUNT} --created-by restore --force (docs/runbooks/data_guard.md)."
  fi
fi

# --- Compare the marker with the live machine -----------------------------------
declare -A marker=()
while IFS='=' read -r key value || [[ -n "$key" ]]; do
  [[ -z "$key" ]] && continue
  [[ "$key" =~ ^[a-z_]+$ ]] || fatal "malformed line in ${MARKER}: '${key}'."
  marker["$key"]="$value"
done <"$MARKER"

[[ "${marker[schema]:-}" == "1" ]] ||
  fatal "marker schema is '${marker[schema]:-missing}'; this guard understands schema 1 only."
[[ "${marker[fs_uuid]:-}" == "$LIVE_UUID" ]] ||
  fatal "marker fs_uuid=${marker[fs_uuid]:-missing} but the mounted filesystem is ${LIVE_UUID}. A restored or copied marker looks like this; re-bless only if that is what happened (docs/runbooks/data_guard.md)."
[[ "${marker[instance]:-}" == "$LIVE_INSTANCE" ]] ||
  fatal "marker instance=${marker[instance]:-missing} but IMDS says this node is ${LIVE_INSTANCE}: the right disk on the wrong node."
[[ "${marker[disk_name]:-}" == "$LIVE_DISK_NAME" ]] ||
  warn "marker disk_name=${marker[disk_name]:-missing} but IMDS reports '${LIVE_DISK_NAME}' at LUN ${LUN}. A name is reassignable, so this is not fatal."
[[ "${marker[mount]:-}" == "$MOUNT" ]] ||
  warn "marker mount=${marker[mount]:-missing} but the disk is mounted at ${MOUNT}. Not fatal."

printf '%s: OK %s: %s at LUN %s, filesystem %s, node %s (marker created %s by %s)\n' \
  "$TAG" "$MOUNT" "${LIVE_DISK_NAME:-?}" "$LUN" "$LIVE_UUID" "$LIVE_INSTANCE" \
  "${marker[created]:-?}" "${marker[created_by]:-?}"
