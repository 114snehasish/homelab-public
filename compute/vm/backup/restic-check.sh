#!/usr/bin/env bash
#
# restic-check — weekly repository integrity check (#100, risk R13)
#
# Runs as homelab-restic-check.service on a weekly timer. R13 is "the repository
# is unreadable when it is finally needed", and the mitigation roadmap.md records
# is this: check weekly, so rot is caught early rather than during a restore.
#
# `restic check` alone verifies STRUCTURE — that every pack and index referenced
# by a snapshot exists and the metadata is consistent. It does not read the data.
# `--read-data-subset` actually downloads and verifies a slice of the pack files,
# which is the only thing that detects bit rot or a partially written pack. 5%
# weekly covers the repository roughly twice a year at random, at lab volumes, and
# costs nothing in egress now that the account is co-regional with the VM.
#
# Deliberately a separate unit from the backup: a failing check must not stop
# tonight's backup from being taken, and a failing backup must not hide a
# repository that has quietly rotted.
#
# Usage (normally via systemd):  restic-check

set -euo pipefail

TAG="restic-check"
ENV_FILE="/etc/homelab/restic.env"
READ_DATA_SUBSET="5%"

say() { printf '%s: %s\n' "$TAG" "$*"; }
fatal() {
  printf '%s: FATAL: %s\n' "$TAG" "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || fatal "must run as root — the password file is root-owned."
[[ -r "$ENV_FILE" ]] || fatal "${ENV_FILE} is missing or unreadable."

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

for v in AZURE_ACCOUNT_NAME AZURE_CLIENT_ID RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR; do
  [[ -n "${!v:-}" ]] || fatal "${v} is not set in ${ENV_FILE}."
done
[[ -r "$RESTIC_PASSWORD_FILE" ]] || fatal "no repository password at ${RESTIC_PASSWORD_FILE}."

install -d -m 0700 "$RESTIC_CACHE_DIR"

# Same reasoning as the backup path: a lock left by a killed run would otherwise
# fail every check from here on, silently.
restic unlock

say "checking ${RESTIC_REPOSITORY} (structure + ${READ_DATA_SUBSET} of pack data)"
restic check --read-data-subset "$READ_DATA_SUBSET"
say "repository is consistent"
