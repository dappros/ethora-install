#!/bin/bash
# install.sh - first-boot install of Ethora Core from the compose bundle on a
# cloud image (AWS, Azure, DigitalOcean, Vultr, Akamai). One engine, three
# skins: the setup page (deploy/setup-web, compose mode) calls it with the
# answers from its form, the AWS CloudFormation template and the Akamai
# StackScript call it from user data, and an operator can run it over SSH.
#
#   deploy/cloud/install.sh --domain chat.example.com --admin-email ops@example.com
#
# Answers (flag, or env ETHORA_SETUP_<NAME>):
#   --domain ROOT            root domain; api./app./xmpp./files./secure-files. derive from it
#   --admin-email EMAIL      platform admin, base app owner, Let's Encrypt contact
#   --admin-password PASS    default: generated, printed once
#   --display-name NAME      product name in the web app (default: Ethora)
#   --license-key KEY        Enterprise key; empty = Ethora Core (free)
#   --secure-files off       keep chat attachments in the public files bucket (four hosts)
#   --no-verify              skip the end-to-end check at the end
#   --dry-run                resolve the answers, write and start nothing
#
# What it does: ./configure.sh --yes in deploy/compose (writes .env, every
# secret generated; re-running keeps them), docker compose up -d, waits for
# the first-boot init to finish, waits for the web app to answer over https
# (Caddy obtains the certificates), runs the bundle's verify, writes the
# done marker the setup page checks, and leaves a message of the day. Every
# image is on the cloud image already, so no registry is contacted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ETHORA_INSTALL_ROOT:-$(cd "$HERE/../.." && pwd)}"
BUNDLE="$ROOT/deploy/compose"
DONE_FILE="${ETHORA_DONE_FILE:-/etc/ethora/setup-done}"
INIT_TIMEOUT="${ETHORA_INIT_TIMEOUT:-1200}"     # seconds for the first-boot init
WEB_TIMEOUT="${ETHORA_WEB_TIMEOUT:-600}"        # seconds for https://app.<root>/ (certificates)

log() { echo "[cloud-install] $*"; }
die() { echo "[cloud-install] ERROR: $*" >&2; exit 1; }

A_DOMAIN="${ETHORA_SETUP_DOMAIN:-}"; A_EMAIL="${ETHORA_SETUP_ADMIN_EMAIL:-}"
A_PASSWORD="${ETHORA_SETUP_ADMIN_PASSWORD:-}"; A_NAME="${ETHORA_SETUP_DISPLAY_NAME:-}"
A_KEY="${ETHORA_SETUP_LICENSE_KEY:-}"; A_SECURE="${ETHORA_SETUP_SECURE_FILES:-}"
VERIFY=true; DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) A_DOMAIN="$2"; shift 2 ;;
    --admin-email) A_EMAIL="$2"; shift 2 ;;
    --admin-password) A_PASSWORD="$2"; shift 2 ;;
    --display-name) A_NAME="$2"; shift 2 ;;
    --license-key) A_KEY="$2"; shift 2 ;;
    --secure-files) A_SECURE="$2"; shift 2 ;;
    --no-verify) VERIFY=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -f "$BUNDLE/configure.sh" ] || die "compose bundle not found at $BUNDLE"
command -v docker >/dev/null 2>&1 || die "docker is not installed"
[ -n "$A_DOMAIN" ] || die "a root domain is required (--domain)"
[ -n "$A_EMAIL" ] || die "an admin email is required (--admin-email)"
A_DOMAIN="$(printf '%s' "$A_DOMAIN" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*$##')"

args=(--domain "$A_DOMAIN" --admin-email "$A_EMAIL" --yes)
[ -n "$A_PASSWORD" ] && args+=(--admin-password "$A_PASSWORD")
[ -n "$A_NAME" ] && args+=(--display-name "$A_NAME")
[ -n "$A_KEY" ] && args+=(--license-key "$A_KEY")
[ -n "$A_SECURE" ] && args+=(--secure-files "$A_SECURE")
[ "$DRY_RUN" = true ] && args+=(--dry-run)

