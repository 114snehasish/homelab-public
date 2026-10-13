#!/usr/bin/env bash
#
# node-health.sh — "did this node come back whole?" (#101, ADR-0009 §5)
#
# Executed ON A NODE, as root, through Azure managed Run Command by
# .github/workflows/_resume.yml after compute/vm is applied — on every resume and
# on every applying deploy.yml run. NOT part of custom_data: editing it never
# replaces a VM.
#
# It checks the resume contract from the inside, in the order the boot runs it:
#   cloud-init finished -> the data disk is mounted and passed its guard ->
#   it was cleanly unmounted at park -> Docker is up -> every container that is
#   meant to be running is running, and stays running -> Caddy loaded its
#   certificate rather than ordering a new one.
# The HTTPS check runs from the GitHub runner instead (it must see what a
# client sees), so it is not here.
#
# Output: one `OK|WARN|FATAL <check>: <detail>` line per check on stdout, so the
# last 4 KB Run Command returns is the useful part. Exit 1 if any check is FATAL.
# WARN never fails the run — it is for things worth seeing that do not mean the
# lab is down.

set -uo pipefail

CLOUD_INIT_TIMEOUT=1500
SETTLE_SECONDS=30
fatal_count=0

ok() { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
bad() {
  printf 'FATAL %s\n' "$*"
  fatal_count=$((fatal_count + 1))
}

printf 'node-health on %s\n' "$(hostname)"

# 1. cloud-init. Exit 2 is "done, with recoverable errors" — #236 saw Azure's
#    own IMDS reprovision polling report exactly that, unrelated to this repo.
timeout "$CLOUD_INIT_TIMEOUT" cloud-init status --wait >/dev/null 2>&1
rc=$?
case "$rc" in
  0) ok "cloud-init: done" ;;
  2) warn "cloud-init: done with recoverable errors (extended status degraded) — read 'cloud-init status --long'" ;;
  124) bad "cloud-init: still running after ${CLOUD_INIT_TIMEOUT}s" ;;
  *) bad "cloud-init: failed (exit ${rc}) — read /var/log/cloud-init-output.log" ;;
esac

# 2. The mount contract (#99): prepare -> mount -> guard -> target. The target
#    can only be active if every guard passed.
if systemctl is-active --quiet homelab-persist.target; then
  ok "persist: homelab-persist.target active ($(journalctl -b -u 'homelab-data-guard@*' -o cat --no-pager 2>/dev/null | grep -m1 ': OK ' || echo 'guard passed'))"
else
  bad "persist: homelab-persist.target is not active — Docker cannot start. journalctl -b -u 'homelab-persist-prepare@*' -u 'homelab-data-guard@*'; recovery in docs/runbooks/data_guard.md"
fi

# 3. Was /data cleanly unmounted at park? Park stops the VM gracefully before
#    destroying it (ADR-0009 §5, #101), so e2fsck should find a clean
#    filesystem. A replayed journal means the disk was detached or the VM died
#    mid-write — data is still consistent at the filesystem level, but worth knowing.
if journalctl -b -u 'homelab-persist-prepare@*' -o cat --no-pager 2>/dev/null | grep -q 'recovering journal'; then
  warn "persist: e2fsck replayed the journal — /data was NOT cleanly unmounted last time (crash-consistent, not clean)"
else
  ok "persist: /data was cleanly unmounted (no journal replay)"
fi

# 4. Docker, behind the target.
if ! systemctl is-active --quiet docker.service; then
  bad "docker: docker.service is not active"
  printf 'summary: %d fatal\n' "$fatal_count"
  exit 1
fi
ok "docker: active"

# 5. Every container that should be running is running — and is still the same
#    process ${SETTLE_SECONDS}s later. A restart loop (the 2026-10-06 Caddy
#    failure: a bind source that no longer existed) looks "running" at any
#    single instant; a changed StartedAt gives it away.
snapshot() {
  docker ps -a --format '{{.Names}}' | while read -r name; do
    docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}} {{.State.Status}} {{.State.StartedAt}}' "$name"
  done | sed 's#^/##' | awk '$2 == "unless-stopped" || $2 == "always"'
}
first="$(snapshot)"
sleep "$SETTLE_SECONDS"
second="$(snapshot)"
if [[ -z "$second" ]]; then
  warn "containers: none with a restart policy — nothing to check"
else
  while read -r name _policy status started; do
    before="$(awk -v n="$name" '$1 == n { print $4 }' <<<"$first")"
    if [[ "$status" != "running" ]]; then
      bad "container ${name}: ${status} — docker logs ${name}"
    elif [[ "$before" != "$started" ]]; then
      bad "container ${name}: restarting (StartedAt moved within ${SETTLE_SECONDS}s) — docker logs ${name}"
    else
      ok "container ${name}: running since ${started}"
    fi
  done <<<"$second"
fi

# 6. Caddy loaded its certificate from /data/caddy rather than ordering one.
#    ADR-0009 §5: an ACME order after a resume is a failure signal, not a
#    nuisance — the cert store is T1 and must have survived.
if docker inspect caddy >/dev/null 2>&1; then
  boot_epoch="$(date -d "$(uptime -s)" +%s)"
  if docker logs --since "$boot_epoch" caddy 2>&1 | grep -qE 'obtaining certificate|certificate obtained successfully'; then
    bad "caddy: ordered a certificate since boot — the ACME store on /data/caddy did not survive"
  else
    ok "caddy: no ACME order since boot (certificate loaded from /data/caddy)"
  fi
fi

printf 'summary: %d fatal\n' "$fatal_count"
[[ "$fatal_count" -eq 0 ]]
