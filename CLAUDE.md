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
- GitHub secrets are split: network/storage/compute workflows use `ARM_*` secret names; dns/cloudflare use `AZURE_*` (plus `DNS_ZONE_NAME`, `RESOURCE_GROUP_NAME`, `CLOUDFLARE_*`). Both sets must exist. Known inconsistency — don't standardize without asking.
- Apply gate is uniform (resolved by #28): all five module workflows run plan on push/PR and apply only via manual `workflow_dispatch` with the apply checkbox (default unchecked). No workflow auto-applies on push.
- `deploy.yml` is the overall pipeline: it calls the five `deploy-*.yml` workflows as reusable workflows (`workflow_call`, `secrets: inherit`) in dependency order. Its `apply_terraform` checkbox gates apply in every module job — unchecked = plan-only dry run across all five.
- `destroy.yml` tears down `compute/vm` → `infra/cloudflare` → `infra/dns` only. It deliberately skips `infra/storage` (the pet disk) **and** `infra/network`: the disk lives inside `homelab-rg`, so destroying the network module would delete (or fail on) the RG holding the disk. VNet/subnet/NSG/RG stay up — they cost nothing. `apply_destroy` unchecked = dry run.
- Deploy and destroy share `concurrency: homelab-terraform` so they can't interleave.
- `main` is force-mirrored to a public GitHub repo on every push (`mirror.yml`) — treat everything committed as public; never commit tfvars, keys, or `.env`.
- `docs/technical_reference.md` predates the dns/cloudflare modules — update `docs/` when adding or changing modules.

## Conventions

- Azure resource names: `homelab-*` kebab-case; Terraform resource labels: `homelab_*` snake_case; region `southindia`.
- Branches: snake_case topical names, PR into `main` (merge commits).
- Adding a VM: use `compute/vm`, pass the correct `dns_zone_name`. Static DNS records go in `infra/dns/main.tf`; VM A records are managed by the VM module itself.
