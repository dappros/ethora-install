#!/bin/sh
# render-config.sh - the `config` service of the compose bundle.
#
# Renders every config file the stack reads from the operator's .env, using
# the same templates the host installer renders (deploy/scripts/setup-env.sh,
# deploy/scripts/setup-ejabberd-config.sh):
#
#   /out/config/api/backend.env            <- templates/backend.env.template
#   /out/config/frontend/frontend.env      <- templates/frontend.env.template
#   /out/config/centrifugo/config.json     <- templates/centrifugo-config.json.template
#   /out/config/xmpp/ejabberd.yml, jwt.key <- /ethora-dist/ejabberd-prod.yml (from the xmpp image)
#   /out/mysql-initdb/01-ejabberd.sql      <- /ethora-dist/mysql2.sql (from the xmpp image)
#
# It runs in the ethora-xmpp image (BusyBox sh, sed, awk), so the ejabberd
# template and schema always come from the image that is about to run. It
# runs on every `docker compose up` and rewrites everything, so .env is the
# only state an operator keeps; the rendered files are disposable.
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
DIST="${XMPP_DIST_DIR:-/ethora-dist}"
OUT="${CONFIG_OUT_DIR:-/out/config}"
MYSQL_INITDB="${MYSQL_INITDB_DIR:-/out/mysql-initdb}"
# Numeric owners of the consumers (the stock images' users). Rendering as
# root, each file is handed to the one container user that reads it.
API_UID="${API_UID:-1000}"          # ethora-api: node
XMPP_UID="${XMPP_UID:-9000}"        # ethora-xmpp: ejabberd
CENTRIFUGO_UID="${CENTRIFUGO_UID:-1000}"

