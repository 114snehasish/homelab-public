# Builds a Caddy image with the Azure DNS plugin baked in — the official
# caddy image ships with no DNS provider plugins, and this repo needs one (#39)
# for the *.az.snehasish-chakraborty.com wildcard cert's DNS-01 challenge.
#
# CI builds this, never the node (#40, PR B). apps-image.yml publishes it to
# GHCR at exactly the tag docker-compose.yml names, and the node pulls that.
#
# WHEN YOU CHANGE THIS FILE, BUMP THE TAG IN docker-compose.yml. Tags are
# immutable: the published image carries this file's sha256 as a label, and CI
# fails any PR whose Dockerfile no longer matches the image its tag points at.
# The tag is `<caddy version>-azuredns<plugin version>`, plus `-r<N>` for a
# rebuild with the same versions. apps/caddy/check.sh enforces that shape.
#
# Both stages are pinned to an exact tag on purpose, and to the SAME version:
# the binary comes from the builder stage, so a builder older than the runtime
# ships the older Caddy under the newer label. check.sh fails on a mismatch.
# Dependabot's `docker` ecosystem (.github/dependabot.yml) proposes FROM bumps,
# and it can bump one stage without the other when the -builder tag is
# published later; such a PR stays red until both lines and the tag agree.
# The plugin version is invisible to Dependabot (it is an xcaddy argument, not
# an image tag), so bumping it stays a manual, deliberate act.
FROM caddy:2.11.9-builder AS builder

# caddy-dns/azure@v0.6.0 is the latest tag as of writing. It authenticates to
# Azure DNS via libdns/azure, which falls back to a managed identity when
# tenant_id/client_id/client_secret are all left unset in the Caddyfile — see
# apps/caddy/Caddyfile. No credential file, no secret, ever, on this VM.
RUN xcaddy build --with github.com/caddy-dns/azure@v0.6.0

FROM caddy:2.11.9

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
