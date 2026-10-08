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
# Prints nothing secret. The client secret goes to `az login` and nowhere else, and
# az's own error text is never echoed (it can carry the client and tenant IDs) —
# only the AADSTS code in it.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

say() { printf 'cloud-session-init: %s\n' "$*"; }

if [ -z "${ARM_CLIENT_ID:-}" ] || [ -z "${ARM_CLIENT_SECRET:-}" ] || [ -z "${ARM_TENANT_ID:-}" ]; then
  say "ARM_* not set on this cloud environment; az is NOT signed in. Is the session running in the 'homelab' environment?"
  exit 0
fi

if ! command -v az >/dev/null 2>&1; then
  say "az is not on PATH, so it is NOT signed in. The environment's setup script installs it."
  exit 0
fi

# A resumed session keeps ~/.azure, so log in only when we are not already signed in
# *as this identity*. Compared, never printed. Checking just `az account show` is not
# enough: someone who ran `az login` as themselves in this container would make the
# read-only banner below untrue.
signed_in=$(az account show --query user.name --output tsv 2>/dev/null)
if [ "${signed_in,,}" != "${ARM_CLIENT_ID,,}" ]; then
  # --password=… and not `--password …`: az parses a secret starting with "-" as an
  # option otherwise.
  if ! err=$(az login --service-principal \
      --username "$ARM_CLIENT_ID" --password="$ARM_CLIENT_SECRET" \
      --tenant "$ARM_TENANT_ID" --output none 2>&1); then
    code=$(printf '%s' "$err" | grep -oE 'AADSTS[0-9]+' | head -n 1)
    if [ -n "$code" ]; then
      say "az login failed ($code), most often an expired or rotated client secret. az is NOT signed in. See docs/runbooks/claude_cloud_environment.md (Troubleshooting)."
    else
      say "az login failed with no AADSTS code, which usually means the network (is login.microsoftonline.com reachable?). az is NOT signed in. See docs/runbooks/claude_cloud_environment.md (Troubleshooting)."
    fi
    exit 0
  fi
fi

if [ -n "${ARM_SUBSCRIPTION_ID:-}" ]; then
  az account set --subscription "$ARM_SUBSCRIPTION_ID" >/dev/null 2>&1 \
    || say "could not select the subscription named by ARM_SUBSCRIPTION_ID."
else
  say "ARM_SUBSCRIPTION_ID is not set; terraform will fail until it is."
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

echo "Azure: signed in as read-only identity homelab-claude-cloud-reader. Cloud sessions are PLAN-ONLY: never terraform apply/destroy here; applies go through GitHub Actions."
exit 0