log() { echo "[config] $*"; }
die() { echo "[config] ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------ required --
missing=""
for v in ROOT_DOMAIN ADMIN_EMAIL ADMIN_PASSWORD JWT_SECRET REFRESH_SECRET \
         XMPP_SECRET XMPP_JWT_SECRET XMPP_ADMIN_PASSWORD MYSQL_ROOT_PASSWORD \
         MINIO_ROOT_USER MINIO_ROOT_PASSWORD INTERNAL_REQUESTS_SECRET \
         CENTRIFUGO_API_KEY CENTRIFUGO_HMAC_SECRET CENTRIFUGO_ADMIN_PASSWORD \
         CENTRIFUGO_ADMIN_SECRET; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || missing="$missing $v"
done
[ -z "$missing" ] || die "missing in .env:$missing (run ./configure.sh, or copy .env.example to .env and fill it in)"

# --------------------------------------------------- derived + defaults --
# Same derivations as setup.sh / refresh-deploy-env.sh / setup-env.sh.
export API_DOMAIN="${API_DOMAIN:-api.$ROOT_DOMAIN}"
export WEB_DOMAIN="${WEB_DOMAIN:-app.$ROOT_DOMAIN}"
export XMPP_DOMAIN="${XMPP_DOMAIN:-xmpp.$ROOT_DOMAIN}"
export FILES_DOMAIN="${FILES_DOMAIN:-files.$ROOT_DOMAIN}"
export HOSTED_APPS_ROOT_DOMAIN="${HOSTED_APPS_ROOT_DOMAIN:-$ROOT_DOMAIN}"
# Base app slug: first label of the web host (app.chat.example.com -> app).
export BASE_APP_DOMAIN_NAME="${BASE_APP_DOMAIN_NAME:-${WEB_DOMAIN%%.*}}"
export DOMAIN_NAME="$BASE_APP_DOMAIN_NAME"
export BASE_APP_DISPLAY_NAME="${BASE_APP_DISPLAY_NAME:-Ethora}"
export BASE_APP_OWNER_EMAIL="${BASE_APP_OWNER_EMAIL:-$ADMIN_EMAIL}"
export BASE_APP_OWNER_PASSWORD="${BASE_APP_OWNER_PASSWORD:-$ADMIN_PASSWORD}"
export BASE_APP_START_BALANCE="${BASE_APP_START_BALANCE:-1000000}"

export NODE_ENV="${NODE_ENV:-production}"
export BACKEND_PORT=8080
export MONGO_PORT=27017
export MONGO_DB="${MONGO_DB:-ethora_prod}"
export REDIS_PORT=6379
export MYSQL_PORT=3306
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
export DEFAULT_APP_URL_PLACEHOLDER="DEFAULT_APP_URL=https://$WEB_DOMAIN"
export VERIFY_EMAIL_WEB_URL_PLACEHOLDER="VERIFY_EMAIL_WEB_URL=https://$WEB_DOMAIN/verifyEmail"
export TEMP_PASSSORD_WEB_URL_PLACEHOLDER="TEMP_PASSSORD_WEB_URL=https://$WEB_DOMAIN/tempPassword"
export XMPP_PATH_PLACEHOLDER="XMPP_PATH=http://xmpp:5280/api"
export XMPP_SERVICE_PLACEHOLDER="XMPP_SERVICE=wss://$XMPP_DOMAIN/ws"
export MINIO_URL_PLACEHOLDER="MINIO_URL=https://$FILES_DOMAIN"
export MINIO_SECURE_URL_PLACEHOLDER="MINIO_SECURE_URL=${SECURE_FILES_DOMAIN:+https://$SECURE_FILES_DOMAIN}"
export AUTH_COOKIE_DOMAIN_PLACEHOLDER="AUTH_COOKIE_DOMAIN=.$ROOT_DOMAIN"
export VITE_API_PLACEHOLDER="VITE_API=https://$API_DOMAIN/v1"
export VITE_API_V2_PLACEHOLDER="VITE_API_V2=https://$API_DOMAIN/v2"
export VITE_APP_XMPP_SERVICE_PLACEHOLDER="VITE_APP_XMPP_SERVICE=wss://$XMPP_DOMAIN/ws"
export VITE_APP_CENTRIFUGE_SERVICE_PLACEHOLDER="VITE_APP_CENTRIFUGE_SERVICE=wss://$WEB_DOMAIN/connection/websocket"

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
set_env_line "$stage/api/backend.env" MONGO_URI "mongodb://mongo:27017/$MONGO_DB?directConnection=true"
set_env_line "$stage/api/backend.env" CHAT_DATABASE "mongodb://mongo:27017/chat_archive?directConnection=true"
set_env_line "$stage/api/backend.env" REDIS_HOST redis
set_env_line "$stage/api/backend.env" MAM_MYSQL_HOST mysql
set_env_line "$stage/api/backend.env" MINIO_HOST minio
set_env_line "$stage/api/backend.env" CENTRIFUGO_API_URL "http://centrifugo:8000/api"
{
  echo "# Rendered by the compose bundle's config service from backend.env.template"
  echo "# on every 'docker compose up'. Edit .env, not this file."
  cat "$stage/api/backend.env"
} > "$stage/api/backend.env.tmp" && mv "$stage/api/backend.env.tmp" "$stage/api/backend.env"

# frontend.env
render "$TEMPLATES/frontend.env.template" "$stage/frontend/frontend.env"

# centrifugo config.json
render "$TEMPLATES/centrifugo-config.json.template" "$stage/centrifugo/config.json"

# ejabberd.yml + jwt.key: the production branch of setup-ejabberd-config.sh.
[ -f "$DIST/ejabberd-prod.yml" ] || die "$DIST/ejabberd-prod.yml not found; the config service must run the ethora-xmpp image"
cfg="$stage/xmpp/ejabberd.yml"
cp "$DIST/ejabberd-prod.yml" "$cfg"
export TRACK_MEMBER_URL="${TRACK_MEMBER_URL:-http://api:8080/v1/chats/track-member}"
export TRACK_LAST_MESSAGE_URL="${TRACK_LAST_MESSAGE_URL:-http://api:8080/v1/chats/track-last-message}"
export TRACK_MESSAGE_URL="${TRACK_MESSAGE_URL:-http://api:8080/v1/chats/archive-message}"
export HISTORY_ACCESS_URL="${HISTORY_ACCESS_URL:-http://api:8080/v1/chats/history-access}"
export MESSAGE_AUDIT_URL="${MESSAGE_AUDIT_URL:-http://api:8080/v1/chats/message-audit}"
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

# ------------------------------------------------------------ install --
# Hand each directory to the one container user that reads it; secrets stay
# unreadable to the others. Then swap the whole tree in.
chmod 700 "$stage/api" "$stage/frontend" "$stage/centrifugo" "$stage/xmpp"
chmod 600 "$stage"/*/*
# (Only root can hand files over; a non-root run, e.g. the bundle's tests,
# keeps its own ownership.)
own() { chown -R "$1" "$2" 2>/dev/null || [ "$(id -u)" != 0 ] || die "chown $1 $2 failed"; }
own "$API_UID:$API_UID" "$stage/api"
own 0:0 "$stage/frontend"
own "$CENTRIFUGO_UID:$CENTRIFUGO_UID" "$stage/centrifugo"
own "$XMPP_UID:$XMPP_UID" "$stage/xmpp"
mkdir -p "$OUT"
for d in api frontend centrifugo xmpp; do
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

log "rendered for $ROOT_DOMAIN: api=$API_DOMAIN web=$WEB_DOMAIN xmpp=$XMPP_DOMAIN files=$FILES_DOMAIN (base app slug: $BASE_APP_DOMAIN_NAME)"
