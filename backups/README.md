# Caddy cert/ACME backup (manual, interim)

`caddy-data/` is a plain `rsync` copy of the VM's `/data/caddy` — the whole
directory Caddy's `docker-compose.yml` volume-mounts (`/data/caddy/data`,
`/data/caddy/config`). It holds the Let's Encrypt wildcard cert + key for
`*.az.snehasish-chakraborty.com` and Caddy's ACME account key.

Last pulled: 2026-09-12, from `homelab-edge` (52.140.52.222) after a fresh
`deploy.yml` run recreated the VM. Cert validity at that time:
`notBefore=Sep 7 2026, notAfter=Dec 6 2026`.

This directory is gitignored — never committed. `main` is force-mirrored to a
public repo, and these files include private key material.

## Why this exists

Caddy (E03.3, #204) shipped writing real state to `/data` before E15's
tiered-persistence/backup layer (issue #96, ADR-0009, PR #216) landed. The
disk itself survives park/destroy cycles (`prevent_destroy` in
`infra/storage`), but there was no way to get a copy *off* the disk until now.
This is a manual stopgap — once ADR-0009's restic → Azure Blob automation
(children #98–#103) ships, this manual pull/restore step goes away.

## Restore (onto a fresh data disk, before Caddy's first start)

```
rsync -avz -e "ssh -i keys/azure_rsa" backups/caddy-data/ azureuser@<new_public_ip>:/data/caddy/
ssh -i keys/azure_rsa azureuser@<new_public_ip> 'sudo chown -R azureuser:azureuser /data/caddy'
```

Run this **before** `docker compose up -d` in `apps/caddy` on that disk —
Caddy will find the existing cert + ACME account under `/data/caddy/data` and
skip re-issuing against Let's Encrypt.
