#!/bin/sh
# Ethora push image entrypoint.
#   ethora-push server   HTTP API (PORT / PUSH_PORT from /app/push/.env)
#   ethora-push worker   queue worker
set -eu
cmd="${1:-server}"
[ $# -gt 0 ] && shift
case "$cmd" in
  server) exec node /app/loader.js /app/push ./server "$@" ;;
  worker) exec node /app/loader.js /app/push ./worker "$@" ;;
  *) exec "$cmd" "$@" ;;
esac
