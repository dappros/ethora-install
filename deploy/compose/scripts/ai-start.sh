#!/bin/sh
# ai-start.sh - entrypoint of the ai module's containers in the compose
# bundle (the ethora-ai image: ai-service, docs-parse, widget-export, ai-init).
#
# Exports the env file the config service rendered for the command (plain
# KEY=value lines; the ai module's templates quote nothing) and hands over to
# the image's own entrypoint (deploy/docker/ai-entrypoint.sh):
#
#   ai-start.sh ai-service            ai/ai-service.env
#   ai-start.sh docs-parse            ai/docs-parse.env
#   ai-start.sh widget-export <dir>   widget/widget.env; renders the widget bundle
#                                     into <dir> and makes it world-readable
#   ai-start.sh pg-schema             ai/ai-service.env; creates the pgvector
#                                     schema (scripts/ai-pg-schema.js), idempotent
set -eu

CONFIG="${ETHORA_CONFIG_DIR:-/ethora/config}"
log() { echo "[ai] $*"; }
die() { echo "[ai] ERROR: $*" >&2; exit 1; }

load() { # load <env file>: export every KEY=value line (the environment wins)
  [ -r "$1" ] || die "$1 is missing or unreadable; the config service did not run with the ai module on"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      [A-Za-z_]*=*)
        key="${line%%=*}"
        case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
        eval "[ -n \"\${$key+x}\" ]" && continue
        export "$line"
        ;;
    esac
  done < "$1"
}

cmd="${1:-ai-service}"; shift || true
case "$cmd" in
  ai-service)
    load "$CONFIG/ai/ai-service.env"
    exec /usr/local/bin/ethora-ai ai-service ;;
  docs-parse)
    load "$CONFIG/ai/docs-parse.env"
    exec /usr/local/bin/ethora-ai docs-parse ;;
  widget-export)
    out="${1:-/widget}"
    load "$CONFIG/widget/widget.env"
    /usr/local/bin/ethora-ai widget-export "$out"
    # Written as root into the widget volume; the widget service reads it.
    chmod -R a+rX "$out" ;;
  pg-schema)
    load "$CONFIG/ai/ai-service.env"
    [ -n "${PG_URL:-}" ] || die "PG_URL is empty in ai-service.env"
    # Postgres (bundled or external) may still be starting.
    attempt=1
    until AI_PG_URL="$PG_URL" AI_PG_APP_DIR=/app/ai-service AI_PG_MIGRATIONS_DIR=/app/ai-service/drizzle \
          node "$(dirname "$0")/ai-pg-schema.js"; do
      [ "$attempt" -lt 20 ] || die "could not initialise the AI Postgres schema at ${PG_URL#*@} after $attempt attempts"
      log "Postgres at ${PG_URL#*@} not ready; retrying in 5 s (attempt $((attempt + 1)) of 20)"
      attempt=$((attempt + 1)); sleep 5
    done ;;
  *)
    exec /usr/local/bin/ethora-ai "$cmd" "$@" ;;
esac
