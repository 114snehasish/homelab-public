#!/usr/bin/env bash
#
# check-edge-routes.sh — cross-check the edge router's routes against the apps
# that exist (#40).
#
#   check-edge-routes.sh <adapted.json> <edge-app-dir>     e.g. ... apps/caddy
#
# <adapted.json> is `caddy adapt` output for <edge-app-dir>/Caddyfile. Every
# other directory beside <edge-app-dir> that holds a docker-compose.yml is an
# app. Two assertions:
#
#   1. every app is reachable: at least one reverse_proxy upstream's host is
#      the app's own name, which check-app-conventions.sh guarantees is its main
#      container_name ("deployed but unreachable");
#   2. every reverse_proxy upstream names a container some app's compose file
#      defines ("route to an app that doesn't exist"). On the `web` network a
#      container name is the only upstream that resolves, so an IP, localhost or
#      a typo is always a dead route.
#
# The edge app itself is exempt from (1): it is the router, not a route.
# Needs docker (Compose v2) and jq. Portable to bash 3.2.

set -euo pipefail

json="${1:?adapted Caddy JSON}"
edge_dir="${2:?edge app dir, e.g. apps/caddy}"
edge_dir="${edge_dir%/}"
edge_app="$(basename "$edge_dir")"
apps_root="$(dirname "$edge_dir")"
fail=0

bad() {
  printf '::error file=%s/Caddyfile::%s\n' "$edge_dir" "$*"
  fail=1
}

# Upstream hosts: every reverse_proxy handler, at any depth, minus the port.
upstreams="$(jq -r '.. | objects | select(.handler? == "reverse_proxy") | .upstreams[]?.dial // empty' "$json" |
  sed 's/:[0-9]*$//' | sort -u)"

apps=""
containers=""
for f in "$apps_root"/*/docker-compose.yml; do
  [[ -f "$f" ]] || continue
  a="$(basename "$(dirname "$f")")"
  apps+="${a}"$'\n'
  containers+="$(docker compose -f "$f" config --format json | jq -r '.services[].container_name // empty')"$'\n'
done

has_line() { grep -Fxq -- "$2" <<<"$1"; }

# 2. No route to nowhere.
while IFS= read -r u; do
  [[ -n "$u" ]] || continue
  if ! has_line "$containers" "$u"; then
    bad "a route proxies to '$u', but no ${apps_root}/*/docker-compose.yml defines a container named '$u'. Fix the upstream, or add the app."
  fi
done <<<"$upstreams"

# 1. No app without a route.
while IFS= read -r a; do
  [[ -n "$a" && "$a" != "$edge_app" ]] || continue
  if ! has_line "$upstreams" "$a"; then
    bad "app '$a' is deployed but unreachable: add a route inside the wildcard site, e.g. '@${a} host ${a}.<zone>' plus 'handle @${a} { reverse_proxy ${a}:<port> }'."
  fi
done <<<"$apps"

if ((fail == 0)); then
  printf 'edge routes ok: upstreams [%s], apps behind the edge [%s]\n' \
    "$(paste -sd, - <<<"$upstreams")" "$(grep -vFx -e "$edge_app" -e '' <<<"$apps" | paste -sd, -)"
fi
exit "$fail"
