#!/usr/bin/env bash
# configure.sh - write .env for the Ethora Core compose bundle from a few
# answers. The compose counterpart of deploy/scripts/setup.sh: same answers,
# same host derivation, every secret generated. Needs bash and coreutils
# only; nothing is installed and nothing is started.
#
# Usage
#   ./configure.sh                                        interactive
#   ./configure.sh --domain chat.example.com --admin-email ops@example.com --yes
#   ./configure.sh --domain 203-0-113-10.sslip.io --admin-email ops@example.com --yes
#
# Answers (flag, or env ETHORA_SETUP_<NAME>, or prompt):
#   --domain ROOT            root domain: api./app./xmpp./files. derive from it
#   --public-url URL         one origin instead: https://chat.example.com, or
#                            http://<LAN address>:<port> (sets HTTP_PORT)
#   --api/--web/--xmpp/--files HOST   explicit host overrides
#   --admin-email EMAIL      platform admin, base app owner, Let's Encrypt contact
#   --admin-password PASS    default: generated, printed once
#   --display-name NAME      base app display name (default: Ethora)
#   --license-key KEY        ETHORA1.<payload>.<signature>; empty = Ethora Core
#   --no-call-home           air-gapped install (needs an offline key)
#   --no-caddy               no bundled proxy; the platform routes the four hosts
#   --local-certs            Caddy issues self-signed certificates (LAN tests)
#   --out FILE               default: .env next to this script
#   --force                  start over: regenerate every secret (fresh installs only)
#   --yes                    non-interactive: never prompt, fail on missing answers
#   --dry-run                print the resolved answers and exit without writing
#
# Re-running on an existing .env reconfigures it: secrets and every value
# not answered again are kept, so the databases keep accepting them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/.env.example"
OUT_FILE="$SCRIPT_DIR/.env"

log()  { echo "[configure] $*"; }
warn() { echo "[configure] $*" >&2; }
die()  { echo "[configure] ERROR: $*" >&2; exit 1; }

A_DOMAIN="${ETHORA_SETUP_DOMAIN:-}"
A_PUBLIC_URL="${ETHORA_SETUP_PUBLIC_URL:-}"
A_API="${ETHORA_SETUP_API:-}"; A_WEB="${ETHORA_SETUP_WEB:-}"; A_XMPP="${ETHORA_SETUP_XMPP:-}"; A_FILES="${ETHORA_SETUP_FILES:-}"
A_ADMIN_EMAIL="${ETHORA_SETUP_ADMIN_EMAIL:-}"
A_ADMIN_PASSWORD="${ETHORA_SETUP_ADMIN_PASSWORD:-}"
A_DISPLAY_NAME="${ETHORA_SETUP_DISPLAY_NAME:-}"
A_LICENSE_KEY="${ETHORA_SETUP_LICENSE_KEY:-}"
A_CALL_HOME="${ETHORA_SETUP_CALL_HOME:-}"
A_CADDY=""; A_LOCAL_CERTS=false
FORCE=false; YES=false; DRY_RUN=false

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) A_DOMAIN="$2"; shift 2 ;;
    --public-url) A_PUBLIC_URL="$2"; shift 2 ;;
    --api) A_API="$2"; shift 2 ;;
    --web) A_WEB="$2"; shift 2 ;;
    --xmpp) A_XMPP="$2"; shift 2 ;;
    --files) A_FILES="$2"; shift 2 ;;
    --admin-email) A_ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) A_ADMIN_PASSWORD="$2"; shift 2 ;;
    --display-name) A_DISPLAY_NAME="$2"; shift 2 ;;
    --license-key) A_LICENSE_KEY="$2"; shift 2 ;;
    --no-call-home) A_CALL_HOME="false"; shift ;;
    --no-caddy) A_CADDY="off"; shift ;;
    --local-certs) A_LOCAL_CERTS=true; shift ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --yes|--non-interactive|-y) YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -f "$TEMPLATE" ] || die "$TEMPLATE not found; run this script from the bundle directory"

