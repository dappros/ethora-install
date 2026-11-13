#!/usr/bin/env bash
# get.sh - install Ethora on a fresh server with one command.
#
#   curl -fsSL https://raw.githubusercontent.com/dappros/ethora-install/main/deploy/compose/get.sh | sudo bash
#   ... | sudo bash -s -- --web                     answer in the browser instead of here
#   ... | sudo bash -s -- --domain chat.example.com --admin-email ops@example.com --yes
#
# What it does, in order:
#   1. checks the server (Linux, memory, disk, ports 80 and 443)
#   2. installs Docker (get.docker.com) and git when they are missing
#   3. fetches the install bundle into /opt/ethora (ETHORA_DIR), or updates it
#   4. asks four questions here (domain, admin email, licence key, AI key), or
#      with --web serves the setup page on port 8888 (one-time password below)
#   5. runs deploy/cloud/install.sh: writes .env, starts the stack, waits for
#      the first boot and the certificates, checks every service
#
# Options (anything else goes to deploy/cloud/install.sh, see its --help):
#   --web                    setup page in the browser (installs Node.js for it)
#   --domain ROOT            root domain; `auto` (the default answer) = <public IP>.sslip.io
#   --admin-email EMAIL      platform admin and Let's Encrypt contact
#   --license-key KEY        Enterprise licence; empty = Ethora Core (free)
#   --modules LIST           with a licence: ai,push,playground,mcp,uptime,calls
#   --ai-api-key KEY         ai module: OpenAI-compatible provider key
#   --yes                    no questions; fail on a missing answer
#   --dir DIR                where the bundle goes (default /opt/ethora)
#   --ref BRANCH             bundle branch (default main)
set -euo pipefail

REPO="${ETHORA_REPO:-https://github.com/dappros/ethora-install.git}"
DIR="${ETHORA_DIR:-/opt/ethora}"
REF="${ETHORA_REF:-main}"
WEB=false; YES=false
DOMAIN=""; EMAIL=""; KEY=""; MODULES=""; AIKEY=""
PASS=()

say()  { printf '\033[1m[ethora]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[ethora] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m[ethora] %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --web) WEB=true; shift ;;
    --yes|-y) YES=true; shift ;;
    --dir) DIR="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --admin-email) EMAIL="$2"; shift 2 ;;
    --license-key) KEY="$2"; shift 2 ;;
    --modules) MODULES="$2"; shift 2 ;;
    --ai-api-key) AIKEY="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" 2>/dev/null | sed '$d' | sed 's/^# \{0,1\}//' || echo "see https://github.com/dappros/ethora-install"; exit 0 ;;
    *) PASS+=("$1"); shift ;;
  esac
done

# Answers come from the terminal even when the script itself arrives on stdin (curl | bash).
ask() { # ask VAR "question" "default"
  local var="$1" q="$2" def="${3:-}" ans=""
  [ -n "${!var}" ] && return 0
  if [ "$YES" = true ] || [ ! -r /dev/tty ]; then printf -v "$var" '%s' "$def"; return 0; fi
  if [ -n "$def" ]; then read -r -p "$q [$def]: " ans </dev/tty; else read -r -p "$q: " ans </dev/tty; fi
  printf -v "$var" '%s' "${ans:-$def}"
}

# ------------------------------------------------------------------ 1. checks --
[ "$(uname -s)" = Linux ] || die "this installer is for a Linux server; on a Mac use Docker Desktop and deploy/compose/README.md"
[ "$(id -u)" = 0 ] || die "run it as root: curl -fsSL ... | sudo bash"
mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)"
disk_gb="$(df -BG --output=avail / | tail -n 1 | tr -dc 0-9)"
say "server: ${mem_gb} GB memory, ${disk_gb} GB free disk"
[ "${mem_gb:-0}" -ge 4 ] || warn "4 GB of memory is the minimum for Ethora Core (8 GB with the Enterprise modules)"
[ "${disk_gb:-0}" -ge 20 ] || warn "20 GB of free disk is the minimum (30 GB with the Enterprise modules)"
for p in 80 443; do
  if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then
    warn "port $p is in use: Ethora's proxy needs 80 and 443 (stop the web server that holds it, or see the bundle README for running behind your own proxy)"
  fi
