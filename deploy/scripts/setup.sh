#!/bin/bash
# setup.sh - generate deploy/config/deploy.yml from a handful of answers.
#
# deploy.yml has ~200 keys but a working install needs six answers: a root
# domain (every host derives from it), an admin email, and optionally a
# license key, an AI provider key, the TLS mode and which modules to enable.
# Every secret is generated. Everything else keeps the template default and
# stays hand-editable in the fully commented file this writes.
#
# One engine, two skins: this script is the engine and the terminal skin.
# The web first-boot page (setup-web/) calls it in --yes mode. Anything that
# automates an install (user-data, CloudFormation, CI) calls it in --yes mode.
#
# Usage
#   deploy/scripts/setup.sh                           interactive (prompts for what is missing)
#   deploy/scripts/setup.sh --domain chat.example.com --admin-email ops@example.com --yes
#   deploy/scripts/setup.sh --from /path/old-deploy.yml --domain chat.new.com --yes
#   deploy/scripts/setup.sh --local --yes             localhost install, no TLS
#   deploy/scripts/setup.sh ... --run                 then run install.sh --yes
#
# Answers (flag, or env ETHORA_SETUP_<NAME>, or prompt):
#   --domain ROOT            root domain: api./app./xmpp./files./playground./uptime. derive from it
#   --api/--web/--xmpp/--files/--playground/--uptime HOST   explicit host overrides
#   --admin-email EMAIL      platform admin + base app owner + Let's Encrypt contact
#   --admin-password PASS    default: generated, printed once
#   --display-name NAME      base app display name (default: Ethora)
#   --license-key KEY        ETHORA1.<payload>.<signature>; empty = Ethora Core (register later from the admin panel)
#   --license-key-file PATH  alternative to --license-key
#   --license-server URL     license server base URL (call-home)
#   --no-call-home           air-gapped install
#   --ssl certbot|provided|none   default certbot (none with --local)
#   --cert PATH --key PATH   when --ssl provided
#   --ai on|off              AI service + docs parsing (default on)
#   --ai-key KEY --ai-url URL --ai-model NAME
#   --blockchain on|off      default off
#   --uptime on|off          default on
#   --hosted-apps ROOT       enable hosted tenant apps under ROOT (advanced)
#   --target DIR             live install dir (paths.base); default sibling "ethora" of the source dir
#   --backend-mode source|image     run the API from source (PM2) or the prebuilt image (default source)
#   --frontend-mode source|image    build the admin panel from source or export it from the image
#   --api-image REF --frontend-image REF   image refs for image mode (defaults: ghcr.io/dappros/ethora-{api,frontend}:2610)
#   --ai-mode / --push-mode / --playground-mode / --mcp-mode / --ejabberd-mode source|image   the other services (default source)
#   --all-modes source|image        set every service mode at once (individual flags still win)
#   --edition core|full      core = API + admin panel + XMPP only (AI, push, playground, MCP, uptime,
#                            monitoring, widget off; images default to docker.io/dappros); full = everything (default)
#   --local                  localhost mode (starts from deploy-local.yml.template)
#   --from FILE              start from an existing deploy.yml instead of the template
#   --out FILE               where to write (default deploy/config/deploy.yml)
#   --force                  overwrite an existing --out
#   --yes                    non-interactive: never prompt, fail on missing answers
#   --dry-run                print the resolved answers and exit without writing
#   --no-validate            skip validate.sh after writing to the canonical path
#   --run                    run install.sh --yes after writing (needs sudo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
CANONICAL_OUT="$DEPLOY_DIR/config/deploy.yml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[setup]${NC} $*"; }
ok()   { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*" >&2; }
die()  { echo -e "${RED}[setup] ERROR:${NC} $*" >&2; exit 1; }

# ----------------------------------------------------------------- answers --
# Every answer has one variable. Precedence: flag > ETHORA_SETUP_<NAME> env >
# value found in --from file > prompt > default.
A_DOMAIN="${ETHORA_SETUP_DOMAIN:-}"
A_API="${ETHORA_SETUP_API:-}"; A_WEB="${ETHORA_SETUP_WEB:-}"; A_XMPP="${ETHORA_SETUP_XMPP:-}"
A_FILES="${ETHORA_SETUP_FILES:-}"; A_PLAYGROUND="${ETHORA_SETUP_PLAYGROUND:-}"; A_UPTIME_HOST="${ETHORA_SETUP_UPTIME_HOST:-}"
A_ADMIN_EMAIL="${ETHORA_SETUP_ADMIN_EMAIL:-}"
A_ADMIN_PASSWORD="${ETHORA_SETUP_ADMIN_PASSWORD:-}"
A_DISPLAY_NAME="${ETHORA_SETUP_DISPLAY_NAME:-}"
A_LICENSE_KEY="${ETHORA_SETUP_LICENSE_KEY:-}"
A_LICENSE_KEY_FILE="${ETHORA_SETUP_LICENSE_KEY_FILE:-}"
A_LICENSE_SERVER="${ETHORA_SETUP_LICENSE_SERVER:-}"
A_CALL_HOME="${ETHORA_SETUP_CALL_HOME:-}"
A_SSL="${ETHORA_SETUP_SSL:-}"
A_CERT="${ETHORA_SETUP_CERT:-}"; A_KEY="${ETHORA_SETUP_KEY:-}"
A_AI="${ETHORA_SETUP_AI:-}"
A_AI_KEY="${ETHORA_SETUP_AI_KEY:-}"; A_AI_URL="${ETHORA_SETUP_AI_URL:-}"; A_AI_MODEL="${ETHORA_SETUP_AI_MODEL:-}"
A_BLOCKCHAIN="${ETHORA_SETUP_BLOCKCHAIN:-}"
A_UPTIME="${ETHORA_SETUP_UPTIME:-}"
A_HOSTED_APPS="${ETHORA_SETUP_HOSTED_APPS:-}"
A_TARGET="${ETHORA_SETUP_TARGET:-}"
A_BACKEND_MODE="${ETHORA_SETUP_BACKEND_MODE:-}"
A_FRONTEND_MODE="${ETHORA_SETUP_FRONTEND_MODE:-}"
A_API_IMAGE="${ETHORA_SETUP_API_IMAGE:-}"; A_XMPP_IMAGE="${ETHORA_SETUP_XMPP_IMAGE:-}"
A_FRONTEND_IMAGE="${ETHORA_SETUP_FRONTEND_IMAGE:-}"
A_AI_MODE="${ETHORA_SETUP_AI_MODE:-}"; A_PUSH_MODE="${ETHORA_SETUP_PUSH_MODE:-}"
A_PLAYGROUND_MODE="${ETHORA_SETUP_PLAYGROUND_MODE:-}"; A_MCP_MODE="${ETHORA_SETUP_MCP_MODE:-}"; A_EJABBERD_MODE="${ETHORA_SETUP_EJABBERD_MODE:-}"
A_ALL_MODES="${ETHORA_SETUP_ALL_MODES:-}"
A_EDITION="${ETHORA_SETUP_EDITION:-}"

MODE_LOCAL=false; FROM_FILE=""; OUT_FILE="$CANONICAL_OUT"; FORCE=false; YES=false
DRY_RUN=false; VALIDATE=true; RUN_INSTALL=false

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) A_DOMAIN="$2"; shift 2 ;;
    --api) A_API="$2"; shift 2 ;;
    --web) A_WEB="$2"; shift 2 ;;
    --xmpp) A_XMPP="$2"; shift 2 ;;
    --files) A_FILES="$2"; shift 2 ;;
    --playground) A_PLAYGROUND="$2"; shift 2 ;;
    --uptime-host) A_UPTIME_HOST="$2"; shift 2 ;;
    --admin-email) A_ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) A_ADMIN_PASSWORD="$2"; shift 2 ;;
    --display-name) A_DISPLAY_NAME="$2"; shift 2 ;;
    --license-key) A_LICENSE_KEY="$2"; shift 2 ;;
    --license-key-file) A_LICENSE_KEY_FILE="$2"; shift 2 ;;
    --license-server) A_LICENSE_SERVER="$2"; shift 2 ;;
    --no-call-home) A_CALL_HOME="false"; shift ;;
    --ssl) A_SSL="$2"; shift 2 ;;
    --cert) A_CERT="$2"; shift 2 ;;
    --key) A_KEY="$2"; shift 2 ;;
    --ai) A_AI="$2"; shift 2 ;;
    --ai-key) A_AI_KEY="$2"; shift 2 ;;
    --ai-url) A_AI_URL="$2"; shift 2 ;;
    --ai-model) A_AI_MODEL="$2"; shift 2 ;;
    --blockchain) A_BLOCKCHAIN="$2"; shift 2 ;;
    --uptime) A_UPTIME="$2"; shift 2 ;;
    --hosted-apps) A_HOSTED_APPS="$2"; shift 2 ;;
    --target) A_TARGET="$2"; shift 2 ;;
    --backend-mode) A_BACKEND_MODE="$2"; shift 2 ;;
    --frontend-mode) A_FRONTEND_MODE="$2"; shift 2 ;;
    --api-image) A_API_IMAGE="$2"; shift 2 ;;
    --frontend-image) A_FRONTEND_IMAGE="$2"; shift 2 ;;
    --xmpp-image) A_XMPP_IMAGE="$2"; shift 2 ;;
    --ai-mode) A_AI_MODE="$2"; shift 2 ;;
    --push-mode) A_PUSH_MODE="$2"; shift 2 ;;
    --playground-mode) A_PLAYGROUND_MODE="$2"; shift 2 ;;
    --mcp-mode) A_MCP_MODE="$2"; shift 2 ;;
    --ejabberd-mode) A_EJABBERD_MODE="$2"; shift 2 ;;
    --all-modes) A_ALL_MODES="$2"; shift 2 ;;
    --edition) A_EDITION="$2"; shift 2 ;;
    --local) MODE_LOCAL=true; shift ;;
    --from) FROM_FILE="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --yes|--non-interactive|-y) YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-validate) VALIDATE=false; shift ;;
    --run) RUN_INSTALL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# yq v4 (mikefarah). Distributions ship the unrelated v3 under the same name,
