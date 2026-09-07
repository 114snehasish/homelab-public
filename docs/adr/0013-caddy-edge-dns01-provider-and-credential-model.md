# ADR-0013: Caddy edge — DNS-01 provider and credential model

- **Status**: Accepted
- **Date**: 2026-09-07
- **Deciders**: repo owner
- **Related**: [#39](https://github.com/114snehasish/homelab/issues/39) (E03.3, this issue) · [#16](https://github.com/114snehasish/homelab/issues/16) (E03, parent) · [#37](https://github.com/114snehasish/homelab/issues/37) · [#38](https://github.com/114snehasish/homelab/issues/38) · [ADR-0012](0012-workload-tiering-cidr-and-nsg-ownership.md) · [#98](https://github.com/114snehasish/homelab/issues/98) · [#99](https://github.com/114snehasish/homelab/issues/99)

## Context

Issue `#39` (E03.3), epic `#16`, and `docs/roadmap.md`'s stack-picks table all specified the
Cloudflare DNS plugin for Caddy's `*.az.snehasish-chakraborty.com` wildcard cert, with the
Cloudflare API token supplied via a VM-local `.env` file as a stated **temporary** measure (moved
to Key Vault in E05.3/E05.4).

**That design cannot work, verified rather than theorised.** `az.snehasish-chakraborty.com` is
delegated away from Cloudflare to Azure DNS (`infra/dns` creates the zone; `infra/cloudflare`
writes the NS delegation records). Queried directly, while planning this issue:

```
$ dig @carl.ns.cloudflare.com  TXT _acme-challenge.az.snehasish-chakraborty.com
;; flags: qr rd; QUERY: 1, ANSWER: 0, AUTHORITY: 4, ADDITIONAL: 1
;; AUTHORITY SECTION:
az.snehasish-chakraborty.com. 3600 IN NS ns1-08.azure-dns.com.
az.snehasish-chakraborty.com. 3600 IN NS ns2-08.azure-dns.net.
... (referral, not an answer — Cloudflare is not authoritative below the delegation)

$ dig @ns1-08.azure-dns.com    TXT _acme-challenge.az.snehasish-chakraborty.com
;; flags: qr aa rd ad; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 1
;; AUTHORITY SECTION:
az.snehasish-chakraborty.com. 300 IN SOA ns1-08.azure-dns.com. azuredns-hostmaster.microsoft.com. ...
... (aa flag: Azure DNS answers authoritatively)
```

A Cloudflare-authenticated DNS-01 challenge would write the ACME TXT record into a zone Let's
Encrypt's resolvers never consult when validating `*.az.snehasish-chakraborty.com` — the challenge
would fail every time, not intermittently.

## Decision

**Use `caddy-dns/azure` against the Azure DNS zone directly, authenticating as a VM-attached
user-assigned managed identity.** Not the CNAME-override alternative (a `_acme-challenge` CNAME in
Azure DNS pointing at a Cloudflare-hosted name, keeping the Cloudflare plugin) — that would have
been the smaller diff, staying inside the issue's original one-PR scope, but it keeps a Cloudflare
API token with `DNS:Edit` on the **root** zone (Cloudflare cannot scope a token to a subdomain
delegation) sitting on the internet-facing edge VM indefinitely, for a "temporary" arrangement that
this repo's own history shows tends to outlive its stated lifetime. The managed-identity path costs
more up front and removes the debt instead of scheduling it: no credential of any kind lives on the
VM, and there is nothing for E05.3/E05.4 to migrate for this identity.

**User-assigned, not system-assigned.** `compute/vm` is cattle — `destroy.yml` tears the edge node
down on every park cycle. A system-assigned identity dies with the VM and mints a new
`principal_id` on every recreate, which would break the DNS Zone Contributor role assignment each
time. A user-assigned identity, created once in `infra/identity` and attached by name, survives
recreation — `compute/vm` only ever looks it up and attaches it.

### What this costs

- **`infra/identity` gains a `data "azurerm_dns_zone"` lookup on `infra/dns`'s zone.** Every other
  data source in that module reads a resource pre-existing outside this repo (the state storage
  account, the SSH key, `homelab-rg`); this is the first one reading a resource another *root
  module in this repo* creates. Consequence: a from-scratch rebuild applies `infra/dns` before
  `infra/identity`, an ordering that didn't previously matter.
- **The CI identity gets one more role: `Managed Identity Operator`, scoped to the new UAMI only.**
  This is not a privilege escalation — CI already holds `Contributor` on `homelab-rg`, and the DNS
  zone lives in `homelab-rg`, so CI could already write records into it directly. The new grant only
  adds the `.../userAssignedIdentities/assign/action` needed to *attach* the identity to a VM in
  `compute/vm`'s Terraform. `Reader` is not sufficient for this — attaching a UAMI is a write on the
  `assign` action, and a `Reader`-only grant plans clean in `compute/vm` and then fails at apply
  with an authorization error naming neither "Reader" nor "assign".
- **`compute/vm` gains an `identity` block on the edge instance.** Verified before writing any code
  that this is an in-place update on this repo's pinned `azurerm ~> 5.0`, not a replacement (the
  provider fixed forcing a VM replacement for identity changes before 4.31) — confirmed empirically
  against the real `homelab-edge` VM: `terraform plan` showed `0 to add, 1 to change, 0 to destroy`,
  and `terraform apply` completed in 18 seconds with no VM restart.
- **IMDS reachability from a container was the one assumption that could have invalidated this
  approach, so it was checked first, against the real VM, before any Caddy code was written** — a
  container on a *custom* bridge network (`docker network create web`, the exact topology
  `apps/caddy` uses, not just the default bridge) reached
  `http://169.254.169.254/metadata/instance` and, after the identity was attached, received a real
  ARM access token scoped to `https://management.azure.com/` for that identity's `client_id`. Had
  this failed, the fallback would have been a host-side DNAT rule — deliberately not
  `network_mode: host`, which would remove Caddy from the shared `web` network every other app
  needs it reachable on.

## Consequences

- **Positive.** Zero credentials of any kind for the DNS-01 challenge live on the edge VM, in the
  repo, or in CI secrets. `apps/caddy/.env` holds two identifiers (`AZURE_SUBSCRIPTION_ID`,
  `AZURE_DNS_RESOURCE_GROUP`), not a token — E05.3/E05.4's Key Vault migration has nothing to do for
  this piece. The wildcard-cert/wildcard-DNS hostname-hygiene property (risk R6) is unaffected by
  this change; only the mechanism obtaining the cert changed.
- **Cost.** `infra/identity` now depends on `infra/dns` having applied first — a new, if narrow,
  cross-module ordering constraint in a repo whose modules are otherwise linked only by naming
  convention, never `terraform_remote_state` (see `CLAUDE.md`).
- **This overturns text already written down in three places** — the issue (`#39`) itself, epic
  `#16`'s decision log, and `docs/roadmap.md`'s stack-picks table. Rather than silently editing
  history, this ADR is the record of why; `docs/roadmap.md` is corrected in the same PR to point
  here instead of restating the old rationale.
- **The `#98`/`#99` ordering gate (`docs/roadmap.md`: *"E15's disk migration + mount contract land
  before E03.3"*) was deliberately crossed, not resolved by this ADR** — recorded in
  `docs/roadmap.md`'s E15/E03 ordering note and in the PR description, not here: that decision is
  about disk-migration risk, orthogonal to which DNS-01 provider Caddy uses.

## Open items

None — Section-5-style deferred measurement doesn't apply here; every claim above was verified
against the real subscription before this ADR was written, not projected.
