#!/bin/sh
# render-config.sh - the `config` service of the compose bundle.
#
# Renders every config file the stack reads from the operator's settings
# (.env, or the variables a platform passes in), using the same templates
# the host installer renders (deploy/scripts/setup-env.sh,
# deploy/scripts/setup-ejabberd-config.sh):
#
#   /out/config/api/backend.env            <- templates/backend.env.template
#   /out/config/frontend/frontend.env      <- templates/frontend.env.template
#   /out/config/centrifugo/config.json     <- templates/centrifugo-config.json.template
#   /out/config/xmpp/ejabberd.yml, jwt.key <- /ethora-dist/ejabberd-prod.yml (from the xmpp image)
#   /out/config/caddy/Caddyfile            <- /ethora/Caddyfile
#   /out/config/mysql, /out/config/minio   <- the database credentials, as *_FILE secrets
#   /out/config/scripts/                   <- the bundle's scripts, which every other service runs
#   /out/mysql-initdb/01-ejabberd.sql      <- /ethora-dist/mysql2.sql (from the xmpp image)
#
# It runs in the ethora-xmpp image (development form, scripts bind-mounted)
# or in the ethora-compose-init image, which is the xmpp image plus this
# directory (single-file form); either way the ejabberd template and schema
# come from the xmpp release that is about to run. It runs on every
# `docker compose up` and rewrites everything; the rendered files are
# disposable.
#
# Secrets: a secret given in the environment wins. One left empty is taken
# from /out/secrets/secrets.env (the `secrets` volume) or, on the first start,
# generated there, so a compose file with nothing but ROOT_DOMAIN and
# ADMIN_EMAIL is a complete install.
#
# Two routing modes, chosen by PUBLIC_URL:
#   unset  four hosts, api./app./xmpp./files.<ROOT_DOMAIN>, TLS by Caddy
#          (the host installer's layout).
#   set    one origin, e.g. https://chat.example.com or http://nas.local:8420
#          (appliances: Umbrel, CasaOS): Caddy routes by path, and the web
#          app takes its API / XMPP / Centrifugo URLs from the address the
#          browser used.
#
# Internal endpoints default to the compose service names; the Helm chart and
# installs with external databases override them (all optional):
#   ETHORA_MONGO_URI, ETHORA_CHAT_DATABASE_URI   Mongo, app data and chat archive
#   ETHORA_REDIS_HOST, ETHORA_REDIS_PORT         Redis (no password: the API has none)
#   ETHORA_MYSQL_HOST, ETHORA_MYSQL_PORT, ETHORA_MYSQL_USER
#                                                ejabberd's SQL store; the password is
#                                                MYSQL_ROOT_PASSWORD whatever the user
#   ETHORA_MINIO_HOST, ETHORA_MINIO_PORT         S3-compatible storage over plain HTTP
#   ETHORA_MYSQL_DATABASE                        default ejabberd_db
#   ETHORA_CENTRIFUGO_URL, ETHORA_XMPP_URL, ETHORA_API_URL, ETHORA_FRONTEND_URL
#                                                http://centrifugo:8000, http://xmpp:5280,
#                                                http://api:8080, http://frontend:8080
# and, for a host that is not compose (the Cloudron package):
#   ETHORA_SITE_ADDRESS    the one-origin site's Caddy address, e.g. :3000
#                          behind a proxy that terminates TLS itself
#   ETHORA_EXTRA_SITES     more Caddy site blocks, appended as they are
#   API_UID, XMPP_UID, CENTRIFUGO_UID, MYSQL_UID, MINIO_UID, FRONTEND_UID
#                          owners of the rendered files (the images' users)
#
# Differences from the host installer, all because the services talk over the
# compose network instead of the host's loopback:
#   - backend.env: MONGO_URI, CHAT_DATABASE, REDIS_HOST, MINIO_HOST,
#     MAM_MYSQL_HOST, CENTRIFUGO_API_URL and XMPP_PATH point at the compose
#     service names (mongo, redis, minio, mysql, centrifugo, xmpp).
#   - ejabberd.yml: the tracking / audit URLs point at http://api:8080
#     instead of the public https://api.<root>, so ejabberd never hairpins
#     through the proxy.
#   - BUILD_* stay empty, so the version baked into each image is reported.
set -eu

