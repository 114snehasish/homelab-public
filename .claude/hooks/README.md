# Claude Code hooks

Hooks that guard this repo, and set up its cloud sessions, when it's edited through Claude Code.

## `block-env.js` — block `.env` secrets access (PreToolUse)

Denies any tool call that would read, write, or reference a `.env` secrets file.

**Why.** The root `.env` holds live credentials — the Cloudflare API token today, and whatever
comes next (it held the Azure service-principal secret until E02.4, #36, retired it) —
and `main` is force-mirrored to a **public** GitHub repo on every push
(`.github/workflows/mirror.yml`). Pulling `.env` contents into the transcript is a real
leak vector, so we block it at the tool boundary — defense-in-depth on top of `.env`
already being gitignored.

**What it blocks / allows.**

| Referenced path                                   | Result |
| ------------------------------------------------- | ------ |
| `.env`, `.env.local`, `.env.production`, `path/.env` | **denied** |
| `.env.example`, `.env.sample`, `.env.template`    | allowed (non-secret, committed scaffolding) |
| `environment.md`, `docs/env.md`, unrelated names  | allowed |

**Tools guarded** (via the `matcher` in `../settings.json`):
`Read`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, `Bash`, `Grep`, `Glob`.
For `Bash`/`Grep`/`Glob` the command / pattern / path string is scanned, so indirect
access like `cat .env` or a `**/.env` glob is caught too.

**Behavior on a block.** The tool call is denied and Claude sees a short reason
explaining the `.env` guardrail. The hook **fails open** (allows) on any malformed
input or internal error, so a bug here can never wedge a session.

## Requirements

Node.js must be on `PATH` wherever Claude Code runs (the hook uses only Node built-ins —
no npm install). Verified with Node 22.

## Testing the hook

The hook reads a tool-call JSON payload on stdin and, to block, prints a
`permissionDecision: "deny"` object on stdout (exit 0); to allow, it exits 0 with no
output. Drive it directly (note: run this from a plain shell — inside Claude Code the
hook will block your own `.env`-containing command, which is the hook working):

```bash
# denied
printf '%s' '{"tool_name":"Read","tool_input":{"file_path":".env"}}' | node .claude/hooks/block-env.js
# allowed (prints nothing)
printf '%s' '{"tool_name":"Read","tool_input":{"file_path":".env.example"}}' | node .claude/hooks/block-env.js
```

## `cloud-session-init.sh` — sign `az` in for cloud sessions (SessionStart)

Signs the Azure CLI in as the read-only service principal `homelab-claude-cloud-reader` when a
session starts in the personal Claude Code **cloud** environment (claude.ai/code, `homelab`), then
prints a one-line reminder that cloud sessions are plan-only. Terraform itself needs none of this:
azurerm reads `ARM_*` from the environment, so only `az` needs an explicit login. What the identity
is, what it may do and how the environment is configured:
[`docs/runbooks/claude_cloud_environment.md`](../../docs/runbooks/claude_cloud_environment.md).
Source: [`scripts/cloud-session-init.sh`](../../scripts/cloud-session-init.sh).

**Only acts in cloud sessions.** It exits at once unless `CLAUDE_CODE_REMOTE=true`, so on a laptop
it is a silent no-op — there `az login` as yourself is the auth path, and `ARM_CLIENT_*` must stay
unset.

**Fails open.** Every path exits 0 (deliberately no `set -e`): a missing variable, a failed login,
an expired secret or a missing tool each print one line of diagnosis and let the session start. A
SessionStart hook's stdout is handed to Claude as context, which is how those lines — and the
plan-only reminder — reach it. The script never prints the client secret, nor `az`'s own error text
(it can carry the client and tenant IDs): on a failed login it reports only the `AADSTS` code.

**Registered** in `../settings.json` for `startup|resume`, synchronous, 60 s timeout. The session
waits for it; that is the point, since `az` is then signed in before the first prompt. Idempotent:
a resumed session that is already signed in as the identity skips the login.

**Requirements.** `az` and `jq` on `PATH`; bash 3.2 is enough, so macOS's `/bin/bash` works. The environment's setup script installs
`az`; `jq` is already in the cloud image and the setup script does not install it. `terraform` is
needed too, for the version check (`terraform version` against `.terraform-version`, warning on
drift). A missing tool is reported, not fatal.

**Not run everywhere.** Project threads and multi-repo sessions don't run repo hooks. There, run
`bash scripts/cloud-session-init.sh` by hand.

**Testing.** From the repo root:

```bash
# local: silent no-op, exit 0
bash scripts/cloud-session-init.sh; echo "exit=$?"
# cloud, a variable missing: one diagnostic line, exit 0
env -u ARM_CLIENT_ID CLAUDE_CODE_REMOTE=true bash scripts/cloud-session-init.sh; echo "exit=$?"
```

To exercise the failed-login path, set `CLAUDE_CODE_REMOTE=true`, made-up `ARM_CLIENT_ID`,
`ARM_TENANT_ID` and `ARM_CLIENT_SECRET` values, and `AZURE_CONFIG_DIR=$(mktemp -d)` so your real
`az` login is untouched. It should print an `AADSTS` code — never an ID — and still exit 0.
