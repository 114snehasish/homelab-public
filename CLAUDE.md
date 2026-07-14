# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal Azure homelab infrastructure-as-code: pure Terraform + GitHub Actions. No application code, no tests, no Makefile. Five independent root modules, each with its own remote state.

## Modules and deployment order

Deploy in this order — later modules find earlier ones' resources **by name via data sources** (there is no `terraform_remote_state` linkage), so renames break downstream modules silently:

1. `infra/network` — `homelab-rg`, VNet 10.0.0.0/16, subnet, NSG
2. `infra/dns` — Azure DNS zone `az.snehasish-chakraborty.com` (root domain `snehasish-chakraborty.com` lives in Cloudflare)
3. `infra/cloudflare` — NS records delegating `az.*` from Cloudflare to Azure DNS
4. `infra/storage` — persistent 20GB data disk (`prevent_destroy = true`)
5. `compute/vm` — disposable VM (`homelab-vm.az.snehasish-chakraborty.com`); attaches the data disk at LUN 10 and registers its own DNS A record

Run `terraform init && terraform plan|apply` inside each module directory. Plans/applies happen both locally and via GitHub Actions — no strict rule.

## Never touch

These pre-exist and are managed **outside this repo** — never import, modify, or destroy:
- RG `do-not-delete` and storage account `listeninfratfstatesa` (the Terraform state backend, container `tfstate`, keys `homelab.<module>.tfstate`)
- SSH public key `homelab-vm-ssh-key-2` in `do-not-delete` (read by data source in `compute/vm`)

Design is "cattle VM, pet disk": destroying/recreating `compute/vm` is routine; the `infra/storage` disk and its data must always survive (cloud-init only formats the disk if unformatted).

## Local setup

- Azure auth: `ARM_*` env vars (`ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`) from the gitignored root `.env`
- Cloudflare: `TF_VAR_cloudflare_api_token` / `TF_VAR_cloudflare_zone_id`
- `infra/dns`, `infra/cloudflare`, `compute/vm` each need `terraform.tfvars` copied from `terraform.tfvars.example` (gitignored)

## Gotchas

- The NSG SSH rule whitelists the public IP of whatever machine runs plan/apply (fetched live from api.ipify.org) unless `ssh_source_ip` is set — local and CI plans always disagree on this rule.
- cloud-init contract (`compute/vm/cloud-init.yaml`): discovers the data disk at `/dev/disk/azure/scsi1/lun10`, mounts at `/data`. Changing the LUN in Terraform breaks it.
- The NS record name `az` in `infra/cloudflare/main.tf` is hardcoded and must match the subdomain label of `dns_zone_name`.
- GitHub secrets are split: network/storage/compute workflows use `ARM_*` secret names; dns/cloudflare use `AZURE_*` (plus `DNS_ZONE_NAME`, `RESOURCE_GROUP_NAME`, `CLOUDFLARE_*`). Both sets must exist. `_terraform.yml` implements the split with two mutually-exclusive `if:`-gated steps that set `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/`ARM_SUBSCRIPTION_ID`/`ARM_TENANT_ID` via `$GITHUB_ENV` — from `ARM_*` secrets for network/storage/compute, from `AZURE_*` secrets for `infra/dns`/`infra/cloudflare` — deliberately with no static `env:` entry of the same name anywhere in the job, since a static entry can silently win over a later `$GITHUB_ENV` write. Known inconsistency — don't standardize without asking (dies in E02.4).
- Apply gate is uniform (resolved by #28): all five module workflows run plan on push/PR and apply only via manual `workflow_dispatch` with the apply checkbox (default unchecked). No workflow auto-applies on push.
- `deploy.yml` is the overall pipeline: it calls the five `deploy-*.yml` workflows as reusable workflows (`workflow_call`, `secrets: inherit`) in dependency order. Its `apply_terraform` checkbox gates apply in every module job — unchecked = plan-only dry run across all five.
- `destroy.yml` tears down `compute/vm` → `infra/cloudflare` only. It deliberately skips `infra/storage` (the pet disk), `infra/network`, and `infra/dns`: the disk lives inside `homelab-rg`, so destroying the network module would delete (or fail on) the RG holding the disk, and VNet/subnet/NSG/RG stay up since they cost nothing; the DNS zone is a flat ~$0.52/month regardless of usage, so it's not worth tearing down every cycle — destroying it was also the direct cause of recurring plan failures in `infra/cloudflare`/`compute/vm`, which look it up by name via a data source with no tolerance for it being absent (#124). `apply_destroy` unchecked = dry run.
- Deploy and destroy share `concurrency: homelab-terraform` so they can't interleave.
- All five `deploy-*.yml` workflows are thin wrappers around `.github/workflows/_terraform.yml` (a `workflow_call`-only reusable workflow taking `working_directory`/`apply`/`ssh_source_ip`), each run under a `tf-<working_directory>` concurrency group. It pins the Terraform CLI version from the repo-root `.terraform-version` file and always runs `terraform validate`. Two per-module quirks live in `_terraform.yml` as `if: inputs.working_directory == ...` steps rather than the shared `env:` block: the `AZURE_*`/`ARM_*` credential split above, and `TF_VAR_rg_name` for `infra/dns` only — `rg_name` is also declared (default `homelab-rg`) by `infra/network`/`infra/storage`/`compute/vm`, so a static env entry would silently override their defaults too.
- `main` is force-mirrored to a public GitHub repo on every push (`mirror.yml`) — treat everything committed as public; never commit tfvars, keys, or `.env`.
- `docs/technical_reference.md` predates the dns/cloudflare modules — update `docs/` when adding or changing modules.
- `lint.yml` (tflint + checkov, both blocking) runs repo-wide on any `.tf` change, separate from the five per-module pipelines. `.tflint.hcl` is a single repo-root config covering all five modules via `tflint --recursive`. Checkov findings that are real but not fixable yet are silenced with an inline `# checkov:skip=<ID>:<reason>` comment placed *inside* the resource block (a comment above the `resource` line is out of the range checkov scans) — not a separate baseline file.

## Conventions

- Azure resource names: `homelab-*` kebab-case; Terraform resource labels: `homelab_*` snake_case; region `southindia`.
- Branches: snake_case topical names, PR into `main` (merge commits).
- Adding a VM: use `compute/vm`, pass the correct `dns_zone_name`. Static DNS records go in `infra/dns/main.tf`; VM A records are managed by the VM module itself.