# and this script runs before install.sh (which installs v4 itself), so put
# the right one in place here: /usr/local/bin comes first on PATH.
ensure_yq() {
  if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -qE "version v?4\."; then return 0; fi
  local arch url
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "yq v4 is required (https://github.com/mikefarah/yq); install it for $(uname -m) and re-run" ;; esac
  url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
  echo "[setup] yq v4 is required$(command -v yq >/dev/null 2>&1 && echo " (found: $(yq --version 2>/dev/null))"); installing it to /usr/local/bin/yq" >&2
  local sudo=""; [ "$(id -u)" = 0 ] || sudo=sudo
  $sudo sh -c "curl -fsSL '$url' -o /usr/local/bin/yq.new && chmod 755 /usr/local/bin/yq.new && mv /usr/local/bin/yq.new /usr/local/bin/yq" \
    || die "could not install yq v4; run: sudo wget -qO /usr/local/bin/yq $url && sudo chmod +x /usr/local/bin/yq"
  hash -r
  yq --version 2>/dev/null | grep -qE "version v?4\." || die "yq v4 is required; /usr/local/bin/yq is $(yq --version 2>/dev/null)"
}
ensure_yq

# ----------------------------------------------------------------- helpers --
is_tty() { [ -t 0 ] && [ -t 1 ]; }

