---
name: tf-plan
description: Run the Terraform pre-flight (fmt check, init, validate, plan) for one homelab module or all five in dependency order. Use before committing Terraform changes or when asked to plan/preview infrastructure changes. Pass a module path (e.g. "compute/vm") or "all".
---

Run a consistent Terraform pre-flight for this repo's root modules.

## Input

`$ARGUMENTS` is a module directory or `all` (default: the module(s) touched by the current diff; if none, ask).

Dependency order for `all`: `infra/network` → `infra/dns` → `infra/cloudflare` → `infra/storage` → `compute/vm`.

## Environment

First work out which world you are in: `echo "$CLAUDE_CODE_REMOTE"`. `true` means a Claude Code
cloud session (the `homelab` environment); empty means a local run. They authenticate
differently, and each one's rule breaks the other — follow only the matching subsection.

### Local (`CLAUDE_CODE_REMOTE` unset)

Azure auth is the operator's own `az login` session — there is no service-principal secret any
more (retired in E02.4, #36). Confirm one exists and that the subscription ID is exported before
planning; if `az account show` fails, tell the user to run `az login` rather than trying to
authenticate for them:

```bash
az account show          # must succeed
export ARM_SUBSCRIPTION_ID=<subscription_id>
```

- `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/`ARM_TENANT_ID` must stay **unset**. If they are exported
  they take precedence over the `az login` session and every plan fails at authentication —
  check for them first when a plan dies on auth.

- `infra/cloudflare` additionally needs `TF_VAR_cloudflare_api_token` and `TF_VAR_cloudflare_zone_id` — if unset, tell the user and skip that module rather than letting the plan prompt/hang.
- `infra/dns` and `compute/vm` need `terraform.tfvars` (copy from `terraform.tfvars.example` if missing — ask the user for values, never invent them).

### Cloud (`CLAUDE_CODE_REMOTE=true`)

Azure auth is the environment's **read-only service principal**: `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/
`ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID` are set **on purpose**. Don't unset them, and don't
`export ARM_SUBSCRIPTION_ID` — it is already set. Terraform reads them itself; only `az` needs a
sign-in, which the SessionStart hook performs. If `az account show` fails (project threads and
multi-repo sessions don't run repo hooks), run `bash scripts/cloud-session-init.sh` — don't tell
the user to `az login`.

- **Plan only — never `apply`, `destroy`, `import`, `state rm`/`state mv` or `force-unlock`.** The
  identity can't, and applies belong to GitHub Actions or a local run as Owner.
- Plans run without a state lock: `TF_CLI_ARGS_plan=-lock=false` comes from the environment, so
  the commands under *Steps* are unchanged. Don't add the flag yourself.
- **Skip `infra/cloudflare`** with a note ("skipped — cloud session: no Cloudflare token,
  `api.cloudflare.com` not allowlisted"). In `all`, that leaves four modules.
- No `terraform.tfvars` exists in a cloud clone. `TF_VAR_dns_zone_name` and `TF_VAR_dns_rg_name`
  come from the environment and the fleet from `-var-file=../../fleet.tfvars` (below) — never
  invent a value.
- `init` rewrites the tracked `.terraform.lock.hcl` files (it adds this platform's hashes). After
  planning, `git checkout -- '*.terraform.lock.hcl'`; never commit that churn unless the task is a
  provider bump.
- If a plan fails with `AuthorizationFailed`, report the exact action it names and stop. Don't
  work around it — the fix is granting that one action to the identity, which is the owner's call.

### Either way

- Adding or removing a node is an edit to `fleet.tfvars`, which changes what **both** `compute/vm`
  and `infra/storage` deploy — plan the two together, in that dependency order, and expect the
  disk to appear before the VM that attaches it.

## Steps (per module, from the repo root)

```bash
terraform -chdir=<module> fmt -check -recursive
terraform -chdir=<module> init -input=false
terraform -chdir=<module> validate
terraform -chdir=<module> plan -input=false
```

**`compute/vm` is the exception (E17.4, #163): it uses a *partial* backend config**, so a bare
`init` there fails with "Missing backend configuration". Its state key is a flag:

```bash
terraform -chdir=compute/vm init -input=false -backend-config="key=homelab.compute.tfstate"
```

Add `-reconfigure` when the previous `init` in that checkout used a different key. The other five
modules still carry a literal `key` in `backend.tf` and take no flag.

**`compute/vm` and `infra/storage` both require the fleet map** — they declare `instances` with no
default, so `plan` without it fails on a missing variable (by design: the alternative is silently
planning an empty fleet). Paths are relative to the module dir under `-chdir`:

```bash
terraform -chdir=compute/vm    plan -input=false -var-file=../../fleet.tfvars
terraform -chdir=infra/storage plan -input=false -var-file=../../fleet.tfvars
```

- If `fmt -check` fails, run `terraform -chdir=<module> fmt -recursive` and note which files changed.
- NEVER run `terraform apply` or `terraform destroy` from this skill — plan only.
- Expected noise: the `infra/network` plan shows a diff on the NSG SSH rule whenever the caller's public IP changed (it's fetched live from api.ipify.org). Point this out instead of treating it as a real change. In a cloud session it is always present: the caller's address is the session's egress IP.

## Report

Summarize per module: fmt/validate status and the plan's add/change/destroy counts, calling out anything destructive. In a cloud session, list `infra/cloudflare` as skipped.