TEMPLATES="${TEMPLATES_DIR:-/ethora/templates}"
CADDYFILE_TEMPLATE="${CADDYFILE_TEMPLATE:-/ethora/Caddyfile}"
SCRIPTS_SRC="$(cd "$(dirname "$0")" && pwd)"
DIST="${XMPP_DIST_DIR:-/ethora-dist}"
OUT="${CONFIG_OUT_DIR:-/out/config}"
SECRETS_DIR="${SECRETS_DIR:-/out/secrets}"
MYSQL_INITDB="${MYSQL_INITDB_DIR:-/out/mysql-initdb}"
# Numeric owners of the consumers (the stock images' users). Rendering as
# root, each file is handed to the one container user that reads it.
API_UID="${API_UID:-1000}"          # ethora-api: node
XMPP_UID="${XMPP_UID:-9000}"        # ethora-xmpp: ejabberd
CENTRIFUGO_UID="${CENTRIFUGO_UID:-1000}"
MYSQL_UID="${MYSQL_UID:-999}"       # mysql: mysql
MINIO_UID="${MINIO_UID:-0}"         # minio: root
FRONTEND_UID="${FRONTEND_UID:-0}"   # ethora-frontend: root

log() { echo "[config] $*"; }
die() { echo "[config] ERROR: $*" >&2; exit 1; }

# -------------------------------------------------------------- secrets --
SECRETS_FILE="$SECRETS_DIR/secrets.env"
store=""
if mkdir -p "$SECRETS_DIR" 2>/dev/null && touch "$SECRETS_FILE" 2>/dev/null; then
  chmod 700 "$SECRETS_DIR"; chmod 600 "$SECRETS_FILE"
  store=1
fi
rand() { tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$1"; }
stored() { [ -n "$store" ] && sed -n "s/^$1=//p" "$SECRETS_FILE" | head -n 1; }
record() {
  awk -v k="$1" 'index($0, k "=") != 1' "$SECRETS_FILE" > "$SECRETS_FILE.tmp"
  printf '%s=%s\n' "$1" "$2" >> "$SECRETS_FILE.tmp"
  mv "$SECRETS_FILE.tmp" "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
}
missing=""; generated=""
secret() { # secret NAME LENGTH [PREFIX]: environment > secrets volume > generated
  eval "cur=\${$1:-}"
  old="$(stored "$1" || true)"
  if [ -n "$cur" ]; then val="$cur"
  elif [ -n "$old" ]; then val="$old"
  elif [ -n "$store" ]; then val="${3:-}$(rand "$2")"; generated="$generated $1"
  else missing="$missing $1"; return 0
  fi
  export "$1=$val"
  if [ -n "$store" ] && [ "$val" != "$old" ]; then record "$1" "$val"; fi
}
secret ADMIN_PASSWORD 20
secret JWT_SECRET 64
secret REFRESH_SECRET 64
secret XMPP_JWT_SECRET 64
secret XMPP_SECRET 32
secret XMPP_ADMIN_PASSWORD 24
secret INTERNAL_REQUESTS_SECRET 32
secret MYSQL_ROOT_PASSWORD 32
secret MINIO_ROOT_USER 12 ethora-
secret MINIO_ROOT_PASSWORD 32
secret CENTRIFUGO_API_KEY 64
secret CENTRIFUGO_HMAC_SECRET 64
secret CENTRIFUGO_ADMIN_PASSWORD 24
secret CENTRIFUGO_ADMIN_SECRET 64
[ -z "$missing" ] || die "missing:$missing (set them in .env, or mount the secrets volume at $SECRETS_DIR so they are generated)"
[ -z "$generated" ] || log "generated and stored in the secrets volume:$generated"
case " $generated " in
  *" ADMIN_PASSWORD "*) log "admin password (generated, shown once): $ADMIN_PASSWORD" ;;
esac

