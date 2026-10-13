#!/usr/bin/env bash
#
# run-on-node.sh — run one committed script on one node via Azure managed Run
# Command, and hand back its stdout and exit code (#101).
#
# Runs ON THE GITHUB RUNNER (az already logged in), called by _park.yml and
# _resume.yml. Run Command is the lab's CI→VM channel: no SSH key, no NSG hole,
# authorised by the CI identity's Contributor on homelab-rg. It needs
# allow_extension_operations = true on the VM (compute/vm/main.tf) because Run
# Command is delivered as a VM extension.
#
#   run-on-node.sh <vm-name> <script-path> <timeout-seconds> <label>
#
# stdout: the remote script's stdout (the last 4 KB — a Run Command limit, which
#         is why the remote scripts put the line that matters last).
# stderr: progress, plus the remote script's stderr.
# exit:   the remote script's exit code, or 1 if Run Command itself failed.
#
# The script is shipped base64-encoded and piped into bash, so it runs under
# bash whatever interpreter the Run Command handler uses for the wrapper line.

set -euo pipefail

vm="${1:?vm name}"
script="${2:?script path}"
timeout_s="${3:?timeout seconds}"
label="${4:?label}"
rg="${RG:-homelab-rg}"
agent_wait_seconds=600

say() { printf 'run-on-node[%s/%s]: %s\n' "$vm" "$label" "$*" >&2; }

[[ -r "$script" ]] || {
  say "no such script: ${script}"
  exit 1
}

# Run Command goes through the VM agent. On a freshly created VM the agent
# reports Ready only once provisioning settles, and cloud-init's apt upgrade can
# briefly restart it — so wait for Ready instead of failing on the first try.
waited=0
until [[ "$(az vm get-instance-view -g "$rg" -n "$vm" \
  --query 'instanceView.vmAgent.statuses[0].displayStatus' -o tsv 2>/dev/null || true)" == "Ready" ]]; do
  if ((waited >= agent_wait_seconds)); then
    say "VM agent not Ready after ${agent_wait_seconds}s"
    exit 1
  fi
  sleep 15
  waited=$((waited + 15))
done

# Unique per run and attempt, so "Re-run failed jobs" never collides with a
# Run Command resource a previous attempt left behind.
name="lc-${label}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"
payload="$(base64 -w0 <"$script")"

say "running ${script} (timeout ${timeout_s}s)"
# A non-zero remote exit can surface as a failed create. Either way the instance
# view below is the source of truth, so the create's own status is not trusted.
az vm run-command create -g "$rg" --vm-name "$vm" --name "$name" \
  --script "echo ${payload} | base64 -d | bash" \
  --timeout-in-seconds "$timeout_s" --async-execution false \
  -o none 2>/dev/null || true

view="$(az vm run-command show -g "$rg" --vm-name "$vm" --name "$name" --instance-view -o json 2>/dev/null || echo '{}')"

# The VM is destroyed right after a park; on resume it lives on, and a VM keeps
# at most 25 managed Run Commands. Delete ours either way.
az vm run-command delete -g "$rg" --vm-name "$vm" --name "$name" --yes -o none 2>/dev/null || true

state="$(jq -r '.instanceView.executionState // "Unknown"' <<<"$view")"
code="$(jq -r '.instanceView.exitCode // empty' <<<"$view")"
jq -r '.instanceView.error // empty' <<<"$view" | sed 's/^/  remote stderr: /' >&2
jq -r '.instanceView.output // empty' <<<"$view"

say "executionState=${state} exitCode=${code:-none}"
[[ "$state" == "Succeeded" && "$code" == "0" ]]
