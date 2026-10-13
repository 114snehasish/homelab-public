#!/usr/bin/env bash
#
# park-backup.sh — the "no backup, no park" step (#101, ADR-0009 §5)
#
# Executed ON A NODE, as root, through Azure managed Run Command by
# .github/workflows/_park.yml. It is NOT part of custom_data: editing this file
# never replaces a VM and never touches the 65,535-byte budget cloud-init.tf
# guards. The workflow ships it to the node on every run.
#
# Contract with _park.yml:
#   - exit 0 and the LAST stdout line is `snapshot_id=<64 hex chars>`  -> park may proceed
#   - anything else                                                    -> park aborts before any stop or destroy
# Everything except that one line goes to stderr, for the same reason
# restic-backup keeps its own stdout to the id alone.
#
# What it does, in order:
#   1. Refuses unless homelab-persist.target is active. A backup of a /data that
#      is not the blessed disk is worse than none (the reason #99 blocked #100).
#   2. Refuses on a node with no backup contract. Restic ships only to the
#      public-edge node today (#100); making it fleet-wide is #166. Failing here
#      is what stops park from destroying a node whose disk was never backed up.
#   3. Waits for an in-flight nightly to finish rather than colliding with its
#      `forget --prune` lock. It NEVER stops the timer: if this park aborts, the
#      node keeps running and still needs tonight's backup.
#   4. Runs `restic-backup final` (pre-hooks, backup, no prune) and re-reads the
#      snapshot from the repository, so "verified" means "restic can read it
#      back", not "a process printed an id".

set -euo pipefail

TAG="park-backup"
BACKUP_BIN="/usr/local/sbin/restic-backup"
ENV_FILE="/etc/homelab/restic.env"
NIGHTLY_UNIT="homelab-restic-backup.service"
NIGHTLY_WAIT_SECONDS=2700

say() { printf '%s: %s\n' "$TAG" "$*" >&2; }
fatal() {
  printf '%s: FATAL: %s\n' "$TAG" "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || fatal "must run as root (Run Command runs as root; a manual run needs sudo)."

systemctl is-active --quiet homelab-persist.target ||
  fatal "homelab-persist.target is not active on $(hostname): /data is missing or failed its data-guard. No backup is possible, so park must not proceed — see docs/runbooks/data_guard.md, or dispatch park.yml with skip_backup if this node is beyond saving."

[[ -x "$BACKUP_BIN" && -r "$ENV_FILE" ]] ||
  fatal "$(hostname) has no backup contract (${BACKUP_BIN} / ${ENV_FILE}). Restic ships only to the public-edge node until #166 makes it fleet-wide; refusing so this node is never destroyed unbacked."

waited=0
while [[ "$(systemctl is-active "$NIGHTLY_UNIT" || true)" == "activating" ]]; do
  ((waited >= NIGHTLY_WAIT_SECONDS)) && fatal "the nightly backup has been running for over ${NIGHTLY_WAIT_SECONDS}s; refusing to race it."
  ((waited % 60 == 0)) && say "a nightly backup is in flight; waiting for it (${waited}s so far)"
  sleep 15
  waited=$((waited + 15))
done

say "taking the final snapshot on $(hostname)"
snapshot_id="$("$BACKUP_BIN" final)"

[[ "$snapshot_id" =~ ^[0-9a-f]{64}$ ]] ||
  fatal "restic-backup final printed '${snapshot_id}', which is not a snapshot id."

# Read it back with the same environment the wrappers use. Sourced, not
# exported system-wide — see restic-backup's note on AZURE_CLIENT_ID.
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a
restic cat snapshot "$snapshot_id" >/dev/null ||
  fatal "snapshot ${snapshot_id} was reported but cannot be read back from ${RESTIC_REPOSITORY}."

say "snapshot ${snapshot_id} verified in ${RESTIC_REPOSITORY}"
printf 'snapshot_id=%s\n' "$snapshot_id"