# prompt VAR "question" "default": only when interactive and VAR is empty.
prompt() {
  local var="$1" q="$2" def="${3:-}" ans
  [ -n "${!var}" ] && return 0
  if [ "$YES" = true ] || ! is_tty; then
    printf -v "$var" '%s' "$def"
    return 0
  fi
  if [ -n "$def" ]; then
    read -r -p "$q [$def]: " ans </dev/tty
  else
    read -r -p "$q: " ans </dev/tty
  fi
  printf -v "$var" '%s' "${ans:-$def}"
}

# yq-based reader for the --from file ("" when absent/null).
from_val() {
  [ -n "$FROM_FILE" ] || { echo ""; return; }
  local v; v="$(yq eval "$1 // \"\"" "$FROM_FILE" 2>/dev/null || true)"
  [ "$v" = "null" ] && v=""
  echo "$v"
}

norm_host() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*$##; s#:[0-9]+$##; s#\.$##; s#^[[:space:]]+|[[:space:]]+$##g'; }
valid_host() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || [ "$1" = "localhost" ]; }
valid_email() { [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || [[ "$1" =~ ^[^[:space:]@]+@localhost$ ]]; }
valid_key() { [[ "$1" =~ ^ETHORA1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; }
onoff() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in on|true|yes|1) echo true ;; off|false|no|0) echo false ;; *) return 1 ;; esac; }
gen_password() { openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 20; }

# ------------------------------------------------------------ gather answers --
if [ -n "$FROM_FILE" ]; then
  [ -f "$FROM_FILE" ] || die "--from file not found: $FROM_FILE"
  log "starting from $FROM_FILE (its values are kept unless you answer differently)"
fi

if [ "$MODE_LOCAL" = true ]; then
  A_DOMAIN="localhost"
fi

