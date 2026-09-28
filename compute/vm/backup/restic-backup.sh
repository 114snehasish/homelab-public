#!/usr/bin/env bash
#
# restic-backup — the lab's only logical backup (#100, ADR-0009 §6, T2)
#
# Runs as homelab-restic-backup.service on a nightly timer, and on demand as
# `restic-backup final` — the entrypoint #101's park workflow calls and waits on
# before it destroys anything.
#
#   init      create the repository. Explicit, once, never automatic.
#   nightly   pre-hooks -> backup /data -> forget --prune          (the timer)
#   final     pre-hooks -> backup /data, and NO prune              (park)
#
# WHY `final` DOES NOT PRUNE. Park is blocked on this run finishing, and a prune
# repacks pack files — minutes of work whose only benefit is storage cost, on the
# one run where the thing being protected is about to be destroyed. The nightly
# timer prunes; park does not need to.
#
# THE INTEGRITY GUARANTEE, and the reason #99 blocked #100: the unit requires
# homelab-persist.target, so this never runs against a /data that is the OS disk
# or half-mounted. A clean-looking snapshot of the wrong filesystem is worse than
# no snapshot at all — it is a backup you would trust. This script re-checks the
# mount anyway, because it is also invoked by hand.
#
# THE CREDENTIAL. There is none on this machine. restic authenticates as the
# user-assigned managed identity homelab-backup-identity through the Azure SDK
# credential chain, which selects it from AZURE_CLIENT_ID in the environment file
# below. The account (homelabpersistbackupsa) has shared_access_key_enabled =
# false, so there is no account key to fall back to even by mistake. The only
# secret in play is the repository password, which is a file on the data disk.
#
# Usage (normally via systemd):  restic-backup [init|nightly|final]

set -euo pipefail

TAG="restic-backup"
MODE="${1:-nightly}"
ENV_FILE="/etc/homelab/restic.env"
HOOK_DIR="/etc/homelab/backup-pre.d"
EXCLUDE_FILE="/etc/homelab/restic-excludes"
SOURCE="/data"

# ADR-0009 §6b/§6c. Hot tier, so a nightly prune carries no early-deletion
# penalty and the two operations are not worth decoupling.
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

say() { printf '%s: %s\n' "$TAG" "$*" >&2; }
fatal() {
  printf '%s: FATAL: %s\n' "$TAG" "$*" >&2
  exit 1
}

case "$MODE" in
  init | nightly | final) ;;
  *) fatal "usage: ${TAG} [init|nightly|final] (got '${MODE}')." ;;
esac

[[ "$(id -u)" -eq 0 ]] || fatal "must run as root — /data and the password file are root-owned."

# --- Environment ---------------------------------------------------------------
# Sourced here rather than declared as the unit's EnvironmentFile, so that a
# manual `sudo restic-backup` behaves identically to the timer. A unit-only
# EnvironmentFile is the classic way to get a backup that works under systemd and
# mysteriously does not by hand, or the reverse.
[[ -r "$ENV_FILE" ]] || fatal "${ENV_FILE} is missing or unreadable. It is rendered into custom_data by compute/vm/cloud-init.tf; a VM without it was not built by this repo."
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

for v in AZURE_ACCOUNT_NAME AZURE_CLIENT_ID RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR; do
  [[ -n "${!v:-}" ]] || fatal "${v} is not set in ${ENV_FILE}."
done

# AZURE_CLIENT_ID pins WHICH managed identity to use, and it is load-bearing
# because the edge VM carries two (ADR-0013's Caddy DNS-01 identity and this
# one). With two attached, an unpinned request is ambiguous. Note it is exported
# only into this process: exported system-wide it would leak into Caddy's
# container and select the wrong identity there — the same bug, reversed.

# --- The disk ------------------------------------------------------------------
mountpoint -q "$SOURCE" ||
  fatal "${SOURCE} is not a mountpoint. Refusing to back up the OS disk — see docs/runbooks/data_guard.md."
[[ -e "${SOURCE}/.homelab-persist" ]] ||
  fatal "${SOURCE} carries no .homelab-persist marker, so this lab never blessed it. The data-guard should already have stopped this; refusing anyway."
