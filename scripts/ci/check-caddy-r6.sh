#!/usr/bin/env bash
#
# check-caddy-r6.sh — fail unless the only certificate Caddy would ever request
# is the zone wildcard (risk R6; E03.4 PR A, #40).
#
#   check-caddy-r6.sh <adapted.json> <expected-wildcard>
#
# <adapted.json> is `caddy adapt` output for apps/caddy/Caddyfile. Checking
# Caddy's own adapted config, not grepping the Caddyfile, is the point: it sees
# what Caddy will actually do, including site addresses joined with a comma and
# certificate policies a global options block might add.
#
# Why it matters: Caddy takes every site address literally as a certificate
# subject. A second site block, or a second address on the wildcard's block,
# requests a certificate for that exact hostname, and the hostname then shows up
# in a public Certificate Transparency log. On-demand TLS does the same thing for
# every hostname a client asks for. The repo is mirrored publicly, so per-app
# hostnames reaching CT is the leak the wildcard exists to prevent.
#
# Three assertions:
#   1. the hosts the server routes match at its top level are exactly the
#      wildcard (a `host` matcher inside a `handle` is a route, not a site, and is
#      not top-level, so per-app routes pass);
#   2. every TLS automation policy names only the wildcard as its subject;
#   3. on-demand TLS is not enabled anywhere.

set -euo pipefail

json="${1:?adapted Caddy JSON}"
want="${2:?expected wildcard, e.g. *.az.example.com}"
fail=0

bad() {
  printf '::error::R6: %s\n' "$*"
  fail=1
}

hosts="$(jq -c '[.apps.http.servers[]?.routes[]?.match[]?.host[]?] | unique' "$json")"
if [[ "$hosts" != "$(jq -cn --arg w "$want" '[$w]')" ]]; then
  bad "Caddy serves sites for ${hosts}, expected exactly [\"${want}\"]. Every app must be a 'handle' block with a host matcher inside the one wildcard site block, never a site block or site address of its own."
fi

subjects="$(jq -c '[.apps.tls.automation.policies[]?.subjects[]?] | unique' "$json")"
extra="$(jq -c --arg w "$want" '[.apps.tls.automation.policies[]?.subjects[]? | select(. != $w)] | unique' "$json")"
if [[ "$extra" != "[]" ]]; then
  bad "TLS automation would request certificates for ${extra}. Only \"${want}\" may ever be a certificate subject."
fi

if jq -e '(.apps.tls.automation.on_demand != null) or any(.apps.tls.automation.policies[]?; .on_demand == true)' "$json" >/dev/null; then
  bad "on-demand TLS is enabled. It issues a certificate for every hostname a client asks for, and each one lands in a public CT log."
fi

if ((fail == 0)); then
  printf 'R6 ok: sites %s, certificate subjects %s, no on-demand TLS\n' "$hosts" "$subjects"
fi
exit "$fail"
