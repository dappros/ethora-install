#!/bin/sh
# module-start.sh - entrypoint of the push, playground, mcp and uptime module
# containers in the compose bundle. Exports the env file the config service
# rendered for the module (plain KEY=value lines), plus the base app's API
# credentials that init.sh leaves in base-app/credentials.env for the modules
# that drive the API as a B2B client, and hands over to the image's own start.
#
#   module-start.sh push server|worker   push/push.env         -> ethora-push
#   module-start.sh playground           playground/playground.env + base app -> ethora-playground
#   module-start.sh mcp                  mcp/mcp.env           -> node /app/dist/index.js
#   module-start.sh uptime               uptime/uptime.env + base app -> node dist/server.js
set -eu

CONFIG="${ETHORA_CONFIG_DIR:-/ethora/config}"
log() { echo "[module] $*"; }
die() { echo "[module] ERROR: $*" >&2; exit 1; }

load() { # load <env file>: export every KEY=value line (the environment wins)
  [ -r "$1" ] || die "$1 is missing or unreadable; the config service did not run with this module on"
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

# The base app's id and secret, written by init.sh after the first boot.
base_app() {
  f="$CONFIG/base-app/credentials.env"
  for i in $(seq 1 60); do [ -s "$f" ] && break; [ "$i" = 60 ] && die "$f not written yet (did init finish? docker compose logs init)"; sleep 5; done
  load "$f"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  push)
    load "$CONFIG/push/push.env"
    exec /usr/local/bin/ethora-push "${1:-server}" ;;
  playground)
    load "$CONFIG/playground/playground.env"
    base_app
    exec /usr/local/bin/ethora-playground ;;
  mcp)
    load "$CONFIG/mcp/mcp.env"
    exec node /app/dist/index.js ;;
  uptime)
    load "$CONFIG/uptime/uptime.env"
    base_app
    # The journeys and the push check sign in as the base app.
    export ETHORA_B2B_APP_ID="${ETHORA_B2B_APP_ID:-$ETHORA_CHAT_APP_ID}" ETHORA_B2B_APP_SECRET="${ETHORA_B2B_APP_SECRET:-$ETHORA_CHAT_APP_SECRET}"
    cd /app && exec node dist/server.js ;;
  *)
    die "usage: module-start.sh push server|worker | playground | mcp | uptime" ;;
esac
