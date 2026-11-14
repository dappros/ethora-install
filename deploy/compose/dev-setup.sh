#!/usr/bin/env bash
# dev-setup.sh - write .env for a local stack built from this checkout's
# submodules: configure.sh with development answers, then the settings that
# switch on docker-compose.dev.yml. Every developer gets their own secrets.
# Nothing is built and nothing is started.
#
# Usage
#   ./dev-setup.sh                                      all modules but playground
#   ./dev-setup.sh --license-key ETHORA1.... --ai-api-key sk-...
#   ./dev-setup.sh --modules ai,push                    fewer modules
#
# Flags go to configure.sh and win over the defaults here. Re-running keeps the
# secrets, so it is safe on an existing stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

log() { echo "[dev-setup] $*"; }

[ -f "$SCRIPT_DIR/../../ethora-backend/services/api/Dockerfile" ] || {
  echo "[dev-setup] ERROR: submodules missing: run git submodule update --init --recursive" >&2
  exit 1
}

# playground stays off: it needs an app created in the admin panel first. No
# updater: these images are built from this checkout, not pulled.
ETHORA_SETUP_REGISTRY_CHECK=false "$SCRIPT_DIR/configure.sh" \
  --domain ethora.localhost \
  --admin-email admin@example.test \
  --display-name "Ethora Local" \
  --modules ai,push,mcp,uptime,calls \
  --local-certs \
  --no-updater \
  --yes "$@"

set_env() { # set_env KEY value: replaces the line, or adds one
  local key="$1" val="$2" tmp
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  grep -v "^$key=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

set_env COMPOSE_PROJECT_NAME ethora-local
set_env COMPOSE_FILE docker-compose.yml:docker-compose.dev.yml
for image in API FRONTEND XMPP AI PUSH PLAYGROUND MCP UPTIME; do
  name="$(printf '%s' "$image" | tr 'A-Z' 'a-z')"
  set_env "ETHORA_${image}_IMAGE" "ethora-$name:local"
done
set_env CRAWLER_ENABLED true
set_env CRAWLER_URL http://crawler:8000/crawl
grep -q '^CRAWLER_CALLBACK_SECRET=.' "$ENV_FILE" \
  || set_env CRAWLER_CALLBACK_SECRET "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"

log "wrote $ENV_FILE for docker-compose.dev.yml"
log "next: docker compose up -d --build"