cd "$BUNDLE" || die "cannot enter $BUNDLE"
log "$(date -u +%FT%TZ) configure: root domain $A_DOMAIN, admin $A_EMAIL$([ -n "$A_KEY" ] && echo ', license key given' || echo ', Ethora Core (free)')"
# configure.sh prints the generated admin password once; it is kept in .env.
./configure.sh "${args[@]}" || die "configure.sh failed"
if [ "$DRY_RUN" = true ]; then log "dry run: nothing written, nothing started"; exit 0; fi

log "$(date -u +%FT%TZ) starting the stack (docker compose up -d)"
docker compose up -d || die "docker compose up failed"

# The init service runs the first-boot steps and exits 0; stream its log
# while waiting for it.
log "waiting for the first-boot init (base app, admin account, XMPP accounts)"
docker compose logs -f --no-log-prefix init 2>/dev/null &
logpid=$!
rc=""; t=0
while [ $t -lt "$INIT_TIMEOUT" ]; do
  # -a: the init container has exited by then, and `ps -q` lists running ones only.
  cid="$(docker compose ps -aq init 2>/dev/null | head -n 1)"
  if [ -n "$cid" ]; then
    st="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$cid" 2>/dev/null || true)"
    case "$st" in exited\ *) rc="${st#exited }"; break ;; esac
  fi
  sleep 5; t=$((t + 5))
done
kill "$logpid" 2>/dev/null; wait "$logpid" 2>/dev/null
[ -n "$rc" ] || die "the first-boot init did not finish within $INIT_TIMEOUT s (docker compose logs init)"
[ "$rc" = 0 ] || die "the first-boot init failed (exit $rc); see: docker compose logs init"

APP_URL="https://app.$A_DOMAIN"
log "$(date -u +%FT%TZ) waiting for $APP_URL (Let's Encrypt certificates for the five hosts)"
t=0; ok=false
while [ $t -lt "$WEB_TIMEOUT" ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$APP_URL/" 2>/dev/null || true)"
  [ "$code" = 200 ] && { ok=true; break; }
  sleep 10; t=$((t + 10))
done
if [ "$ok" = true ]; then log "web app answers at $APP_URL"
else log "WARN: $APP_URL did not answer 200 within $WEB_TIMEOUT s; DNS for the five hosts may not point here yet (docker compose logs caddy)"; fi

if [ "$VERIFY" = true ] && [ "$ok" = true ]; then
  log "$(date -u +%FT%TZ) end-to-end check (docker compose --profile verify run --rm verify)"
  if docker compose --profile verify run --rm verify; then log "verify passed"
  else log "WARN: verify reported failures (the install is up; see the lines above)"; fi
fi

mkdir -p "$(dirname "$DONE_FILE")" 2>/dev/null && date -u +%FT%TZ > "$DONE_FILE" 2>/dev/null || true
# Message of the day for images without one of their own (DigitalOcean and
# Vultr ship a 99-one-click that already branches on the done marker).
if [ -d /etc/update-motd.d ] && [ ! -f /etc/update-motd.d/99-one-click ] && [ -w /etc/update-motd.d ]; then
  cat > /etc/update-motd.d/98-ethora <<MSG
#!/bin/sh
cat <<EOM
********************************************************************************
Ethora Core is installed. Web app and admin panel: $APP_URL
Settings: $BUNDLE/.env (then: docker compose up -d --force-recreate)
Update:   cd $BUNDLE && git -C $ROOT pull && docker compose pull && docker compose up -d
Data:     Docker volumes ethora_mongo, ethora_mysql, ethora_minio, ethora_redis,
          ethora_caddy-data, ethora_secrets (backup steps: $BUNDLE/README.md)
Docs:     https://github.com/dappros/ethora-install
********************************************************************************
EOM
MSG
  chmod +x /etc/update-motd.d/98-ethora
fi
log "$(date -u +%FT%TZ) install complete: $APP_URL (admin $A_EMAIL; the password was printed above and is ADMIN_PASSWORD in $BUNDLE/.env)"
exit 0
