#!/usr/bin/env bash
# build.sh - generate single/docker-compose.yml, the single-file form of the
# compose bundle, from the development form ../docker-compose.yml.
#
# The two differ in one place: the config service. In the development form it
# runs the xmpp image with ./scripts, ./templates and ./Caddyfile mounted from
# this checkout; here it runs the ethora-compose-init image, which is the xmpp
# image with those files built in. Every other service already takes its
# scripts from the config volume, so nothing else changes and the generated
# file needs no other file on disk (a .env next to it is optional).
#
# Checked by deploy/scripts/tests/compose-bundle.test.sh (regenerate, expect
# no diff).
#   run: deploy/compose/single/build.sh [--check]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "$HERE/.." && pwd)"
SRC="$BUNDLE/docker-compose.yml"
OUT="$HERE/docker-compose.yml"
INIT_IMAGE_LINE='    image: ${ETHORA_COMPOSE_INIT_IMAGE:-docker.io/dappros/ethora-compose-init:2610}'

render() {
  cat <<'HDR'
# Ethora Core in one file. GENERATED from deploy/compose/docker-compose.yml by
# deploy/compose/single/build.sh; edit those, not this.
#
# Save this file as docker-compose.yml in an empty directory, next to a .env
# with at least:
#   ROOT_DOMAIN=chat.example.com     # api./app./xmpp./files. point at this host
#   ADMIN_EMAIL=you@example.com
# (or PUBLIC_URL=https://chat.example.com for everything on one address), then
#   docker compose up -d
# Every other setting of the bundle's .env.example may be added; secrets left
# out are generated on the first start and kept in the `secrets` volume, and
# the admin password is printed once by `docker compose logs config`.
# Platforms that take variables instead of a .env file pass the same names.
#
# Caddy always runs here (ports 80 and 443, Let's Encrypt); behind a proxy of
# your own, start with `docker compose up -d --scale caddy=0` and route the
# hosts as the guide below describes.
#
# The configuration is rendered by the ethora-compose-init image (the xmpp
# image plus the bundle's scripts and templates), which also hands every
# other service its start script through the `config` volume.
# Guide: https://github.com/dappros/ethora-install/tree/main/deploy/compose

HDR
  awk -v img="$INIT_IMAGE_LINE" '
    /^name:/ { body = 1 }
    !body { next }
    /^  [a-z][a-z0-9-]*:$/ { svc = $1 }
    svc == "config:" && /^    image:/ { print img; next }
    svc == "config:" && /^      - \.\/(scripts|templates|Caddyfile)[:\/]/ { next }
    svc == "caddy:" && /^    profiles:/ { next }
    { print }
  ' "$SRC"
}

check_generated() {
  if grep -nE '^\s+- \./' "$1"; then echo "[single] bind mounts from the working tree remain" >&2; return 1; fi
  grep -q 'ethora-compose-init' "$1" || { echo "[single] config does not run ethora-compose-init" >&2; return 1; }
}

if [ "${1:-}" = "--check" ]; then
  diff -u "$OUT" <(render) && check_generated "$OUT" && echo "[single] $OUT is up to date"
else
  render > "$OUT.tmp" && check_generated "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
  echo "[single] wrote $OUT ($(wc -c < "$OUT") bytes)"
fi
