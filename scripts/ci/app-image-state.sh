#!/usr/bin/env bash
#
# app-image-state.sh — is an app's published image current? (#40, PR B)
#
#   app-image-state.sh <app-dir>          e.g. apps/caddy
#
# For an app with a Dockerfile, the image reference in its compose file is the
# single source of truth: apps-image.yml publishes exactly that reference, and
# the node pulls exactly that reference. Tags are IMMUTABLE. Each published image
# carries a label with the sha256 of the Dockerfile it was built from, and this
# script compares that label with the Dockerfile in the checkout:
#
#   absent   the tag was never published       -> apps-image.yml publishes it
#   current  published from this Dockerfile    -> nothing to do
#   stale    published from another Dockerfile -> error: bump the tag
#
# "stale" is an error, never a rebuild: overwriting a tag would change what a
# node pulls on its next deploy without anything in git changing.
# Scope of the hash: the Dockerfile only. An app whose Dockerfile COPYs other
# files must bump its tag by hand when those change; none does today.
#
# Writes ref=, tag=, dockerfile_sha256= and state= to $GITHUB_OUTPUT when set, and
# always to stdout. Needs docker (Compose v2, buildx), jq, sha256sum or shasum,
# and a `docker login ghcr.io` for anything not yet public.

set -euo pipefail

dir="${1:?app dir, e.g. apps/caddy}"
dir="${dir%/}"
app="$(basename "$dir")"
label="homelab.dockerfile-sha256"

[[ -f "$dir/Dockerfile" ]] || {
  printf '::error::%s has no Dockerfile, so there is no image to publish\n' "$dir"
  exit 1
}

# The main service is the one named after the directory (check-app-conventions.sh
# rule 6), and its image is the reference to publish.
ref="$(docker compose -f "$dir/docker-compose.yml" config --format json |
  jq -r --arg a "$app" '.services[] | select(.container_name == $a) | .image // empty')"
[[ -n "$ref" ]] || {
  printf '::error file=%s/docker-compose.yml::no service with container_name %s and an image: to publish\n' "$dir" "$app"
  exit 1
}

if command -v sha256sum >/dev/null; then
  want="$(sha256sum "$dir/Dockerfile" | cut -d' ' -f1)"
else
  want="$(shasum -a 256 "$dir/Dockerfile" | cut -d' ' -f1)"
fi

emit() {
  local kv
  kv="$(printf "ref=%s\ntag=%s\ndockerfile_sha256=%s\nstate=%s" "$ref" "${ref##*:}" "$want" "$1")"
  printf "%s\n" "$kv"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf "%s\n" "$kv" >>"$GITHUB_OUTPUT"; fi
}

if out="$(docker buildx imagetools inspect "$ref" --format '{{json .Image}}' 2>&1)"; then
  # A single-platform image gives one config; an index gives a map of them.
  have="$(jq -r --arg l "$label" \
    'if has("config") then .config.Labels[$l] // "" else ([.[] | .config.Labels[$l] // ""] | first) end' <<<"$out")"
  if [[ "$have" == "$want" ]]; then
    emit current
  else
    emit stale
    printf '::error file=%s/docker-compose.yml::%s is already published from a different Dockerfile (label %s=%s, this Dockerfile is %s). Tags are immutable: bump the tag in %s/docker-compose.yml.\n' \
      "$dir" "$ref" "$label" "${have:-none}" "$want" "$dir"
    exit 1
  fi
elif grep -qiE 'not found|manifest unknown|name unknown|denied|403 forbidden' <<<"$out"; then
  # GHCR answers 403 rather than 404 for a package that does not exist yet, the
  # same answer it gives for one this token cannot read. A token that can push
  # can always read, so on main this is "never published".
  emit absent
else
  printf '::error::could not inspect %s: %s\n' "$ref" "$out"
  exit 1
fi