# Root domain. Derive a default from an imported file's web host (app.X -> X).
_from_web="$(from_val '.domains.web')"
if [ -z "$A_DOMAIN" ] && [ -n "$_from_web" ]; then
  A_DOMAIN="${_from_web#app.}"
fi
if [ "$YES" != true ] && is_tty && [ -z "$A_DOMAIN" ]; then
  echo
  echo "Ethora setup. Six questions; everything else is derived or generated."
  echo "Root domain: the four service hosts derive from it, e.g. chat.example.com ->"
  echo "  api.chat.example.com, app.chat.example.com, xmpp.chat.example.com, files.chat.example.com"
  echo
fi
prompt A_DOMAIN "Root domain (or 'localhost' for a local install)" ""
A_DOMAIN="$(norm_host "$A_DOMAIN")"
[ -n "$A_DOMAIN" ] || die "a root domain is required (--domain chat.example.com, or --local)"
valid_host "$A_DOMAIN" || die "not a valid domain: $A_DOMAIN"
[ "$A_DOMAIN" = "localhost" ] && MODE_LOCAL=true

if [ "$MODE_LOCAL" = true ]; then
  A_API="localhost"; A_WEB="localhost"; A_XMPP="localhost"; A_FILES="localhost"; A_PLAYGROUND="localhost"; A_UPTIME_HOST="localhost"
else
  A_API="$(norm_host "${A_API:-api.$A_DOMAIN}")"
  A_WEB="$(norm_host "${A_WEB:-app.$A_DOMAIN}")"
  A_XMPP="$(norm_host "${A_XMPP:-xmpp.$A_DOMAIN}")"
  A_FILES="$(norm_host "${A_FILES:-files.$A_DOMAIN}")"
  A_PLAYGROUND="$(norm_host "${A_PLAYGROUND:-playground.$A_DOMAIN}")"
  A_UPTIME_HOST="$(norm_host "${A_UPTIME_HOST:-uptime.$A_DOMAIN}")"
  for h in "$A_API" "$A_WEB" "$A_XMPP" "$A_FILES" "$A_PLAYGROUND" "$A_UPTIME_HOST"; do
    valid_host "$h" || die "not a valid host: $h"
  done
fi

prompt A_ADMIN_EMAIL "Admin email (platform admin, base app owner, TLS contact)" "$(from_val '.admin.email')"
[ "$MODE_LOCAL" = true ] && [ -z "$A_ADMIN_EMAIL" ] && A_ADMIN_EMAIL="admin@localhost"
[ -n "$A_ADMIN_EMAIL" ] || die "an admin email is required (--admin-email)"
valid_email "$A_ADMIN_EMAIL" || die "not a valid email: $A_ADMIN_EMAIL"

GENERATED_PASSWORD=false
if [ -z "$A_ADMIN_PASSWORD" ]; then
  _from_pw="$(from_val '.admin.password')"
  if [ -n "$_from_pw" ] && [ "$_from_pw" != "admin123" ]; then
    A_ADMIN_PASSWORD="$_from_pw"
  else
    A_ADMIN_PASSWORD="$(gen_password)"; GENERATED_PASSWORD=true
  fi
fi

prompt A_DISPLAY_NAME "Product display name" "$(from_val '.base_app.display_name')"
A_DISPLAY_NAME="${A_DISPLAY_NAME:-Ethora}"

# License. Empty is a valid answer (14-day grace window).
if [ -n "$A_LICENSE_KEY_FILE" ]; then
  [ -f "$A_LICENSE_KEY_FILE" ] || die "--license-key-file not found: $A_LICENSE_KEY_FILE"
elif [ -z "$A_LICENSE_KEY" ]; then
  _from_key="$(from_val '.license.key')"
  if [ -n "$_from_key" ]; then
    A_LICENSE_KEY="$_from_key"
  elif [ "$MODE_LOCAL" != true ]; then
    prompt A_LICENSE_KEY "License key (leave empty for a 14-day trial)" ""
  fi
fi
A_LICENSE_KEY="$(printf '%s' "$A_LICENSE_KEY" | tr -d '[:space:]')"
if [ -n "$A_LICENSE_KEY" ] && ! valid_key "$A_LICENSE_KEY"; then
  die "license key does not look like an Ethora key (expected ETHORA1.<payload>.<signature>)"
