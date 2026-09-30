#!/bin/sh
# frontend-start.sh - entrypoint of the frontend service in the compose bundle.
#
# The ethora-frontend image renders /config.js and the CSP from the VITE_*
# variables in its environment. Export the frontend.env the config service
# rendered (plain KEY=value lines, taken literally, the same as the docker
# --env-file that deploy/scripts/frontend-from-image.sh produces), then run
# the image's own entrypoint.
set -eu

ENV_FILE="${ETHORA_FRONTEND_ENV_FILE:-/ethora/config/frontend/frontend.env}"
[ -r "$ENV_FILE" ] || { echo "[frontend] $ENV_FILE missing; the config service did not run" >&2; exit 1; }

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *'{{'*) continue ;;
    [A-Za-z_]*=*)
      key="${line%%=*}"
      case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
      export "$line"
      ;;
  esac
done < "$ENV_FILE"

exec /usr/local/bin/ethora-frontend "$@"