done

# --------------------------------------------------- 2. Docker and git --
if ! command -v docker >/dev/null 2>&1; then
  say "installing Docker (get.docker.com)"
  curl -fsSL https://get.docker.com | sh >/tmp/ethora-docker-install.log 2>&1 || die "Docker install failed; see /tmp/ethora-docker-install.log"
  systemctl enable --now docker >/dev/null 2>&1 || true
fi
docker compose version >/dev/null 2>&1 || die "Docker is installed but the Compose plugin is missing (docker compose version)"
if ! command -v git >/dev/null 2>&1; then
  say "installing git"
  if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq git >/dev/null
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q git
  else die "please install git and run this again"; fi
fi

# ------------------------------------------------------------ 3. bundle --
if [ -d "$DIR/.git" ]; then
  say "updating the bundle in $DIR"
  git -C "$DIR" fetch -q origin "$REF" && git -C "$DIR" checkout -q "$REF" && git -C "$DIR" pull -q --ff-only origin "$REF" \
    || warn "could not update $DIR (local changes?); using it as it is"
else
  say "fetching the bundle into $DIR"
  git clone -q --depth 1 -b "$REF" "$REPO" "$DIR"
fi
BUNDLE="$DIR/deploy/compose"
INSTALL="$DIR/deploy/cloud/install.sh"
[ -x "$INSTALL" ] || chmod +x "$INSTALL"

# ----------------------------------------------------- 4a. the setup page --
if [ "$WEB" = true ]; then
  if ! command -v node >/dev/null 2>&1; then
    say "installing Node.js for the setup page"
    if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq nodejs >/dev/null
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q nodejs
    else die "please install Node.js and run this again"; fi
  fi
  pw="$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
  ip="$(curl -fsS -4 -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then ufw allow 8888/tcp >/dev/null || true; fi
  echo
  say "Open http://$ip:8888 in your browser"
  say "user: admin   password: $pw   (one time: the page stops when the install is done)"
  say "Port 8888 must be open in your cloud firewall / security group. Ctrl+C stops the page."
  echo
  sug=""; [ -n "$ip" ] && sug="$(printf '%s' "$ip" | tr . -).sslip.io"
  SETUP_MODE=compose SETUP_PASSWORD="$pw" ETHORA_SOURCE_ROOT="$DIR" SETUP_SUGGESTED_DOMAIN="$sug" \
    SETUP_DONE_FILE="$DIR/.setup-done" SETUP_LOG="$DIR/setup.log" \
    exec node "$DIR/deploy/setup-web/server.js"
fi

# ------------------------------------------------- 4b. questions here --
if [ -z "$DOMAIN" ] && [ "$YES" != true ] && [ -r /dev/tty ]; then
  echo
  say "Four questions. Press Enter to accept the suggestion in brackets."
  echo "  Domain: the web app, API and chat hosts derive from it (app., api., xmpp., ...)."
  echo "  No domain yet? Keep 'auto': <this server's IP>.sslip.io works at once, with real certificates."
fi
ask DOMAIN "Root domain" "auto"
ask EMAIL "Admin email (your sign-in, and the contact for the certificates)" ""
[ -n "$EMAIL" ] || die "an admin email is required"
ask KEY "Licence key (Enter for Ethora Core, free)" ""
if [ -n "$KEY" ] && [ -z "$MODULES" ]; then
  ask MODULES "Enterprise modules" "ai,push,mcp,uptime"
fi
case ",$MODULES," in *,ai,*) ask AIKEY "OpenAI API key for the AI agents (Enter to add it later in Server settings)" "" ;; esac

# ---------------------------------------------------------- 5. install --
args=(--domain "$DOMAIN" --admin-email "$EMAIL")
[ -n "$KEY" ] && args+=(--license-key "$KEY")
[ -n "$MODULES" ] && args+=(--modules "$MODULES")
[ -n "$AIKEY" ] && args+=(--ai-api-key "$AIKEY")
exec "$INSTALL" "${args[@]}" ${PASS[@]+"${PASS[@]}"}