fi
[ -z "$A_LICENSE_SERVER" ] && A_LICENSE_SERVER="$(from_val '.license.server_url')"
if [ -n "$A_LICENSE_SERVER" ] && ! [[ "$A_LICENSE_SERVER" =~ ^https?:// ]]; then
  die "--license-server must be an http(s) URL"
fi
[ -z "$A_CALL_HOME" ] && A_CALL_HOME="$(from_val '.license.call_home')"
A_CALL_HOME="${A_CALL_HOME:-true}"

# TLS.
if [ "$MODE_LOCAL" = true ]; then
  A_SSL="${A_SSL:-none}"
else
  [ -z "$A_SSL" ] && A_SSL="$(from_val '.ssl.method')"
  prompt A_SSL "TLS: certbot (Let's Encrypt, DNS must already point here) | provided | none" "certbot"
fi
case "$A_SSL" in
  certbot|provided|none) ;;
  *) die "--ssl must be certbot, provided or none (got: $A_SSL)" ;;
esac
if [ "$A_SSL" = "provided" ]; then
  [ -z "$A_CERT" ] && A_CERT="$(from_val '.ssl.cert_path')"
  [ -z "$A_KEY" ] && A_KEY="$(from_val '.ssl.key_path')"
  prompt A_CERT "Path to fullchain certificate (PEM)" ""
  prompt A_KEY "Path to private key (PEM)" ""
  [ -n "$A_CERT" ] && [ -n "$A_KEY" ] || die "--ssl provided needs --cert and --key"
fi

# Modules.
# Edition. core = the three published images and their databases, nothing
# else; everything optional is switched off so the installer never looks for
# a module that is not there. Explicit flags given on the command line still
# win for AI, blockchain and uptime.
A_EDITION="${A_EDITION:-$(from_val '.edition')}"; A_EDITION="${A_EDITION:-full}"
case "$A_EDITION" in core|full) ;; *) die "--edition must be core or full" ;; esac
if [ "$A_EDITION" = "core" ]; then
  [ -z "$A_AI" ] && A_AI="off"
  [ -z "$A_UPTIME" ] && A_UPTIME="off"
  [ -z "$A_BLOCKCHAIN" ] && A_BLOCKCHAIN="off"
fi
if [ -z "$A_AI" ]; then
  _from_ai="$(from_val '.features.ai_service')"
  [ -n "$_from_ai" ] && A_AI="$_from_ai"
fi
prompt A_AI "Enable AI agents and document parsing? (on/off)" "on"
A_AI="$(onoff "$A_AI")" || die "--ai must be on or off"
if [ "$A_AI" = true ]; then
  [ -z "$A_AI_KEY" ] && A_AI_KEY="$(from_val '.ai.ai_api_key')"
  [ -z "$A_AI_URL" ] && A_AI_URL="$(from_val '.ai.ai_api_url')"
  [ -z "$A_AI_MODEL" ] && A_AI_MODEL="$(from_val '.ai.chat_model')"
  prompt A_AI_KEY "AI provider API key (OpenAI-compatible; leave empty for an unauthenticated/self-hosted endpoint)" ""
fi
if [ -z "$A_BLOCKCHAIN" ]; then
  _from_bc="$(from_val '.features.blockchain')"
  [ -n "$_from_bc" ] && A_BLOCKCHAIN="$_from_bc"
fi
A_BLOCKCHAIN="$(onoff "${A_BLOCKCHAIN:-off}")" || die "--blockchain must be on or off"
if [ -z "$A_UPTIME" ]; then
  _from_up="$(from_val '.services.uptime.enabled')"
  [ -n "$_from_up" ] && A_UPTIME="$_from_up"
fi
A_UPTIME="$(onoff "${A_UPTIME:-on}")" || die "--uptime must be on or off"
[ -z "$A_HOSTED_APPS" ] && A_HOSTED_APPS="$(from_val '.domains.hosted_apps_root')"
if [ -n "$A_HOSTED_APPS" ]; then
  A_HOSTED_APPS="$(norm_host "$A_HOSTED_APPS")"
  valid_host "$A_HOSTED_APPS" || die "--hosted-apps must be a domain"
fi

# Paths. preflight-paths.sh refuses in-place installs, so the live tree
# defaults to a sibling of the source checkout named "ethora".
if [ -z "$A_TARGET" ]; then
  A_TARGET="$(from_val '.paths.base')"
fi
if [ -z "$A_TARGET" ]; then
  if [ "$(basename "$SOURCE_ROOT")" = "ethora" ]; then
    A_TARGET="$(dirname "$SOURCE_ROOT")/ethora-live"
  else
    A_TARGET="$(dirname "$SOURCE_ROOT")/ethora"
  fi
