#!/bin/bash
# init.sh - the `init` service of the compose bundle: the first-boot steps
# the host installer runs in deploy/scripts/init-services.sh and
# run-migrations.sh, through the API image's script mode.
#
# Runs on every `docker compose up` after the API is healthy, and every step
# is idempotent, so a second run changes nothing:
#   1. base app + platform admin        scripts/initEthoraApp.js (exits 0 when present)
#   2. ejabberd accounts of the base    scripts/deploy/xmpp-app-lookup.js, then
#      app owner and system account     register / change_password over ejabberd's HTTP API
#   3. data migrations                  scripts/migrateSourceAgentId.js (re-runnable by design)
#   4. translation server languages     src/utils/scripts/syncTranslateLanguages.js
#
# The environment is backend.env, loaded by api-entrypoint.sh. The ejabberd
# admin account itself is created by the xmpp container (xmpp-start.sh).
set -uo pipefail

log()  { echo "[init] $*"; }
warn() { echo "[init] WARN: $*" >&2; }
die()  { echo "[init] ERROR: $*" >&2; exit 1; }

script() { NODE_NO_WARNINGS=1 NODE_OPTIONS="--no-deprecation" node /app/dist/start.js script "$@"; }

: "${MONGO_URI:?MONGO_URI missing from backend.env}"
: "${XMPP_HOST:?XMPP_HOST missing from backend.env}"
: "${XMPP_PASS:?XMPP_PASS missing from backend.env}"
XMPP_API="${XMPP_PATH:-http://xmpp:5280/api}"
API_URL="${API_INTERNAL_URL:-http://api:8080}"

# initEthoraApp.js reads these names (init-services.sh exports the same).
export PLATFORM_ACCOUNT_EMAIL="${PLATFORM_ACCOUNT_EMAIL:?}"
export BASE_APP_OWNER_EMAIL="${BASE_APP_OWNER_EMAIL:-$PLATFORM_ACCOUNT_EMAIL}"
export BASE_APP_OWNER_PASSWORD="${BASE_APP_OWNER_PASSWORD:-$PLATFORM_ACCOUNT_PASSWORD}"
export JWT_SECRET="${SECRET_KEY:-}"

# ----------------------------------------------------------- 1. base app --
# The API seeds the same base app on its own start (config/init.js), so the
# two can race on a slow host: initEthoraApp.js finds no app, the API inserts
# it, and the script's insert then fails on the unique domainName. A second
# attempt takes the "already exists" path, so retry a few times.
log "base app '${BASE_APP_DOMAIN_NAME:-}' and platform admin ${PLATFORM_ACCOUNT_EMAIL}"
attempt=1
until script scripts/initEthoraApp.js; do
  rc=$?
  [ $attempt -lt 4 ] || die "initEthoraApp.js failed (exit $rc) after $attempt attempts"
  log "initEthoraApp.js failed (exit $rc); retrying in 5 s (attempt $((attempt + 1)) of 4)"
  attempt=$((attempt + 1)); sleep 5
done

# ------------------------------------------------------ 2. xmpp accounts --
# ejabberd's HTTP API, authenticated as admin@<xmpp host> (the account the
# xmpp container registers on start and the backend uses the same way).
xmpp_api() { # xmpp_api <command> <json>
  curl -sS --max-time 10 -u "admin@${XMPP_HOST}:${XMPP_PASS}" \
    -H 'Content-Type: application/json' -X POST -d "$2" "$XMPP_API/$1"
}
json_str() { node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"; }

ensure_xmpp_account() { # ensure_xmpp_account <localpart or jid> <password> <label>
  local user="${1%%@*}" pass="$2" label="$3" u p h out
  [ -n "$user" ] && [ -n "$pass" ] || { warn "no XMPP credentials for the $label; skipped"; return 0; }
  u="$(json_str "$user")"; p="$(json_str "$pass")"; h="$(json_str "$XMPP_HOST")"
  out="$(xmpp_api check_account "{\"user\":$u,\"host\":$h}")"
  if [ "$out" = "0" ]; then
    out="$(xmpp_api change_password "{\"user\":$u,\"host\":$h,\"newpass\":$p}")"
    [ "$out" = "0" ] && { log "xmpp account of the $label present (password ensured)"; return 0; }
  else
    out="$(xmpp_api register "{\"user\":$u,\"host\":$h,\"password\":$p}")"
    case "$out" in *successfully*|*registered*) log "xmpp account of the $label created"; return 0 ;; esac
  fi
  warn "xmpp account of the $label: unexpected answer from ejabberd: $(printf '%s' "$out" | head -c 200)"
  return 1
}

# The admin account can lag the xmpp healthcheck by a few seconds.
for i in $(seq 1 60); do
  [ "$(xmpp_api check_account "{\"user\":\"admin\",\"host\":$(json_str "$XMPP_HOST")}" 2>/dev/null)" = "0" ] && break
  [ "$i" = 60 ] && die "ejabberd HTTP API at $XMPP_API does not accept admin@$XMPP_HOST (see: docker compose logs xmpp)"
  sleep 2
done

lookup_err="$(mktemp)"
lookup="$(script scripts/deploy/xmpp-app-lookup.js "$MONGO_URI" "${BASE_APP_DOMAIN_NAME:-}" "$PLATFORM_ACCOUNT_EMAIL" 2>"$lookup_err")" \
  || die "xmpp-app-lookup.js failed: $(tail -n 5 "$lookup_err")"
rm -f "$lookup_err"
field() { printf '%s\n' "$lookup" | sed -n "s/^ETHORA_XMPP_$1_B64=//p" | head -n 1 | base64 -d 2>/dev/null; }
rc=0
ensure_xmpp_account "$(field OWNER_USERNAME)" "$(field OWNER_PASSWORD)" "base app owner" || rc=1
ensure_xmpp_account "$(field SYSTEM_JID)" "$(field SYSTEM_PASSWORD)" "base app system account" || rc=1
[ "$rc" = 0 ] || die "could not provision the base app's xmpp accounts"

# ---------------------------------------------------------- 3. migrations --
# run-migrations.sh's list. Each one is idempotent and re-runnable, so no
# stamp files are kept.
for m in scripts/migrateSourceAgentId.js; do
  log "migration $m"
  script "$m" 2>&1 | sed 's/^/[init]   /' || warn "migration $m failed (non-fatal)"
done

# ---------------------------------------------------- 4. translate languages --
if out="$(script src/utils/scripts/syncTranslateLanguages.js "${TRANSLATE_LANGUAGES:-}" 2>&1)"; then
  log "translate languages: $(printf '%s' "$out" | tail -n 1)"
else
  warn "translate language sync failed (non-fatal): $(printf '%s' "$out" | tr '\n' ' ' | head -c 240)"
fi

# ----------------------------------------------------------------- done --
if curl -fsS --max-time 5 "$API_URL/v1/apps/get-config?domainName=${BASE_APP_DOMAIN_NAME:-}" >/dev/null 2>&1; then
  log "base app config served by the API"
else
  warn "GET /v1/apps/get-config?domainName=${BASE_APP_DOMAIN_NAME:-} did not answer yet"
fi
log "done. Web app: ${DEFAULT_APP_URL:-https://app.<root>}  admin: ${PLATFORM_ACCOUNT_EMAIL}"
