# Builds a Caddy image with the Azure DNS plugin baked in — the official
# caddy:2.11.4 image ships with no DNS provider plugins, and this repo needs
# one (#39) for the *.az.snehasish-chakraborty.com wildcard cert's DNS-01
# challenge.
#
# Both stages are pinned to an exact tag on purpose: this repo's Dependabot
# config (.github/dependabot.yml) has no `docker` ecosystem, so nothing
# watches these tags for updates — bumping them is a manual, deliberate act.
FROM caddy:2.11.4-builder AS builder

# caddy-dns/azure@v0.6.0 is the latest tag as of writing. It authenticates to
# Azure DNS via libdns/azure, which falls back to a managed identity when
# tenant_id/client_id/client_secret are all left unset in the Caddyfile — see
# apps/caddy/Caddyfile. No credential file, no secret, ever, on this VM.
RUN xcaddy build --with github.com/caddy-dns/azure@v0.6.0

FROM caddy:2.11.4

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
