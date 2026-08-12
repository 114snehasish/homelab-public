# Claude Code hooks

Hooks that guard this repo when it's edited through Claude Code.

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
