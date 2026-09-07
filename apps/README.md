# Runbook: Deploying the Apps Layer

## The pattern

`apps/` is one directory per app. Each app directory holds:

- A `docker-compose.yml` — one service (or a small related group), joined to the shared external
  `web` Docker network.
- Persistent state under `/data/<app>` on the VM's data disk — never inside the container, never
  on the OS disk. `apps/caddy` writes to `/data/caddy`; a future app writes to `/data/<its-name>`.
- A route added inside Caddy's **one** wildcard site block in `apps/caddy/Caddyfile` — never a new
  Caddy site block of its own. See that file's header comment for why (risk R6: the repo is
  force-mirrored to a public GitHub repo on every push to `main`, and a second site block would
  leak that app's hostname into public Certificate Transparency logs).

`apps/caddy` is the first app in this layer, and it is special: it is the edge every other app's
traffic passes through, so it exists before any real app does (E03.3, `#39`). Real apps land in
E03.5/E03.6.

## Why this is manual today

Everything else in this repo deploys through GitHub Actions. `apps/**` does not yet — CI deploy
(`rsync` + `docker compose up -d`, path-filtered on `apps/**`) is E03.4 (`#40`), a separate PR.
Until then, this file is the deploy mechanism: read it top to bottom the first time, then treat
Step 3 onward as the repeatable loop for every change.

**`apps/**` triggers no CI check today.** `lint.yml` filters on `**/*.tf`, and its checkov job is
pinned to `framework: terraform` — neither reads a compose file or a Caddyfile. A PR touching only
`apps/` gets no lint, no plan comment, nothing but a human review. Keep that in mind reading a
green PR check: it proves the Terraform half of a change, never the apps half.

## What Caddy needs before it can run

Caddy authenticates to Azure DNS for the ACME DNS-01 challenge as the VM's attached **user-assigned
managed identity** (`homelab-edge-dns-identity`, created by `infra/identity`, granted `DNS Zone
Contributor` on the `az.snehasish-chakraborty.com` zone only — see ADR-0013). There is no
Cloudflare token and no service-principal secret involved: `az.snehasish-chakraborty.com` is
delegated away from Cloudflare to Azure DNS, so a Cloudflare-authenticated DNS-01 challenge would
write the ACME TXT record somewhere Let's Encrypt never looks. `compute/vm` attaches this identity
only to the instance with `public_edge = true` — the edge node's Terraform plan must show that
identity attached before Caddy is deployed here, or the container has nothing to authenticate as.

## Step 1 — create the shared network (once per VM)

```bash
ssh azureuser@<public_ip> 'docker network create web'
```

Idempotent-ish: if it already exists, Docker errors with `network with name web already exists`,
which is fine — nothing to do. Every app's compose file, including Caddy's, declares `web` as
`external: true` rather than creating it, so exactly one app doesn't get to own the network's
lifecycle.

## Step 2 — copy `.env` onto the VM (first deploy, or after rotating a value)

`apps/caddy/.env` is never committed — `.gitignore` excludes `apps/**/*.env` (with a
`!apps/**/*.env.example` negation for the committed template). Copy `.env.example`, fill in the
two identifiers, and get it onto the VM out-of-band of `rsync` (which this repo's `.gitignore`
pattern for `apps/**/*.env` will otherwise correctly, and unhelpfully, also make `rsync --exclude`
redundant to think about — just `scp` it directly instead):

```bash
cp apps/caddy/.env.example apps/caddy/.env
# edit apps/caddy/.env: fill in AZURE_SUBSCRIPTION_ID (see: az account show --query id -o tsv)
scp apps/caddy/.env azureuser@<public_ip>:/home/azureuser/apps/caddy/.env
ssh azureuser@<public_ip> 'chmod 600 /home/azureuser/apps/caddy/.env'
```

