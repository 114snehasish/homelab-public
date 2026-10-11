#!/usr/bin/env bash
#
# cloud-session-init.sh — sign `az` in as the read-only cloud identity
#
# SessionStart hook for Claude Code cloud sessions (claude.ai/code, the "homelab"
# environment), registered in .claude/settings.json. Also safe to run by hand —
# `bash scripts/cloud-session-init.sh` — which is what a session does when it did
# not run repo hooks (project threads and multi-repo sessions do not). What the
# identity is, what it may do and why it exists at all:
# docs/runbooks/claude_cloud_environment.md.
#
# Cloud sessions only. Locally this is a no-op: `az login` as yourself is the auth
# path there, and ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID must stay UNSET
# (exported, they override your az session).
#
# Terraform needs none of this: azurerm reads the ARM_* variables itself. Only `az`
# needs an explicit login.
#
# Fails open, on purpose — which is why there is no `set -euo pipefail` here, unlike
# its siblings. Every path exits 0, so a sign-in problem can never keep a session
# from starting. Problems are reported on stdout, which a SessionStart hook hands to
# Claude as context.
#
# The "signed in" line is printed only after a real `az login` with the CURRENT
# credentials AND a successful subscription selection. Nothing weaker proves it:
# `az account show` and `az account get-access-token` both answer from the local
# profile and token cache.
#
# Stays bash-3.2-compatible on purpose: macOS /bin/bash is 3.2, and that is where this
# gets run by hand. So no ${var,,} / ${var^^}, mapfile or associative arrays. Failing
# open makes this matter: a bash-4-only construct would not stop the script, bash would
# just drop the statement it sits in and carry on to the success banner.
#
# Prints nothing secret. The client secret goes to `az login` and nowhere else, and
# az's own error text is never echoed (it can carry the client and tenant IDs) —
# only the AADSTS code in it, and which of a few known shapes it matched.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

say() { printf 'cloud-session-init: %s\n' "$*"; }
reminder="Cloud sessions are PLAN-ONLY: never terraform apply/destroy here; applies go through GitHub Actions."

if [ -z "${ARM_CLIENT_ID:-}" ] || [ -z "${ARM_CLIENT_SECRET:-}" ] || [ -z "${ARM_TENANT_ID:-}" ]; then
  say "ARM_* not set on this cloud environment; az is NOT signed in. Is the session running in the 'homelab' environment?"
  exit 0
fi

if ! command -v az >/dev/null 2>&1; then
  say "az is not on PATH, so it is NOT signed in. The environment's setup script installs it."
  exit 0
fi

# Sign in every time, even when az already has an account cached (a resumed session
# keeps ~/.azure). A cached login would hide a rotated or expired secret: the banner
# below would claim a sign-in while every later az call failed at token refresh. Logging
# in with the current secret is the only check that means anything, and warm it takes
# about a second. It also replaces anyone else's cached login (say, a human who ran
# `az login` in this container) with the read-only identity.
# --password=… and not `--password …`: az parses a secret starting with "-" as an option
# otherwise.
if ! err=$(az login --service-principal \
    --username "$ARM_CLIENT_ID" --password="$ARM_CLIENT_SECRET" \
    --tenant "$ARM_TENANT_ID" --output none 2>&1); then
  code=$(printf '%s' "$err" | grep -oE 'AADSTS[0-9]+' | head -n 1)
  case "$code" in
    AADSTS7000222) why="the client secret has expired" ;;
    AADSTS7000215) why="the client secret is wrong: the secret ID pasted instead of its value, or it was rotated" ;;
    AADSTS700016)  why="ARM_CLIENT_ID or ARM_TENANT_ID does not match an app registration, or the app was deleted" ;;
    AADSTS90002)   why="ARM_TENANT_ID could not be resolved" ;;
    "")
      # No AADSTS code. Either az authenticated and then found no subscription (the
      # Reader assignment deleted, or a new one still propagating), or it failed before
      # Entra answered at all.
      if printf '%s' "$err" | grep -q 'No subscriptions found'; then
        why="the identity authenticated but has no role on any subscription (Reader deleted, or a new assignment still propagating)"
      else
        why="no AADSTS code and no recognised message, which usually means the network (is login.microsoftonline.com reachable?)"
      fi ;;
    *) why="an Entra error this script does not recognise" ;;
  esac
  say "az login failed${code:+ ($code)}: $why. az is NOT signed in. See docs/runbooks/claude_cloud_environment.md (Troubleshooting)."
  exit 0
fi

# The success line is only true if az can also work in the configured subscription.
problem=""
if [ -z "${ARM_SUBSCRIPTION_ID:-}" ]; then
  problem="ARM_SUBSCRIPTION_ID is not set (terraform will fail until it is)"
elif ! az account set --subscription "$ARM_SUBSCRIPTION_ID" >/dev/null 2>&1; then
  problem="could not select the subscription named by ARM_SUBSCRIPTION_ID (is Reader still assigned? a new assignment can take a minute to propagate)"
fi

# Warn if the environment's pinned Terraform has drifted from the repo pin. The repo
# root falls back to this script's location: CLAUDE_PROJECT_DIR is unset when run by hand.
root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
want=$(cat "$root/.terraform-version" 2>/dev/null)
if ! command -v terraform >/dev/null 2>&1; then
  say "terraform is not on PATH. The environment's setup script installs it."
elif ! command -v jq >/dev/null 2>&1; then
  say "jq is not on PATH; skipped the Terraform version check."
else
  have=$(terraform version -json 2>/dev/null | jq -r '.terraform_version // empty')
  if [ -n "$want" ] && [ "$want" != "$have" ]; then
    say "Terraform ${have:-?} installed but .terraform-version pins $want. Update TF_VERSION in the homelab environment's setup script."
  fi
fi

if [ -n "$problem" ]; then
  say "signed in, but $problem. $reminder"
else
  echo "Azure: signed in as read-only identity homelab-claude-cloud-reader. $reminder"
fi
exit 0
