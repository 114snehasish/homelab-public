#!/usr/bin/env bash
#
# check-app-conventions.sh — enforce the apps/ house rules on one app (#40).
#
#   check-app-conventions.sh <app-dir>          e.g. apps/homepage
#
# Reads Compose's resolved config (`docker compose config --format json`), so it
# sees what Compose will actually run: relative bind sources are
# already absolute, short-form ports and networks are already expanded. Prints
# one ::error:: per violation, saying what to change, and exits 1 on any.
#
# The rules, and the incident or convention each one comes from (apps/README.md,
# CLAUDE.md "Conventions"):
#   1. every service joins the external `web` network — it is how Caddy reaches
#      the app by container name, and no app owns its lifecycle;
#   2. every bind source sits under /data/<app>/ or inside the app's own
#      directory — anything on the OS disk vanishes on resume, and Docker then
#      recreates the source as a root-owned directory (the 2026-10-06 failure);
#   3. `restart: unless-stopped` — park relies on it to bring containers back
#      after the graceful stop (ADR-0009 §4);
#   4. the node never builds: no `build:`, and every image has an exact tag or
#      a digest, never `latest` or none — a resume must not silently change what
#      runs. An app with a Dockerfile publishes it through apps-image.yml, and
#      its main service's image must be ${IMAGE_PREFIX}/homelab-<app>:<tag>
#      (default prefix ghcr.io/114snehasish), the reference that workflow pushes;
#   5. no published host ports outside EDGE_APPS — every other app is reached
#      through Caddy on `web`, never directly (and the NSG is not the guard);
#   6. container_name is set and predictable: the main service is named after
#      the directory, sidecars are `<app>-<role>` — so a Caddyfile route is always
#      `reverse_proxy <app>:<port>`.
#
# Needs docker (Compose v2) and jq. Portable to bash 3.2.

set -euo pipefail

# The only apps allowed to publish host ports: the edge router every other app
# sits behind. This list is the only place an app is named in this script.
EDGE_APPS=(caddy)

dir="${1:?app dir, e.g. apps/homepage}"
dir="${dir%/}"
app="$(basename "$dir")"
compose="${dir}/docker-compose.yml"
image_prefix="${IMAGE_PREFIX:-ghcr.io/114snehasish}"
main_img=""
fail=0

err() {
  printf '::error file=%s::%s: %s\n' "$compose" "$app" "$*"
  fail=1
}

[[ -f "$compose" ]] || {
  printf '::error::%s has no docker-compose.yml\n' "$dir"
  exit 1
}

cfg="$(docker compose -f "$compose" config --format json)"

# Compose makes relative bind sources absolute with the logical path; allow the
# physical one too, in case the checkout sits behind a symlink (macOS /tmp).
abs_logical="$(cd "$dir" && pwd -L)"
abs_physical="$(cd "$dir" && pwd -P)"

is_edge=false
for e in "${EDGE_APPS[@]}"; do
  [[ "$e" == "$app" ]] && is_edge=true
done

# Rule 1, network half: `web` must be declared external, never created here.
# Compose drops networks no service uses from its resolved config, so this is
# only checked once some service joins `web`; a service that doesn't gets its
# own error below, which is the one to fix first.
if jq -e 'any(.services[]; (.networks // {}) | has("web"))' >/dev/null <<<"$cfg" &&
  ! jq -e '.networks.web.external == true' >/dev/null <<<"$cfg"; then
  err "network 'web' must be declared at the top level as 'web: {external: true}'. It is created once per disk (apps/README.md Step 1) and no app owns it."
fi

services="$(jq -r '.services | keys[]' <<<"$cfg")"
main_count=0