**Assert:** `ssh azureuser@<public_ip> 'stat -c "%a %n" /home/azureuser/apps/caddy/.env'` prints
`600 /home/azureuser/apps/caddy/.env`. This file holds identifiers, not a secret — but it stays out
of the public mirror on principle, same as every other `.env` in this repo.

## Step 3 — deploy (this is the repeatable loop)

```bash
rsync -av --exclude='.env' apps/caddy/ azureuser@<public_ip>:/home/azureuser/apps/caddy/
ssh azureuser@<public_ip> 'cd apps/caddy && docker compose up -d --build'
```

`--exclude='.env'` is belt-and-suspenders: `.env` is gitignored so a plain `rsync -av` of a local
checkout would not send it anyway, but excluding it explicitly means this command is still correct
run from a directory where that assumption ever stops holding.

## Step 4 — watch it obtain the certificate

```bash
ssh azureuser@<public_ip> 'cd apps/caddy && docker compose logs -f caddy'
```

**When it goes wrong:**

- **`unable to get ACME account`, or the DNS provider errors with an auth failure** — the identity
  isn't attached, or the role assignment hasn't propagated yet (a few minutes after `infra/identity`
  apply, occasionally). Confirm from a container on the same network Caddy runs on:
  `docker run --rm --network web curlimages/curl -s -H "Metadata:true" 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/'`
  should return a JSON blob with an `access_token` field, not an error.
- **Stuck waiting on the DNS-01 TXT record to propagate** — Azure DNS is typically fast (seconds),
  but Let's Encrypt's own resolvers add their own delay. Give it a minute before assuming it hung.
- **`no such host` / IMDS unreachable at all from inside the container** — this would mean the
  container can't reach `169.254.169.254`, which was verified working on the `web` network before
  this file was written. If it now fails, something changed about the network setup (e.g. a
  non-default Docker network driver) — do not switch to `network_mode: host` to route around it,
  that breaks every app's ability to sit behind Caddy on the shared network. Fix the route instead.

## Step 5 — verify

```bash
ls /data/caddy/data/caddy/certificates/          # wildcard cert + key present
curl -v https://test.az.snehasish-chakraborty.com  # 200 "caddy edge ok", TLS verifies, no -k needed
```

The R6 proof — that this is genuinely one wildcard cert and not a per-host one — is in the
certificate itself, not just in `curl` succeeding:

```bash
openssl s_client -connect test.az.snehasish-chakraborty.com:443 -servername test.az.snehasish-chakraborty.com </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
```

Expect exactly `DNS:*.az.snehasish-chakraborty.com`. Anything more specific means a hostname leaked
into the cert — check the Caddyfile for an accidental second site block before anything else.

**Persistence check** (cheap version — a full VM-recreate check is the `verify-persistence` skill,
worth running only after `#99` lands the new mount contract):

```bash
ssh azureuser@<public_ip> 'cd apps/caddy && docker compose down && docker compose up -d'
ssh azureuser@<public_ip> 'cd apps/caddy && docker compose logs caddy' | grep -i acme
```

Expect the cert to load from `/data` with no new ACME order — Caddy logs loading an existing
certificate, not requesting one.

## Adding a real app

1. `mkdir apps/<name>`, add its `docker-compose.yml` (join network `web`, mount its state under
   `/data/<name>`).
2. Add a `handle` block to the **existing** wildcard site in `apps/caddy/Caddyfile`, keyed by a
   `host` matcher for `<name>.az.snehasish-chakraborty.com` — proxying to the app's container name
   on the `web` network (e.g. `reverse_proxy <name>:8080`). Do not add a new top-level site block.
3. Deploy the app's own compose stack (Step 3's pattern, its own directory), then redeploy Caddy so
   the new route takes effect: `docker compose up -d` picks up a changed, bind-mounted Caddyfile
   without a rebuild.
4. Verify the same way as Step 5 above, plus that the wildcard cert's SAN is unchanged — adding a
   route must never add a hostname to the certificate.
