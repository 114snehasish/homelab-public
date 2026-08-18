---
name: tf-plan
description: Run the Terraform pre-flight (fmt check, init, validate, plan) for one homelab module or all five in dependency order. Use before committing Terraform changes or when asked to plan/preview infrastructure changes. Pass a module path (e.g. "compute/vm") or "all".
---

Run a consistent Terraform pre-flight for this repo's root modules.

## Input

`$ARGUMENTS` is a module directory or `all` (default: the module(s) touched by the current diff; if none, ask).

Dependency order for `all`: `infra/network` → `infra/dns` → `infra/cloudflare` → `infra/storage` → `compute/vm`.

## Environment

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
terraform -chdir=infra/storage plan -input=false -var-file=../fleet.tfvars
```

- If `fmt -check` fails, run `terraform -chdir=<module> fmt -recursive` and note which files changed.
- NEVER run `terraform apply` or `terraform destroy` from this skill — plan only.
- Expected noise: the `infra/network` plan shows a diff on the NSG SSH rule whenever the caller's public IP changed (it's fetched live from api.ipify.org). Point this out instead of treating it as a real change.

## Report

Summarize per module: fmt/validate status and the plan's add/change/destroy counts, calling out anything destructive.
