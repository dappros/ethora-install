#!/bin/bash
#
# admin-reset.sh - recover or manage the platform superadmin from the host.
#
# For installs without outbound email (no Postmark), or when the superadmin
# is locked out (lost password, lost authenticator, wrong seed address). The
# admin panel's "forgot password" and "reset password" need email to work;
# this does not.
#
# Usage (from the deploy directory of the live install):
#   sudo ./scripts/admin-reset.sh list
#   sudo ./scripts/admin-reset.sh show          --email admin@example.com
#   sudo ./scripts/admin-reset.sh create        --email ops@example.com
#   sudo ./scripts/admin-reset.sh set-password  --email ops@example.com
#   sudo ./scripts/admin-reset.sh temp-password --email ops@example.com
#   sudo ./scripts/admin-reset.sh set-email     --email admin@example.com --new-email ops@example.com
#   sudo ./scripts/admin-reset.sh clear-mfa     --email ops@example.com
#
# create / set-password generate a password and print it once unless one is
# given with --password <p> or ADMIN_RESET_PASSWORD=<p> in the environment
# (the environment keeps it out of shell history). temp-password prints a
# one-time password: the user logs in with it and the app asks for a new
# one. set-password and temp-password end the user's open sessions.
#
# --app <slug> selects another base app; the default is the install's base
# app slug from deploy.yml. --json gives a machine-readable result.
#
# Works in both backend modes: source (node on the host, backend dir from
# deploy.yml) and image (runs inside the API image with the rendered .env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CANONICAL_DEPLOY_CONFIG_FILE:-$DEPLOY_DIR/config/deploy.yml}"
ENV_FILE="$DEPLOY_DIR/.deploy.env"

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }
[ $# -ge 1 ] || { usage; exit 2; }
case "$1" in -h|--help|help) usage; exit 0 ;; esac

[ -f "$CONFIG_FILE" ] || { echo "admin-reset: $CONFIG_FILE not found; run from the deploy directory of an installed system" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "admin-reset: yq is required" >&2; exit 1; }

cfg() { # cfg <yq path> [default]
    local v
    v="$(yq eval "$1 // \"\"" "$CONFIG_FILE" 2>/dev/null || true)"
    [ "$v" = "null" ] && v=""
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "${2:-}"
}

# .deploy.env carries the resolved paths (TARGET_DIR, BACKEND_DIR) written by
# install.sh; fall back to deploy.yml paths for an install that predates it.
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi
BACKEND_MODE="$(cfg '.services.backend.mode' "${BACKEND_MODE:-source}")"
ETHORA_API_IMAGE="$(cfg '.services.backend.image' "${ETHORA_API_IMAGE:-}")"
BASE_DIR="${TARGET_DIR:-$(cfg '.paths.base' "$(cd "$DEPLOY_DIR/.." && pwd)")}"
BACKEND_API_DIR="${BACKEND_API_DIR:-${BACKEND_DIR:-$BASE_DIR/ethora-backend}/services/api}"

# Base app slug: deploy.yml, else derived from the web host like install.sh does.
BASE_APP_SLUG="$(cfg '.base_app.domain_name' "${BASE_APP_DOMAIN_NAME:-}")"
if [ -z "$BASE_APP_SLUG" ]; then
    WEB_HOST="$(cfg '.domains.web' "${WEB_DOMAIN:-}")"
    if [ -z "$WEB_HOST" ] || [ "$WEB_HOST" = "localhost" ]; then BASE_APP_SLUG="ethora"; else BASE_APP_SLUG="${WEB_HOST%%.*}"; fi
fi
ARGS=("$@")
case " $* " in *" --app "*) ;; *) ARGS+=(--app "$BASE_APP_SLUG") ;; esac

SCRIPT="scripts/deploy/admin-reset.js"
if [ "$BACKEND_MODE" = "image" ]; then
    [ -n "$ETHORA_API_IMAGE" ] || { echo "admin-reset: services.backend.image is empty in $CONFIG_FILE" >&2; exit 1; }
    [ -f "$BACKEND_API_DIR/.env" ] || { echo "admin-reset: rendered env $BACKEND_API_DIR/.env not found" >&2; exit 1; }
    exec docker run --rm --network host -i \
        --env-file "$BACKEND_API_DIR/.env" \
        -e NODE_NO_WARNINGS=1 -e NODE_OPTIONS=--no-deprecation \
        ${ADMIN_RESET_PASSWORD:+-e ADMIN_RESET_PASSWORD} \
        "$ETHORA_API_IMAGE" script "$SCRIPT" "${ARGS[@]}"
fi

[ -f "$BACKEND_API_DIR/$SCRIPT" ] || { echo "admin-reset: $BACKEND_API_DIR/$SCRIPT not found (backend older than this script, or wrong paths in $ENV_FILE)" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "admin-reset: node is required on the host in source mode" >&2; exit 1; }
cd "$BACKEND_API_DIR"
# Prefer the compiled copy under dist/ (src/helpers is TypeScript; the script
# requires ../src), then ts-node's require hook, then plain node.
if [ -f "dist/$SCRIPT" ]; then
    exec env NODE_NO_WARNINGS=1 NODE_OPTIONS=--no-deprecation node "dist/$SCRIPT" "${ARGS[@]}"
elif [ -f node_modules/ts-node/register/transpile-only.js ]; then
    exec env NODE_NO_WARNINGS=1 NODE_OPTIONS=--no-deprecation node -r ts-node/register/transpile-only "$SCRIPT" "${ARGS[@]}"
fi
exec env NODE_NO_WARNINGS=1 NODE_OPTIONS=--no-deprecation node "$SCRIPT" "${ARGS[@]}"