fi
case "$A_TARGET" in /*) ;; *) die "--target must be an absolute path: $A_TARGET" ;; esac

# Run modes. --all-modes seeds every service; individual flags override it;
# an imported file supplies the rest; default source.
if [ -n "$A_ALL_MODES" ]; then
  case "$A_ALL_MODES" in source|image) ;; *) die "--all-modes must be source or image" ;; esac
fi
[ -z "$A_BACKEND_MODE" ] && A_BACKEND_MODE="${A_ALL_MODES:-$(from_val '.services.backend.mode')}"
[ -z "$A_FRONTEND_MODE" ] && A_FRONTEND_MODE="${A_ALL_MODES:-$(from_val '.services.frontend.mode')}"
[ -z "$A_AI_MODE" ] && A_AI_MODE="${A_ALL_MODES:-$(from_val '.services.ai_service.mode')}"
[ -z "$A_PUSH_MODE" ] && A_PUSH_MODE="${A_ALL_MODES:-$(from_val '.services.push.mode')}"
[ -z "$A_PLAYGROUND_MODE" ] && A_PLAYGROUND_MODE="${A_ALL_MODES:-$(from_val '.services.playground.mode')}"
[ -z "$A_MCP_MODE" ] && A_MCP_MODE="${A_ALL_MODES:-$(from_val '.services.mcp.mode')}"
[ -z "$A_EJABBERD_MODE" ] && A_EJABBERD_MODE="${A_ALL_MODES:-$(from_val '.services.ejabberd.mode')}"
A_BACKEND_MODE="${A_BACKEND_MODE:-source}"; A_FRONTEND_MODE="${A_FRONTEND_MODE:-source}"
A_AI_MODE="${A_AI_MODE:-source}"; A_PUSH_MODE="${A_PUSH_MODE:-source}"
A_PLAYGROUND_MODE="${A_PLAYGROUND_MODE:-source}"; A_MCP_MODE="${A_MCP_MODE:-source}"; A_EJABBERD_MODE="${A_EJABBERD_MODE:-source}"
for m in "$A_BACKEND_MODE" "$A_FRONTEND_MODE" "$A_AI_MODE" "$A_PUSH_MODE" "$A_PLAYGROUND_MODE" "$A_MCP_MODE" "$A_EJABBERD_MODE"; do
  case "$m" in source|image) ;; *) die "service modes must be source or image (got: $m)" ;; esac
done
[ -z "$A_API_IMAGE" ] && A_API_IMAGE="$(from_val '.services.backend.image')"
[ -z "$A_FRONTEND_IMAGE" ] && A_FRONTEND_IMAGE="$(from_val '.services.frontend.image')"
[ -z "$A_XMPP_IMAGE" ] && A_XMPP_IMAGE="$(from_val '.services.ejabberd.image')"
if [ "$A_EDITION" = "core" ]; then
  # Public images live on Docker Hub; the template defaults point at GHCR.
  case "$A_API_IMAGE" in ""|ghcr.io/*) A_API_IMAGE="docker.io/dappros/ethora-api:2610" ;; esac
  case "$A_FRONTEND_IMAGE" in ""|ghcr.io/*) A_FRONTEND_IMAGE="docker.io/dappros/ethora-frontend:2610" ;; esac
  case "$A_XMPP_IMAGE" in ""|ghcr.io/*) A_XMPP_IMAGE="docker.io/dappros/ethora-xmpp:2610" ;; esac
fi
A_API_IMAGE="${A_API_IMAGE:-ghcr.io/dappros/ethora-api:2610}"
A_FRONTEND_IMAGE="${A_FRONTEND_IMAGE:-ghcr.io/dappros/ethora-frontend:2610}"
A_XMPP_IMAGE="${A_XMPP_IMAGE:-ghcr.io/dappros/ethora-xmpp:2610}"
[ "$A_TARGET" = "$SOURCE_ROOT" ] && die "--target must differ from the source checkout ($SOURCE_ROOT); in-place installs are refused by preflight-paths.sh"

# ------------------------------------------------------------------ report --
show_summary() {
  echo
  echo "  Mode:            $([ "$MODE_LOCAL" = true ] && echo localhost || echo production)    Edition: $A_EDITION"
  echo "  Hosts:           api=$A_API web=$A_WEB xmpp=$A_XMPP files=$A_FILES"
  echo "                   playground=$A_PLAYGROUND uptime=$A_UPTIME_HOST"
  echo "  Admin:           $A_ADMIN_EMAIL  ($([ "$GENERATED_PASSWORD" = true ] && echo "password generated" || echo "password supplied"))"
  echo "  Display name:    $A_DISPLAY_NAME"
  echo "  License:         $([ -n "$A_LICENSE_KEY_FILE" ] && echo "file $A_LICENSE_KEY_FILE" || ([ -n "$A_LICENSE_KEY" ] && echo "key ${A_LICENSE_KEY:0:24}..." || echo "none (Ethora Core; register from the admin panel)"))  call-home=$A_CALL_HOME${A_LICENSE_SERVER:+ server=$A_LICENSE_SERVER}"
  echo "  TLS:             $A_SSL${A_CERT:+ ($A_CERT)}"
  echo "  AI:              $A_AI${A_AI_KEY:+ (key set)}${A_AI_URL:+ url=$A_AI_URL}${A_AI_MODEL:+ model=$A_AI_MODEL}"
  echo "  Blockchain:      $A_BLOCKCHAIN    Uptime: $A_UPTIME    Hosted apps: ${A_HOSTED_APPS:-off}"
  echo
  echo "  Installing accepts the Ethora Core Software License: docs/legal/ETHORA_CORE_LICENSE.md"
  echo "  (editions and limits: docs/legal/FEATURE_SCHEDULE.md)."
  echo "  Run modes:       backend=$A_BACKEND_MODE$([ "$A_BACKEND_MODE" = image ] && echo " ($A_API_IMAGE)")  frontend=$A_FRONTEND_MODE$([ "$A_FRONTEND_MODE" = image ] && echo " ($A_FRONTEND_IMAGE)")"
  echo "                   ai=$A_AI_MODE  push=$A_PUSH_MODE  playground=$A_PLAYGROUND_MODE  mcp=$A_MCP_MODE  ejabberd=$A_EJABBERD_MODE"
  echo "  Source / target: $SOURCE_ROOT -> $A_TARGET"
  echo "  Output:          $OUT_FILE"
  echo
}
show_summary
[ "$DRY_RUN" = true ] && { ok "dry run, nothing written"; exit 0; }

if [ "$YES" != true ] && is_tty; then
  read -r -p "Write this configuration? [Y/n]: " _go </dev/tty
  case "$_go" in n|N|no|NO) die "aborted" ;; esac
fi

# ------------------------------------------------------------------- write --
if [ -f "$OUT_FILE" ] && [ "$FORCE" != true ]; then
  if [ -n "$FROM_FILE" ] && [ "$(cd "$(dirname "$FROM_FILE")" && pwd)/$(basename "$FROM_FILE")" = "$(cd "$(dirname "$OUT_FILE")" && pwd)/$(basename "$OUT_FILE")" ]; then
    : # rewriting the file we imported from is the expected "reconfigure" flow
  else
    die "$OUT_FILE exists; pass --force to overwrite, or --from $OUT_FILE to reconfigure it"
  fi
fi
mkdir -p "$(dirname "$OUT_FILE")"
TMP="$(mktemp "${OUT_FILE}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

if [ -n "$FROM_FILE" ]; then
  cp "$FROM_FILE" "$TMP"
elif [ "$MODE_LOCAL" = true ]; then
  cp "$DEPLOY_DIR/config/deploy-local.yml.template" "$TMP"
else
  cp "$DEPLOY_DIR/config/deploy.yml.template" "$TMP"
fi

# yq -i keeps every comment in the template, so the written file stays a
# readable reference. Values are passed through env to avoid quoting issues.
set_str()  { local path="$1"; V="$2" yq eval -i "$path = strenv(V)" "$TMP"; }
set_bool() { local path="$1"; yq eval -i "$path = $2" "$TMP"; }

set_str '.domains.api' "$A_API"
set_str '.domains.web' "$A_WEB"
set_str '.domains.xmpp' "$A_XMPP"
set_str '.domains.files' "$A_FILES"
set_str '.domains.playground' "$A_PLAYGROUND"
set_str '.domains.uptime' "$A_UPTIME_HOST"
if [ -n "$A_HOSTED_APPS" ]; then
  set_str '.domains.hosted_apps_root' "$A_HOSTED_APPS"
  set_bool '.services.hosted_apps.enabled' true
fi

set_str '.ssl.method' "$A_SSL"
set_str '.ssl.email' "$A_ADMIN_EMAIL"
if [ "$A_SSL" = "provided" ]; then
  set_str '.ssl.cert_path' "$A_CERT"
  set_str '.ssl.key_path' "$A_KEY"
fi

set_str '.admin.email' "$A_ADMIN_EMAIL"
set_str '.admin.password' "$A_ADMIN_PASSWORD"
set_str '.base_app.owner_email' "$A_ADMIN_EMAIL"
set_str '.base_app.display_name' "$A_DISPLAY_NAME"

set_str '.license.key' "$A_LICENSE_KEY"
set_str '.license.key_file' "$A_LICENSE_KEY_FILE"
set_str '.license.server_url' "$A_LICENSE_SERVER"
set_bool '.license.call_home' "$A_CALL_HOME"

set_bool '.features.ai_service' "$A_AI"
set_bool '.services.ai_service.enabled' "$A_AI"
set_bool '.services.docs_parse_service.enabled' "$A_AI"
if [ "$A_AI" = true ]; then
  [ -n "$A_AI_KEY" ]   && set_str '.ai.ai_api_key' "$A_AI_KEY"
  [ -n "$A_AI_URL" ]   && set_str '.ai.ai_api_url' "$A_AI_URL"
  [ -n "$A_AI_MODEL" ] && set_str '.ai.chat_model' "$A_AI_MODEL"
fi
set_bool '.features.blockchain' "$A_BLOCKCHAIN"
set_bool '.services.uptime.enabled' "$A_UPTIME"

set_str '.paths.source' "$SOURCE_ROOT"
set_str '.paths.base' "$A_TARGET"

set_str '.services.backend.mode' "$A_BACKEND_MODE"
set_str '.services.backend.image' "$A_API_IMAGE"
set_str '.services.frontend.mode' "$A_FRONTEND_MODE"
set_str '.services.frontend.image' "$A_FRONTEND_IMAGE"
set_str '.services.ai_service.mode' "$A_AI_MODE"
set_str '.services.push.mode' "$A_PUSH_MODE"
set_str '.services.playground.mode' "$A_PLAYGROUND_MODE"
set_str '.services.mcp.mode' "$A_MCP_MODE"
set_str '.services.ejabberd.mode' "$A_EJABBERD_MODE"
set_str '.services.ejabberd.image' "$A_XMPP_IMAGE"
set_str '.edition' "$A_EDITION"
if [ "$A_EDITION" = "core" ]; then
  set_bool '.services.push.enabled' false
  set_bool '.services.playground.enabled' false
  set_bool '.services.mcp.enabled' false
  set_bool '.services.widget.enabled' false
  set_bool '.services.monitoring.enabled' false
  set_bool '.services.hosted_apps.enabled' false
  set_bool '.services.ai_service.enabled' false
  set_bool '.services.crawler.enabled' false
fi

chmod 600 "$TMP"
mv "$TMP" "$OUT_FILE"
trap - EXIT
ok "wrote $OUT_FILE"

if [ "$GENERATED_PASSWORD" = true ]; then
  echo
  echo -e "  ${YELLOW}Admin password (generated, shown once; it is also in $OUT_FILE under admin.password):${NC}"
  echo "  $A_ADMIN_PASSWORD"
  echo
fi

# ---------------------------------------------------------------- validate --
if [ "$VALIDATE" = true ] && [ "$OUT_FILE" = "$CANONICAL_OUT" ] && [ -x "$SCRIPT_DIR/validate.sh" ]; then
  log "running validate.sh"
  if ! VALIDATE_PRE_INSTALL=true "$SCRIPT_DIR/validate.sh"; then
    die "validate.sh reported problems; fix $OUT_FILE and re-run (or re-run setup.sh --from $OUT_FILE)"
  fi
fi

# --------------------------------------------------------------------- run --
if [ "$RUN_INSTALL" = true ]; then
  [ "$OUT_FILE" = "$CANONICAL_OUT" ] || die "--run needs the config at $CANONICAL_OUT (drop --out)"
  log "running install.sh --yes"
  if [ "$(id -u)" -eq 0 ]; then
    exec "$SCRIPT_DIR/install.sh" --yes
  else
    exec sudo "$SCRIPT_DIR/install.sh" --yes
  fi
fi

echo "Next:"
if [ "$OUT_FILE" = "$CANONICAL_OUT" ]; then
  echo "  sudo $SCRIPT_DIR/install.sh          # first install"
  echo "  $SCRIPT_DIR/setup.sh --from $OUT_FILE ...   # change answers later"
else
  echo "  review $OUT_FILE, then copy it to $CANONICAL_OUT and run sudo $SCRIPT_DIR/install.sh"
fi