# ----------------------------------------------------------------- helpers --
# Kept identical to deploy/scripts/setup.sh (deploy/scripts/tests/compose-bundle.test.sh checks).
norm_host() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*$##; s#:[0-9]+$##; s#\.$##; s#^[[:space:]]+|[[:space:]]+$##g'; }
valid_host() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || [ "$1" = "localhost" ]; }
valid_email() { [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || [[ "$1" =~ ^[^[:space:]@]+@localhost$ ]]; }
valid_key() { [[ "$1" =~ ^ETHORA1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; }

is_tty() { [ -t 0 ] && [ -t 1 ]; }
prompt() { # prompt VAR "question" "default": only when interactive and VAR is empty
  local var="$1" q="$2" def="${3:-}" ans
  [ -n "${!var}" ] && return 0
  if [ "$YES" = true ] || ! is_tty; then printf -v "$var" '%s' "$def"; return 0; fi
  if [ -n "$def" ]; then read -r -p "$q [$def]: " ans </dev/tty; else read -r -p "$q: " ans </dev/tty; fi
  printf -v "$var" '%s' "${ans:-$def}"
}
# Letters and digits only: safe in .env, YAML, JSON, URLs and sed.
rand() { local n="$1" s=""; while [ "${#s}" -lt "$n" ]; do s="$s$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"; done; printf '%s' "${s:0:$n}"; }

# Values of an existing .env (plain KEY=value, optionally quoted, as this
# script writes them), kept as OLD_<KEY>; bash 3.2 compatible (macOS).
OLD_KEYS=""
read_env() {
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; elif [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
    printf -v "OLD_$key" '%s' "$val"
    OLD_KEYS="$OLD_KEYS $key"
  done < "$1"
}
old() { local n="OLD_$1"; printf '%s' "${!n:-}"; }
has_old() { local n="OLD_$1"; [ -n "${!n+x}" ]; }

if [ -f "$OUT_FILE" ]; then
  if [ "$FORCE" = true ]; then
    warn "WARNING: --force regenerates every secret in $OUT_FILE; databases initialised with the old ones will refuse the new passwords. Only for a fresh install."
  else
    read_env "$OUT_FILE"
    log "$OUT_FILE exists: reconfiguring it (secrets and unanswered values kept; --force to start over)"
  fi
fi

# ------------------------------------------------------------ gather answers --
# One origin (PUBLIC_URL) or four hosts under a root domain.
[ -z "$A_PUBLIC_URL" ] && [ -z "$A_DOMAIN" ] && A_PUBLIC_URL="$(old PUBLIC_URL)"
PORT_FROM_URL=""
if [ -n "$A_PUBLIC_URL" ]; then
  A_PUBLIC_URL="${A_PUBLIC_URL%/}"
  [[ "$A_PUBLIC_URL" =~ ^(https?)://([^/:]+)(:([0-9]+))?$ ]] || die "--public-url must be http(s)://host[:port] with no path (got: $A_PUBLIC_URL)"
  _scheme="${BASH_REMATCH[1]}"; _host="$(norm_host "${BASH_REMATCH[2]}")"; _port="${BASH_REMATCH[4]}"
  valid_host "$_host" || [[ "$_host" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || [[ "$_host" =~ ^[a-z0-9-]+$ ]] || die "not a valid host in --public-url: $_host"
  A_PUBLIC_URL="$_scheme://$_host${_port:+:$_port}"
  if [ "$_scheme" = http ]; then PORT_FROM_URL="${_port:-80}"; elif [ -n "$_port" ]; then die "an https --public-url uses port 443; drop :$_port"; fi
  A_DOMAIN=""; V_API=""; V_WEB=""; V_XMPP=""; V_FILES=""
else
  [ -z "$A_DOMAIN" ] && A_DOMAIN="$(old ROOT_DOMAIN)"
  if [ "$YES" != true ] && is_tty && [ -z "$A_DOMAIN" ]; then
    echo
    echo "Ethora Core, compose bundle. Two questions; everything else is derived or generated."
    echo "Root domain: the four service hosts derive from it, e.g. chat.example.com ->"
    echo "  api.chat.example.com, app.chat.example.com, xmpp.chat.example.com, files.chat.example.com"
    echo "No domain yet? Use <server IP with dashes>.sslip.io, e.g. 203-0-113-10.sslip.io."
    echo "(One address instead of four hosts: re-run with --public-url.)"
    echo
  fi
  prompt A_DOMAIN "Root domain" ""
  A_DOMAIN="$(norm_host "$A_DOMAIN")"
  [ -n "$A_DOMAIN" ] || die "a root domain is required (--domain chat.example.com), or --public-url"
  [ "$A_DOMAIN" != "localhost" ] || die "the compose bundle needs a public domain (Caddy obtains certificates for it); try <IP with dashes>.sslip.io, or --public-url http://localhost:8420"
  valid_host "$A_DOMAIN" || die "not a valid domain: $A_DOMAIN"

  # Host overrides: an answer wins, then a previous explicit override, then the
  # derived default (written empty, so it follows ROOT_DOMAIN).
  host_value() { # host_value <answer> <env key> <prefix>
    local v="$1"
    [ -z "$v" ] && v="$(old "$2")"
    [ -z "$v" ] && { echo ""; return; }
    v="$(norm_host "$v")"
    valid_host "$v" || die "not a valid host: $v"
    [ "$v" = "$3.$A_DOMAIN" ] && v=""
    echo "$v"
  }
  V_API="$(host_value "$A_API" API_DOMAIN api)"
  V_WEB="$(host_value "$A_WEB" WEB_DOMAIN app)"
  V_XMPP="$(host_value "$A_XMPP" XMPP_DOMAIN xmpp)"
  V_FILES="$(host_value "$A_FILES" FILES_DOMAIN files)"
fi

prompt A_ADMIN_EMAIL "Admin email (platform admin, base app owner, TLS contact)" "$(old ADMIN_EMAIL)"
[ -n "$A_ADMIN_EMAIL" ] || die "an admin email is required (--admin-email)"
valid_email "$A_ADMIN_EMAIL" || die "not a valid email: $A_ADMIN_EMAIL"

GENERATED_PASSWORD=false
if [ -z "$A_ADMIN_PASSWORD" ]; then
  A_ADMIN_PASSWORD="$(old ADMIN_PASSWORD)"
  if [ -z "$A_ADMIN_PASSWORD" ]; then A_ADMIN_PASSWORD="$(rand 20)"; GENERATED_PASSWORD=true; fi
fi

[ -z "$A_DISPLAY_NAME" ] && A_DISPLAY_NAME="$(old BASE_APP_DISPLAY_NAME)"
A_DISPLAY_NAME="${A_DISPLAY_NAME:-Ethora}"

[ -z "$A_LICENSE_KEY" ] && A_LICENSE_KEY="$(old ETHORA_LICENSE_KEY)"
A_LICENSE_KEY="$(printf '%s' "$A_LICENSE_KEY" | tr -d '[:space:]')"
if [ -n "$A_LICENSE_KEY" ] && ! valid_key "$A_LICENSE_KEY"; then
  die "license key does not look like an Ethora key (expected ETHORA1.<payload>.<signature>)"
fi
[ -z "$A_CALL_HOME" ] && A_CALL_HOME="$(old ETHORA_LICENSE_CALL_HOME)"
A_CALL_HOME="${A_CALL_HOME:-true}"

PROFILES="$(old COMPOSE_PROFILES)"
has_old COMPOSE_PROFILES || PROFILES="caddy"
[ "$A_CADDY" = "off" ] && PROFILES=""
CADDY_OPTS="$(old CADDY_GLOBAL_OPTIONS)"
[ "$A_LOCAL_CERTS" = true ] && CADDY_OPTS="local_certs"

# Every value goes into .env. Refuse the one character this file format
# cannot carry literally in a single-quoted value.
for v in "$A_ADMIN_PASSWORD" "$A_DISPLAY_NAME"; do
  case "$v" in *"'"*) die "values cannot contain a single quote (') - choose another admin password / display name" ;; esac
done

# ------------------------------------------------------------------ report --
echo
if [ -n "$A_PUBLIC_URL" ]; then
  echo "  One origin:      $A_PUBLIC_URL (web app, API, XMPP and files routed by path)"
else
  echo "  Hosts:           api=${V_API:-api.$A_DOMAIN} web=${V_WEB:-app.$A_DOMAIN}"
  echo "                   xmpp=${V_XMPP:-xmpp.$A_DOMAIN} files=${V_FILES:-files.$A_DOMAIN}"
fi
echo "  Admin:           $A_ADMIN_EMAIL  ($([ "$GENERATED_PASSWORD" = true ] && echo "password generated" || echo "password kept/supplied"))"
echo "  Display name:    $A_DISPLAY_NAME"
echo "  License:         $([ -n "$A_LICENSE_KEY" ] && echo "key ${A_LICENSE_KEY:0:24}..." || echo "none (Ethora Core; register from the admin panel)")  call-home=$A_CALL_HOME"
echo "  Proxy:           $([ -n "$PROFILES" ] && echo "bundled Caddy (ports ${PORT_FROM_URL:-$(old HTTP_PORT | grep . || echo 80)}/$(old HTTPS_PORT | grep . || echo 443))${CADDY_OPTS:+, $CADDY_OPTS}" || echo "none (route the four hosts yourself)")"
echo "  Output:          $OUT_FILE"
echo
echo "  Installing accepts the Ethora Core Software License:"
echo "  https://ethora.com/legal/ethora-core-license/"
echo
[ "$DRY_RUN" = true ] && { log "dry run, nothing written"; exit 0; }
if [ "$YES" != true ] && is_tty; then
  read -r -p "Write this configuration? [Y/n]: " _go </dev/tty
  case "$_go" in n|N|no|NO) die "aborted" ;; esac
fi

# ------------------------------------------------------------------- write --
# The answered values, as NEW_<KEY>.
set_new() { printf -v "NEW_$1" '%s' "$2"; }
set_new ROOT_DOMAIN "$A_DOMAIN"
set_new PUBLIC_URL "$A_PUBLIC_URL"
[ -n "$PORT_FROM_URL" ] && set_new HTTP_PORT "$PORT_FROM_URL"
set_new API_DOMAIN "$V_API"; set_new WEB_DOMAIN "$V_WEB"; set_new XMPP_DOMAIN "$V_XMPP"; set_new FILES_DOMAIN "$V_FILES"
set_new ADMIN_EMAIL "$A_ADMIN_EMAIL"; set_new ADMIN_PASSWORD "$A_ADMIN_PASSWORD"
set_new BASE_APP_DISPLAY_NAME "$A_DISPLAY_NAME"
set_new ETHORA_LICENSE_KEY "$A_LICENSE_KEY"; set_new ETHORA_LICENSE_CALL_HOME "$A_CALL_HOME"
set_new COMPOSE_PROFILES "$PROFILES"; set_new CADDY_GLOBAL_OPTIONS "$CADDY_OPTS"
# Secrets: kept when present, generated otherwise. Lengths follow what the
# host installer generates (64 for signing keys, 32 for the rest).
secret() { local v; v="$(old "$1")"; [ -n "$v" ] || v="${3:-}$(rand "$2")"; set_new "$1" "$v"; }
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

quote() { # plain when safe, else single-quoted (compose takes it literally)
  if [[ "$1" =~ ^[A-Za-z0-9_./:@,+=-]*$ ]]; then printf '%s' "$1"; else printf "'%s'" "$1"; fi
}

TMP="$(mktemp "$OUT_FILE.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
WRITTEN=" "
while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"; def="${BASH_REMATCH[2]}"; n="NEW_$key"
    if [ -n "${!n+x}" ]; then val="${!n}"
    elif has_old "$key"; then val="$(old "$key")"
    else val="$def"; fi
    printf '%s=%s\n' "$key" "$(quote "$val")"
    WRITTEN="$WRITTEN$key "
  else
    printf '%s\n' "$line"
  fi
done < "$TEMPLATE" > "$TMP"
# Anything the operator added to the previous .env (POSTMARK_*, ...) is kept.
extra=""
for key in $OLD_KEYS; do
  case "$WRITTEN" in *" $key "*) continue ;; esac
  WRITTEN="$WRITTEN$key "
  extra="$extra$key=$(quote "$(old "$key")")"$'\n'
done
if [ -n "$extra" ]; then
  { echo; echo "# ------------------------------------------------------------- added --"; printf '%s' "$extra" | sort; } >> "$TMP"
fi
chmod 600 "$TMP"
mv "$TMP" "$OUT_FILE"
trap - EXIT
log "wrote $OUT_FILE"

if [ "$GENERATED_PASSWORD" = true ]; then
  echo
  echo "  Admin password (generated, shown once; it is also in $OUT_FILE as ADMIN_PASSWORD):"
  echo "  $A_ADMIN_PASSWORD"
  echo
fi
echo "Next:"
echo "  docker compose up -d        # first start takes a few minutes"
echo "  docker compose logs -f init # first-boot steps; ends with 'done'"