[[ -r "$RESTIC_PASSWORD_FILE" ]] ||
  fatal "no repository password at ${RESTIC_PASSWORD_FILE}. Restore it from the password manager or the secret-files container — docs/runbooks/restic_backup.md."

# On /data on purpose (#207 owns its sizing): the OS disk is destroyed on every
# park, so a cache there is rebuilt from scratch on every resume, making the first
# post-resume backup slow and chatty against blob.
install -d -m 0700 "$RESTIC_CACHE_DIR"

say "mode=${MODE} repo=${RESTIC_REPOSITORY} account=${AZURE_ACCOUNT_NAME} cache=${RESTIC_CACHE_DIR}"

# --- init ----------------------------------------------------------------------
# Deliberately a separate mode rather than an "initialise if missing" branch in
# the backup path. An auto-init hides the one failure that matters most — a
# misconfigured repository path — by silently creating a second, empty repository
# and reporting success every night.
if [[ "$MODE" == "init" ]]; then
  if restic cat config >/dev/null 2>&1; then
    say "repository already initialised; nothing to do"
    exit 0
  fi
  restic init
  say "repository initialised at ${RESTIC_REPOSITORY}"
  exit 0
fi

restic cat config >/dev/null 2>&1 ||
  fatal "no repository at ${RESTIC_REPOSITORY}. Run '${TAG} init' once, deliberately, rather than letting a backup create one."

# --- Stale locks ---------------------------------------------------------------
# A backup killed mid-run (a park that timed out, an OOM, a reboot) leaves a lock
# behind, and every subsequent night would fail on it — the quiet version of "no
# backups". Plain `unlock` removes only locks whose process is gone and which are
# older than restic's staleness threshold; it never touches a live one, which is
# why it is safe to run unconditionally and why `--remove-all` is not used.
restic unlock

# --- Pre-hooks: application consistency ----------------------------------------
# A file-level copy of a live database is a crash-consistent copy, which for
# SQLite and Postgres means "probably fine, occasionally corrupt". Each app drops
# an executable script here that renders a consistent dump under /data (sqlite3
# .backup, pg_dump) BEFORE the snapshot is taken.
#
# A failing hook ABORTS the run. The alternative — snapshot anyway, minus one
# app's consistency — produces exactly the backup that looks fine until it is
# needed. Empty today: there are no stateful apps yet.
if [[ -d "$HOOK_DIR" ]]; then
  for hook in "$HOOK_DIR"/*.sh; do
    [[ -x "$hook" ]] || continue
    say "pre-hook: ${hook}"
    "$hook" || fatal "pre-hook ${hook} failed; refusing to take an inconsistent snapshot."
  done
fi

# --- Backup --------------------------------------------------------------------
# --json so the snapshot id comes from restic's own summary rather than from
# grepping human output. #101's park workflow consumes the id this prints, so
# stdout carries THE ID AND NOTHING ELSE: every other line in this script goes to
# stderr, and adding chatter to stdout breaks park.
SUMMARY="$(mktemp)"
trap 'rm -f "$SUMMARY"' EXIT

restic backup "$SOURCE" \
  --exclude-file "$EXCLUDE_FILE" \
  --tag "$MODE" \
  --json | tee "$SUMMARY" >/dev/null

SNAPSHOT_ID="$(python3 - "$SUMMARY" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("message_type") == "summary":
        print(msg.get("snapshot_id", ""))
        break
PY
)"
[[ -n "$SNAPSHOT_ID" ]] || fatal "restic backup reported no summary snapshot_id; treat this run as failed."

say "snapshot ${SNAPSHOT_ID} saved"

# --- Retention -----------------------------------------------------------------
if [[ "$MODE" == "nightly" ]]; then
  restic forget \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --prune
  say "retention applied (daily ${KEEP_DAILY}, weekly ${KEEP_WEEKLY}, monthly ${KEEP_MONTHLY})"
else
  say "mode=final: skipping forget --prune so park is not blocked on a repack"
fi

# The park contract. Keep this the only thing on stdout.
printf '%s\n' "$SNAPSHOT_ID"