while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  svc="$(jq -c --arg s "$s" '.services[$s]' <<<"$cfg")"

  # Rule 1: on `web`, not host networking.
  if [[ "$(jq -r '.network_mode // ""' <<<"$svc")" != "" ]]; then
    err "service '$s' sets network_mode; remove it and add 'networks: [web]', so Caddy can reach it by name."
  elif ! jq -e '(.networks // {}) | has("web")' >/dev/null <<<"$svc"; then
    err "service '$s' is not on network 'web'; add 'networks: [web]'."
  fi

  # Rule 2: bind sources survive a resume.
  while IFS= read -r src; do
    [[ -n "$src" ]] || continue
    case "$src" in
      "/data/${app}" | "/data/${app}/"* | "/data/apps/${app}" | "/data/apps/${app}/"*) ;;
      "$abs_logical" | "$abs_logical/"* | "$abs_physical" | "$abs_physical/"*) ;;
      *) err "service '$s' bind-mounts '$src'. Bind sources must be under /data/${app}/ (state) or inside ${dir}/ (config shipped with the app). Anywhere else is either the OS disk, which is gone after a resume, or another app's state." ;;
    esac
  done < <(jq -r '.volumes[]? | select(.type == "bind") | .source' <<<"$svc")

  # Rule 3: park/resume brings it back.
  restart="$(jq -r '.restart // ""' <<<"$svc")"
  if [[ "$restart" != "unless-stopped" ]]; then
    err "service '$s' has restart '${restart:-unset}'; set 'restart: unless-stopped', which park/resume relies on to bring it back."
  fi

  # Rule 4: the node never builds, and pulls only pinned images.
  if jq -e '.build != null' >/dev/null <<<"$svc"; then
    err "service '$s' uses 'build:'; the node never builds. Put the Dockerfile in ${dir}/ (apps-image.yml publishes it) and reference ${image_prefix}/homelab-${app}:<tag> with 'image:'."
  fi
  img="$(jq -r '.image // ""' <<<"$svc")"
  last="${img##*/}"
  if [[ -z "$img" ]]; then
    err "service '$s' has no image; pin one with 'image: <name>:<exact version>'."
  elif [[ "$img" == *@sha256:* ]]; then
    :
  elif [[ "$last" != *:* ]]; then
    err "service '$s' image '$img' has no tag; pin an exact version, e.g. '${img}:1.2.3'."
  elif [[ "${last##*:}" == "latest" ]]; then
    err "service '$s' image '$img' uses 'latest'; pin an exact version so a resume cannot change what runs."
  fi

  # Rule 5: only the edge publishes ports.
  if [[ "$is_edge" != true ]] && jq -e '(.ports // []) | length > 0' >/dev/null <<<"$svc"; then
    err "service '$s' publishes host ports; remove 'ports:'. Apps are reached through Caddy on 'web' (add a handle block with reverse_proxy ${app}:<port>), never directly."
  fi

  # Rule 6: predictable container names.
  cn="$(jq -r '.container_name // ""' <<<"$svc")"
  if [[ -z "$cn" ]]; then
    err "service '$s' has no container_name; set it to '${app}' for the main service or '${app}-<role>' for a sidecar."
  elif [[ "$cn" == "$app" ]]; then
    main_count=$((main_count + 1))
    main_img="$img"
  elif [[ "$cn" != "${app}-"* ]]; then
    err "service '$s' container_name '$cn' must be '${app}' (main service) or start with '${app}-' (sidecar)."
  fi
done <<<"$services"

if ((main_count != 1)); then
  err "exactly one service must have container_name '${app}' (found ${main_count}); it is the name Caddy proxies to."
fi

# Rule 4, published half: a Dockerfile here means apps-image.yml publishes
# ${image_prefix}/homelab-<app>:<tag> from the compose image line, so the main
# service must name exactly that repository.
if [[ -f "$dir/Dockerfile" && "$main_count" -eq 1 && "$main_img" != "${image_prefix}/homelab-${app}:"* ]]; then
  err "${dir}/Dockerfile exists, so the main service's image must be '${image_prefix}/homelab-${app}:<tag>' (apps-image.yml publishes exactly that), not '${main_img}'."
fi

if ((fail == 0)); then
  printf 'conventions ok: %s (%s service(s))\n' "$app" "$(grep -c . <<<"$services")"
fi
exit "$fail"