# ------------------------------------------------------ hosts and mode --
[ -n "${ADMIN_EMAIL:-}" ] || die "ADMIN_EMAIL is not set"
PUBLIC_URL="${PUBLIC_URL:-}"
if [ -n "$PUBLIC_URL" ]; then
  PUBLIC_URL="${PUBLIC_URL%/}"
  case "$PUBLIC_URL" in
    http://*|https://*) ;;
    *) die "PUBLIC_URL must start with http:// or https:// (got: $PUBLIC_URL)" ;;
  esac
  scheme="${PUBLIC_URL%%://*}"
  hostport="${PUBLIC_URL#*://}"
  case "$hostport" in */*) die "PUBLIC_URL must be an origin without a path (got: $PUBLIC_URL)" ;; esac
  host="${hostport%%:*}"
  [ -n "$host" ] || die "PUBLIC_URL has no host (got: $PUBLIC_URL)"
  ws_origin="ws${scheme#http}://$hostport"
  # One origin: every public host is that one, the XMPP domain included. The
  # web client (chat-component) takes the XMPP domain from the host of its
  # WebSocket URL, so the two must match, even when the host is an IP address.
  export ROOT_DOMAIN="${ROOT_DOMAIN:-$host}"
  export API_DOMAIN="$host" WEB_DOMAIN="$host" FILES_DOMAIN="$host" XMPP_DOMAIN="$host"
  export BASE_APP_DOMAIN_NAME="${BASE_APP_DOMAIN_NAME:-ethora}"
else
  [ -n "${ROOT_DOMAIN:-}" ] || die "ROOT_DOMAIN is not set (or set PUBLIC_URL for a one-origin install)"
  # Same derivations as setup.sh / refresh-deploy-env.sh / setup-env.sh.
  export API_DOMAIN="${API_DOMAIN:-api.$ROOT_DOMAIN}"
  export WEB_DOMAIN="${WEB_DOMAIN:-app.$ROOT_DOMAIN}"
  export XMPP_DOMAIN="${XMPP_DOMAIN:-xmpp.$ROOT_DOMAIN}"
  export FILES_DOMAIN="${FILES_DOMAIN:-files.$ROOT_DOMAIN}"
  # Base app slug: first label of the web host (app.chat.example.com -> app).
  export BASE_APP_DOMAIN_NAME="${BASE_APP_DOMAIN_NAME:-${WEB_DOMAIN%%.*}}"
fi
export HOSTED_APPS_ROOT_DOMAIN="${HOSTED_APPS_ROOT_DOMAIN:-$ROOT_DOMAIN}"
export DOMAIN_NAME="$BASE_APP_DOMAIN_NAME"
export BASE_APP_DISPLAY_NAME="${BASE_APP_DISPLAY_NAME:-Ethora}"
export BASE_APP_OWNER_EMAIL="${BASE_APP_OWNER_EMAIL:-$ADMIN_EMAIL}"
export BASE_APP_OWNER_PASSWORD="${BASE_APP_OWNER_PASSWORD:-$ADMIN_PASSWORD}"
export BASE_APP_START_BALANCE="${BASE_APP_START_BALANCE:-1000000}"
export ACME_EMAIL="${ACME_EMAIL:-$ADMIN_EMAIL}"
export CADDY_GLOBAL_OPTIONS="${CADDY_GLOBAL_OPTIONS:-}"

export NODE_ENV="${NODE_ENV:-production}"
export BACKEND_PORT=8080
export MONGO_PORT=27017
export MONGO_DB="${MONGO_DB:-ethora_prod}"
# Internal endpoints (see the header).
ETHORA_REDIS_HOST="${ETHORA_REDIS_HOST:-redis}"
ETHORA_MYSQL_HOST="${ETHORA_MYSQL_HOST:-mysql}"
ETHORA_MYSQL_USER="${ETHORA_MYSQL_USER:-root}"
ETHORA_MYSQL_DATABASE="${ETHORA_MYSQL_DATABASE:-ejabberd_db}"
ETHORA_MINIO_HOST="${ETHORA_MINIO_HOST:-minio}"
ETHORA_CENTRIFUGO_URL="${ETHORA_CENTRIFUGO_URL:-http://centrifugo:8000}"
ETHORA_XMPP_URL="${ETHORA_XMPP_URL:-http://xmpp:5280}"
ETHORA_API_URL="${ETHORA_API_URL:-http://api:8080}"
ETHORA_FRONTEND_URL="${ETHORA_FRONTEND_URL:-http://frontend:8080}"
export REDIS_PORT="${ETHORA_REDIS_PORT:-6379}"
export MYSQL_PORT="${ETHORA_MYSQL_PORT:-3306}"
MINIO_PORT="${ETHORA_MINIO_PORT:-9000}"
export CENTRIFUGO_PORT=8000
export PUSH_PORT="${PUSH_PORT:-8098}"
export AI_SERVICE_PORT="${AI_SERVICE_PORT:-8013}"
export DOCS_PARSE_PORT="${DOCS_PARSE_PORT:-8201}"
export MINIO_SECURE_BUCKET="${MINIO_SECURE_BUCKET:-secure-media}"

def() { # def NAME value: export NAME=value unless NAME is already set
  eval "[ -n \"\${$1+x}\" ]" || export "$1=$2"
}
# Ethora Core: the optional modules are not in this bundle (an overlay that
# adds one sets its flag in .env).
def BLOCKCHAIN_ENABLED false
def AI_SERVICE_ENABLED false
def DOCS_PARSE_ENABLED false
def CRAWLER_ENABLED false
def AI_FEATURE_ENABLED false
def ENABLE_SWAGGER true
def ENABLE_SWAGGER_INTERNAL false
def EMAIL_TLD_VALIDATION off
def RATE_LIMIT_DISABLED false
def REFRESH_TOKEN_TTL_DAYS 7
def REFRESH_REUSE_POLICY log_only
def XMPP_JWT_TTL 10m
def XMPP_JWT_WIDGET_TTL 100d
def CENTRIFUGO_ENABLED true
def CENTRIFUGO_TIMEOUT_MS 2000
def POSTMARK_ENABLED false
def POSTMARK_FROM_EMAIL noreply@ethoramail.com
def POSTMARK_FROM_NAME "Ethora Platform"
def POSTMARK_SUBJECT_PREFIX Ethora
def FEEDBACK_RETENTION_DAYS 180
def ANALYTICS_ENABLED false
def REPORT_DAILY_SCHEDULE "30 8 * * *"
def REPORT_WEEKLY_SCHEDULE "30 8 * * 1"
def REPORT_MONTHLY_SCHEDULE "30 8 1 * *"
def STRIPE_ENABLED false
def IAP_ENABLED false
def FIREBASE_ENABLED false
def HUBSPOT_ENABLED false
def HUBSPOT_REGION na1
def IMMUTABLE_LOGS_ENABLED false
def ETHORA_LICENSE_CALL_HOME true
def VIDEO_CALLS_ENABLED false
def E2EE_ENABLED false
def DISABLE_FIREBASE false
def DISABLE_GA true
def DISABLE_CLARITY true

# Whole-line placeholders in the env templates. The values are the
# production (non-localhost) branch of setup-env.sh replace_template(), with
# the compose service names where the installer uses 127.0.0.1.
export ROOT_DOMAIN_PLACEHOLDER="ROOT_DOMAIN=$ROOT_DOMAIN"
export XMPP_PATH_PLACEHOLDER="XMPP_PATH=$ETHORA_XMPP_URL/api"
export MINIO_SECURE_URL_PLACEHOLDER="MINIO_SECURE_URL=${SECURE_FILES_DOMAIN:+https://$SECURE_FILES_DOMAIN}"
if [ -z "$PUBLIC_URL" ]; then
  web_url="https://$WEB_DOMAIN"; api_url="https://$API_DOMAIN"; files_url="https://$FILES_DOMAIN"
  xmpp_ws="wss://$XMPP_DOMAIN/ws"
  export AUTH_COOKIE_DOMAIN_PLACEHOLDER="AUTH_COOKIE_DOMAIN=.$ROOT_DOMAIN"
  export VITE_API_PLACEHOLDER="VITE_API=https://$API_DOMAIN/v1"
  export VITE_API_V2_PLACEHOLDER="VITE_API_V2=https://$API_DOMAIN/v2"
  export VITE_APP_XMPP_SERVICE_PLACEHOLDER="VITE_APP_XMPP_SERVICE=wss://$XMPP_DOMAIN/ws"
  export VITE_APP_CENTRIFUGE_SERVICE_PLACEHOLDER="VITE_APP_CENTRIFUGE_SERVICE=wss://$WEB_DOMAIN/connection/websocket"
else
  web_url="$PUBLIC_URL"; api_url="$PUBLIC_URL"; files_url="$PUBLIC_URL"
  xmpp_ws="$ws_origin/ws"
  export AUTH_COOKIE_DOMAIN_PLACEHOLDER="AUTH_COOKIE_DOMAIN="
  # The web app resolves __ETHORA_ORIGIN__ / __ETHORA_ORIGIN_WS__ against
  # window.location when it loads (frontend-start.sh), so the API and
  # Centrifugo follow whatever address the install was opened by. XMPP does
  # not: the web client names its XMPP domain after the WebSocket host, so it
  # always connects to PUBLIC_URL itself.
  export VITE_API_PLACEHOLDER="VITE_API=__ETHORA_ORIGIN__/v1"
  export VITE_API_V2_PLACEHOLDER="VITE_API_V2=__ETHORA_ORIGIN__/v2"
  export VITE_APP_XMPP_SERVICE_PLACEHOLDER="VITE_APP_XMPP_SERVICE=$xmpp_ws"
  export VITE_APP_CENTRIFUGE_SERVICE_PLACEHOLDER="VITE_APP_CENTRIFUGE_SERVICE=__ETHORA_ORIGIN_WS__/connection/websocket"
fi
export DEFAULT_APP_URL_PLACEHOLDER="DEFAULT_APP_URL=$web_url"
export VERIFY_EMAIL_WEB_URL_PLACEHOLDER="VERIFY_EMAIL_WEB_URL=$web_url/verifyEmail"
export TEMP_PASSSORD_WEB_URL_PLACEHOLDER="TEMP_PASSSORD_WEB_URL=$web_url/tempPassword"
export XMPP_SERVICE_PLACEHOLDER="XMPP_SERVICE=$xmpp_ws"
export MINIO_URL_PLACEHOLDER="MINIO_URL=$files_url"

# ------------------------------------------------------------- render --
# render TEMPLATE OUT: literal substitution of {{NAME}} with $NAME (empty
# when unset, like setup-env.sh's ${NAME:-}) and of whole-line NAME_PLACEHOLDER
# with $NAME_PLACEHOLDER. Values are read from ENVIRON, never from the awk
# program text, so secrets need no escaping. Template-language lines
# ({{#if ...}}, {{/if}}) are dropped; their content stays, as in the installer.
render() {
  awk '
    /^[[:space:]]*\{\{[#\/]/ { next }
    /^[A-Z0-9_]+_PLACEHOLDER[[:space:]]*$/ {
      key = $1
      if (key in ENVIRON) { print ENVIRON[key] } else { print; unresolved[key] = 1 }
      next
    }
    {
      line = $0; out = ""
      while (match(line, /\{\{[A-Z0-9_]+\}\}/)) {
        name = substr(line, RSTART + 2, RLENGTH - 4)
        out = out substr(line, 1, RSTART - 1) ((name in ENVIRON) ? ENVIRON[name] : "")
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
    END { for (k in unresolved) printf("[config] WARN: unresolved placeholder %s\n", k) > "/dev/stderr" }
  ' "$1" > "$2"
}

# set_env_line FILE KEY VALUE: replace the KEY= line (every occurrence).
set_env_line() {
  awk -v k="$2" -v v="$3" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

stage="$(mktemp -d "${TMPDIR:-/tmp}/ethora-config.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/api" "$stage/frontend" "$stage/centrifugo" "$stage/xmpp"

for t in backend.env.template frontend.env.template centrifugo-config.json.template; do
  [ -f "$TEMPLATES/$t" ] || die "template not found: $TEMPLATES/$t (is ./templates mounted?)"
done

# backend.env
render "$TEMPLATES/backend.env.template" "$stage/api/backend.env"
set_env_line "$stage/api/backend.env" MONGO_URI "${ETHORA_MONGO_URI:-mongodb://mongo:27017/$MONGO_DB?directConnection=true}"
set_env_line "$stage/api/backend.env" CHAT_DATABASE "${ETHORA_CHAT_DATABASE_URI:-mongodb://mongo:27017/chat_archive?directConnection=true}"
set_env_line "$stage/api/backend.env" REDIS_HOST "$ETHORA_REDIS_HOST"
set_env_line "$stage/api/backend.env" MAM_MYSQL_HOST "$ETHORA_MYSQL_HOST"
set_env_line "$stage/api/backend.env" MAM_MYSQL_USER "$ETHORA_MYSQL_USER"
set_env_line "$stage/api/backend.env" MAM_MYSQL_DATABASE "$ETHORA_MYSQL_DATABASE"
set_env_line "$stage/api/backend.env" MINIO_HOST "$ETHORA_MINIO_HOST"
set_env_line "$stage/api/backend.env" MINIO_PORT "$MINIO_PORT"
set_env_line "$stage/api/backend.env" CENTRIFUGO_API_URL "$ETHORA_CENTRIFUGO_URL/api"
{
  echo "# Rendered by the compose bundle's config service from backend.env.template"
  echo "# on every 'docker compose up'. Edit .env, not this file."
  cat "$stage/api/backend.env"
  echo
  echo "# Compose bundle: the public entry points (scripts/verify.js reads them)."
  echo "ETHORA_PUBLIC_WEB_URL=$web_url"
  echo "ETHORA_PUBLIC_API_URL=$api_url"
  echo "ETHORA_PUBLIC_FILES_URL=$files_url"
  echo "ETHORA_PUBLIC_XMPP_WS_URL=$xmpp_ws"
  echo "# The API as the other services reach it (scripts/init.sh)."
  echo "API_INTERNAL_URL=$ETHORA_API_URL"
} > "$stage/api/backend.env.tmp" && mv "$stage/api/backend.env.tmp" "$stage/api/backend.env"

# frontend.env
render "$TEMPLATES/frontend.env.template" "$stage/frontend/frontend.env"

# centrifugo config.json
render "$TEMPLATES/centrifugo-config.json.template" "$stage/centrifugo/config.json"

# ejabberd.yml + jwt.key: the production branch of setup-ejabberd-config.sh.
[ -f "$DIST/ejabberd-prod.yml" ] || die "$DIST/ejabberd-prod.yml not found; the config service must run the ethora-xmpp image"
cfg="$stage/xmpp/ejabberd.yml"
cp "$DIST/ejabberd-prod.yml" "$cfg"
export TRACK_MEMBER_URL="${TRACK_MEMBER_URL:-$ETHORA_API_URL/v1/chats/track-member}"
export TRACK_LAST_MESSAGE_URL="${TRACK_LAST_MESSAGE_URL:-$ETHORA_API_URL/v1/chats/track-last-message}"
export TRACK_MESSAGE_URL="${TRACK_MESSAGE_URL:-$ETHORA_API_URL/v1/chats/archive-message}"
export HISTORY_ACCESS_URL="${HISTORY_ACCESS_URL:-$ETHORA_API_URL/v1/chats/history-access}"
export MESSAGE_AUDIT_URL="${MESSAGE_AUDIT_URL:-$ETHORA_API_URL/v1/chats/message-audit}"
PUSH_COMMON_POST_URL="${PUSH_COMMON_POST_URL:-https://$API_DOMAIN/push/api/v2/push}"
PUSH_VOIP_POST_URL="${PUSH_VOIP_POST_URL:-http://host.docker.internal:7778/api/v1/voippush}"
push_token="${B2B_PUSH_SECRET:-$INTERNAL_REQUESTS_SECRET}"
admin_jid="admin@$XMPP_DOMAIN"

# Values go into sed replacement text below: escape \, | (the delimiter) and
# & so an operator-chosen password with those characters renders literally.
esc() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }
E_XMPP_DOMAIN="$(esc "$XMPP_DOMAIN")"
E_ADMIN_JID="$(esc "$admin_jid")"
E_MYSQL_ROOT_PASSWORD="$(esc "$MYSQL_ROOT_PASSWORD")"
E_XMPP_SECRET="$(esc "$XMPP_SECRET")"
E_TRACK_MEMBER_URL="$(esc "$TRACK_MEMBER_URL")"
E_TRACK_LAST_MESSAGE_URL="$(esc "$TRACK_LAST_MESSAGE_URL")"
E_TRACK_MESSAGE_URL="$(esc "$TRACK_MESSAGE_URL")"
E_HISTORY_ACCESS_URL="$(esc "$HISTORY_ACCESS_URL")"
E_MESSAGE_AUDIT_URL="$(esc "$MESSAGE_AUDIT_URL")"
E_PUSH_COMMON_POST_URL="$(esc "$PUSH_COMMON_POST_URL")"
E_PUSH_VOIP_POST_URL="$(esc "$PUSH_VOIP_POST_URL")"
E_PUSH_TOKEN="$(esc "$push_token")"
E_TRANSLATE_URL="$(esc "${TRANSLATE_URL:-}")"

# hosts
sed -i "/^hosts:/,/^[a-z]/s|^  -.*|  - $E_XMPP_DOMAIN|" "$cfg"
# acl admin / apicommands
sed -i \
  -e "/^  admin:/,/^  [a-z]/ s|^[ ]*- \"[^\"]*\"|      - \"$E_ADMIN_JID\"|g" \
  -e "/^  apicommands:/,/^  [a-z]/ s|^[ ]*- \"[^\"]*\"|      - \"$E_ADMIN_JID\"|g" \
  "$cfg"
# sql password
sed -i "s|^sql_password:.*|sql_password: \"$E_MYSQL_ROOT_PASSWORD\"|g" "$cfg"
# sql server, user, port: only when they differ from the template's
# (mysql, root, 3306), so the default rendering stays the installer's.
if [ "$ETHORA_MYSQL_HOST" != mysql ]; then
  sed -i "s|^sql_server:.*|sql_server: \"$(esc "$ETHORA_MYSQL_HOST")\"|" "$cfg"
fi
if [ "$ETHORA_MYSQL_DATABASE" != ejabberd_db ]; then
  sed -i "s|^sql_database:.*|sql_database: \"$(esc "$ETHORA_MYSQL_DATABASE")\"|" "$cfg"
fi
if [ "$ETHORA_MYSQL_USER" != root ]; then
  sed -i "s|^sql_username:.*|sql_username: \"$(esc "$ETHORA_MYSQL_USER")\"|" "$cfg"
fi
if [ "$MYSQL_PORT" != 3306 ]; then
  if grep -q '^sql_port:' "$cfg"; then sed -i "s|^sql_port:.*|sql_port: $MYSQL_PORT|" "$cfg"
  else awk -v p="$MYSQL_PORT" '{ print } /^sql_server:/ { print "sql_port: " p }' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"; fi
fi
# tracking modules
sed -i \
  -e "/^  mod_track_member:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"$E_TRACK_MEMBER_URL\"|g" \
  -e "/^  mod_track_member:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"$E_XMPP_SECRET\"|g" \
  -e "/^  mod_track_last_message:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"$E_TRACK_LAST_MESSAGE_URL\"|g" \
  -e "/^  mod_track_last_message:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"$E_XMPP_SECRET\"|g" \
  "$cfg"
if grep -q "^  mod_track_message:" "$cfg"; then
  sed -i \
    -e "/^  mod_track_message:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"$E_TRACK_MESSAGE_URL\"|g" \
    -e "/^  mod_track_message:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"$E_XMPP_SECRET\"|g" \
    "$cfg"
fi
if grep -q "^  mod_history_access:" "$cfg"; then
  sed -i \
    -e "/^  mod_history_access:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"$E_HISTORY_ACCESS_URL\"|g" \
    -e "/^  mod_history_access:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"$E_XMPP_SECRET\"|g" \
    "$cfg"
fi
# mod_edit / mod_delete ship as bare `{}` blocks: expand them into url/secret
# lines first (awk, so BusyBox and GNU produce the same text), then render.
for audit_mod in mod_edit mod_delete; do
  if grep -qE "^  $audit_mod:[[:space:]]*\{\}[[:space:]]*$" "$cfg"; then
    awk -v m="$audit_mod" '
      $0 ~ "^  " m ":[[:space:]]*\\{\\}[[:space:]]*$" { print "  " m ":"; print "    url: \"\""; print "    secret: \"\""; next }
      { print }' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  fi
  if grep -q "^  $audit_mod:" "$cfg"; then
    sed -i \
      -e "/^  $audit_mod:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"$E_MESSAGE_AUDIT_URL\"|g" \
      -e "/^  $audit_mod:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"$E_XMPP_SECRET\"|g" \
      "$cfg"
  fi
done
# mod_offline_post
sed -i \
  -e "/^  mod_offline_post:/,/^  [a-z_]/ s|^[ ]*common_post_url:.*|    common_post_url: \"$E_PUSH_COMMON_POST_URL\"|g" \
  -e "/^  mod_offline_post:/,/^  [a-z_]/ s|^[ ]*voip_post_url:.*|    voip_post_url: \"$E_PUSH_VOIP_POST_URL\"|g" \
  -e "/^  mod_offline_post:/,/^  [a-z_]/ s|^[ ]*auth_token:.*|    auth_token: \"$E_PUSH_TOKEN\"|g" \
  "$cfg"
# certfiles
sed -i "s|/cert/[^\" ]*\\.pem|/cert/$E_XMPP_DOMAIN.pem|g" "$cfg"
# translate_url (only when set)
if [ -n "${TRANSLATE_URL:-}" ]; then
  sed -i "s|^\([[:space:]]*\)translate_url:.*|\1translate_url: \"$E_TRANSLATE_URL\"|" "$cfg"
fi
# JWT SASL auth
k="$(printf '%s' "$XMPP_JWT_SECRET" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
printf '{"kty":"oct","k":"%s"}' "$k" > "$stage/xmpp/jwt.key"
sed -i "s|^auth_method:.*|auth_method: [sql, jwt, anonymous]|" "$cfg"
if ! grep -qE "^jwt_key:" "$cfg"; then
  awk '{ print } /^auth_method:/ { print "jwt_key: \"/home/ejabberd/conf/jwt.key\""; print "jwt_jid_field: \"jid\"" }' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
fi

# xmpp-start.sh registers admin@<xmpp host> with this password.
printf '%s\n' "$XMPP_ADMIN_PASSWORD" > "$stage/xmpp/admin-password"

# Database credentials for the images' *_FILE variables.
mkdir -p "$stage/mysql" "$stage/minio"
printf '%s' "$MYSQL_ROOT_PASSWORD" > "$stage/mysql/root-password"
printf '%s' "$MINIO_ROOT_USER" > "$stage/minio/root-user"
printf '%s' "$MINIO_ROOT_PASSWORD" > "$stage/minio/root-password"

# Caddyfile: the template's {$NAME} placeholders (Caddy's own syntax), with
# the site blocks of the routing mode in {$ETHORA_SITES}.
if [ -z "$PUBLIC_URL" ]; then
  ETHORA_SITES="$(printf '%s {\n\timport api\n}\n%s {\n\timport web\n}\n%s {\n\timport xmpp\n}\n%s {\n\timport files\n}' \
    "$API_DOMAIN" "$WEB_DOMAIN" "$XMPP_DOMAIN" "$FILES_DOMAIN")"
elif [ -n "${ETHORA_SITE_ADDRESS:-}" ]; then
  ETHORA_SITES="$(printf '%s {\n\timport single_origin\n}' "$ETHORA_SITE_ADDRESS")"
elif [ "$scheme" = https ]; then
  ETHORA_SITES="$(printf '%s {\n\timport single_origin\n}' "$hostport")"
else
  # Plain HTTP (a LAN appliance): any host name on the container's port 80,
  # which the platform or HTTP_PORT maps to the port in PUBLIC_URL.
  ETHORA_SITES="$(printf ':80 {\n\timport single_origin\n}')"
fi
export ETHORA_SITES
export ETHORA_EXTRA_SITES="${ETHORA_EXTRA_SITES:-}"
hostport_of() { u="${1#*://}"; printf '%s' "${u%%/*}"; }
export UPSTREAM_API="$(hostport_of "$ETHORA_API_URL")"
export UPSTREAM_XMPP="$(hostport_of "$ETHORA_XMPP_URL")"
export UPSTREAM_CENTRIFUGO="$(hostport_of "$ETHORA_CENTRIFUGO_URL")"
export UPSTREAM_FRONTEND="$(hostport_of "$ETHORA_FRONTEND_URL")"
export UPSTREAM_MINIO="$ETHORA_MINIO_HOST:$MINIO_PORT"
mkdir -p "$stage/caddy"
if [ -f "$CADDYFILE_TEMPLATE" ]; then
  awk '
    /^[[:space:]]*#/ { print; next }
    {
      line = $0; out = ""
      while (match(line, /\{\$[A-Z0-9_]+\}/)) {
        name = substr(line, RSTART + 2, RLENGTH - 3)
        out = out substr(line, 1, RSTART - 1) ((name in ENVIRON) ? ENVIRON[name] : "")
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }' "$CADDYFILE_TEMPLATE" > "$stage/caddy/Caddyfile"
else
  log "no Caddyfile template at $CADDYFILE_TEMPLATE; the caddy service will not start"
fi

# The bundle's scripts, for every service that runs one.
mkdir -p "$stage/scripts"
cp "$SCRIPTS_SRC"/*.sh "$SCRIPTS_SRC"/*.js "$stage/scripts/"

# ------------------------------------------------------------ install --
# Hand each directory to the one container user that reads it; secrets stay
# unreadable to the others. Then swap the whole tree in.
chmod 700 "$stage/api" "$stage/frontend" "$stage/centrifugo" "$stage/xmpp" "$stage/mysql" "$stage/minio"
chmod 600 "$stage"/api/* "$stage"/frontend/* "$stage"/centrifugo/* "$stage"/xmpp/* "$stage"/mysql/* "$stage"/minio/*
# Neither secret nor per-service: readable by every container.
chmod 755 "$stage/caddy" "$stage/scripts"
for f in "$stage"/caddy/* "$stage"/scripts/*; do [ -f "$f" ] && chmod 644 "$f"; done
# (Only root can hand files over; a non-root run, e.g. the bundle's tests,
# keeps its own ownership.)
own() { chown -R "$1" "$2" 2>/dev/null || [ "$(id -u)" != 0 ] || die "chown $1 $2 failed"; }
own "$API_UID:$API_UID" "$stage/api"
own "$FRONTEND_UID:$FRONTEND_UID" "$stage/frontend"
own "$CENTRIFUGO_UID:$CENTRIFUGO_UID" "$stage/centrifugo"
own "$XMPP_UID:$XMPP_UID" "$stage/xmpp"
own "$MYSQL_UID:$MYSQL_UID" "$stage/mysql"
own "$MINIO_UID:$MINIO_UID" "$stage/minio"
own 0:0 "$stage/caddy"
own 0:0 "$stage/scripts"
mkdir -p "$OUT"
for d in api frontend centrifugo xmpp mysql minio caddy scripts; do
  rm -rf "$OUT/$d.new"
  cp -a "$stage/$d" "$OUT/$d.new"
  rm -rf "$OUT/$d"
  mv "$OUT/$d.new" "$OUT/$d"
done
chmod 755 "$OUT"

# MySQL runs this only when its data directory is empty (first start).
mkdir -p "$MYSQL_INITDB"
cp "$DIST/mysql2.sql" "$MYSQL_INITDB/01-ejabberd.sql"
chmod 644 "$MYSQL_INITDB/01-ejabberd.sql"

if [ -n "$PUBLIC_URL" ]; then
  log "rendered for one origin $PUBLIC_URL (xmpp domain $XMPP_DOMAIN, base app slug $BASE_APP_DOMAIN_NAME)"
else
  log "rendered for $ROOT_DOMAIN: api=$API_DOMAIN web=$WEB_DOMAIN xmpp=$XMPP_DOMAIN files=$FILES_DOMAIN (base app slug: $BASE_APP_DOMAIN_NAME)"
fi
