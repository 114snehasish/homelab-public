#!/usr/bin/env bash
#
# apps/caddy/check.sh — Caddy's own checks (#40, PR B). apps-check.yml runs it
# after the house rules, with the image it just built in $APP_IMAGE.
#
# Keeps the three version facts in step, because nothing else does:
#   1. the builder and runtime FROM lines name the same Caddy version (the
#      binary comes from the builder, so a skew ships the older Caddy under the
#      newer image's labels; Dependabot can bump one line without the other);
#   2. the compose image tag is `<that version>-azuredns<plugin version>`, plus
#      an optional `-r<N>` for a rebuild with the same versions;
#   3. the built binary really is that version and really has the DNS plugin.
#
# Reads the Dockerfile and compose file as text, not through `docker compose
# config`, so it also runs anywhere without an env file.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fail=0
err() {
  printf '::error file=apps/caddy/%s::%s\n' "$1" "$2"
  fail=1
}

builder="$(sed -n 's/^FROM caddy:\([0-9][0-9.]*\)-builder.*/\1/p' "$here/Dockerfile")"
runtime="$(sed -n 's/^FROM caddy:\([0-9][0-9.]*\)[[:space:]]*$/\1/p' "$here/Dockerfile")"
plugin="$(sed -n 's/^RUN .*caddy-dns\/azure@v\([0-9][0-9.]*\).*/\1/p' "$here/Dockerfile")"
image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$here/docker-compose.yml" | head -n 1)"
tag="${image##*:}"

[[ -n "$builder" && -n "$runtime" && -n "$plugin" ]] ||
  err Dockerfile "could not read the builder, runtime and plugin versions (got builder='${builder}' runtime='${runtime}' plugin='${plugin}')."

if [[ "$builder" != "$runtime" ]]; then
  err Dockerfile "builder is caddy:${builder}-builder but runtime is caddy:${runtime}. Set both FROM lines to the same version: the binary comes from the builder."
fi

want="${builder}-azuredns${plugin}"
case "$tag" in
  "$want" | "$want"-r[0-9] | "$want"-r[0-9][0-9]) ;;
  *) err docker-compose.yml "image tag is '${tag}', expected '${want}' (or '${want}-r<N>' for a rebuild with the same versions). Bump it with the Dockerfile." ;;
esac

if [[ -n "${APP_IMAGE:-}" ]]; then
  got="$(docker run --rm "$APP_IMAGE" caddy version | cut -d' ' -f1)"
  [[ "$got" == "v${builder}" ]] ||
    err Dockerfile "the built binary reports ${got}, but the Dockerfile says ${builder}."
  docker run --rm "$APP_IMAGE" caddy list-modules | grep -qx 'dns.providers.azure' ||
    err Dockerfile "the built binary has no dns.providers.azure module; the DNS-01 challenge cannot work."
fi

if ((fail == 0)); then
  printf 'caddy ok: %s, plugin %s, tag %s%s\n' "$builder" "$plugin" "$tag" "${APP_IMAGE:+, binary verified}"
fi
exit "$fail"
