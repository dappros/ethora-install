#!/bin/bash
#
# QA Health Report Script
# - Reads deploy/config/deploy.yml (or --config) and checks key endpoints
# - Prints a concise terminal report (green/amber/red)
# - Optionally generates a static HTML report (no browser CORS issues)
#
# Usage:
#   ./scripts/qa-health.sh
#   ./scripts/qa-health.sh --html
#   ./scripts/qa-health.sh --html /tmp/ethora-qa.html
#   ./scripts/qa-health.sh --config ./config/deploy.yml --html
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"
HTML_OUT=""

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage: $0 [--config <path>] [--html [output.html]]

Options:
  --config <path>   Use a specific deploy.yml (default: $CONFIG_FILE)
  --html [path]     Generate a static HTML report (default: $DEPLOY_DIR/qa-health-report.html)
  -h, --help        Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --html)
      # Optional argument
      if [ -n "${2:-}" ] && [[ "${2:-}" != --* ]]; then
        HTML_OUT="$2"
        shift 2
      else
        HTML_OUT="$DEPLOY_DIR/qa-health-report.html"
        shift 1
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] '$1' not found in PATH" >&2; exit 1; }
}

need_cmd yq
need_cmd curl

# Require yq v4 (scripts use `yq eval ...`)
if ! yq --version 2>/dev/null | grep -qE 'version v4\.'; then
  echo "[ERROR] yq v4 is required (deploy scripts use 'yq eval'). Current: $(yq --version 2>/dev/null || echo 'unknown')" >&2
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[ERROR] Config file not found: $CONFIG_FILE" >&2
  echo "Hint: copy a template first, e.g. 'cp config/deploy-local.yml.template config/deploy.yml'" >&2
  exit 1
fi

API_DOMAIN="$(yq eval '.domains.api' "$CONFIG_FILE")"
WEB_DOMAIN="$(yq eval '.domains.web' "$CONFIG_FILE")"
XMPP_DOMAIN="$(yq eval '.domains.xmpp' "$CONFIG_FILE")"
FILES_DOMAIN="$(yq eval '.domains.files' "$CONFIG_FILE")"

BACKEND_PORT="$(yq eval '.services.backend.port' "$CONFIG_FILE")"
SSL_METHOD="$(yq eval '.ssl.method' "$CONFIG_FILE")"

is_localhost=false
if [ "$API_DOMAIN" == "localhost" ] || [ "$WEB_DOMAIN" == "localhost" ]; then
  is_localhost=true
fi

scheme_http="http"
scheme_https="https"
api_scheme="$scheme_https"
web_scheme="$scheme_https"

if [ "$is_localhost" == "true" ] || [ "$SSL_METHOD" == "none" ]; then
  api_scheme="$scheme_http"
  web_scheme="$scheme_http"
fi

# In localhost installs we run the frontend via Vite dev server on 5173.
frontend_url="${web_scheme}://${WEB_DOMAIN}"
if [ "$WEB_DOMAIN" == "localhost" ]; then
  frontend_url="http://localhost:5173"
fi

api_base="${api_scheme}://${API_DOMAIN}"
if [ "$API_DOMAIN" == "localhost" ]; then
  api_base="http://localhost:${BACKEND_PORT}"
fi

# MinIO / Centrifugo / Crawler are reached via known localhost ports on the host (installer runs on same machine).
minio_health_url="http://localhost:9000/minio/health/live"
minio_console_url="http://localhost:9001"
centrifugo_url="http://localhost:8001/"
crawler_health_url="http://localhost:8000/health"

# XMPP admin pages:
# - Localhost: direct ports
# - Production: via Nginx on 443 (https://xmpp.domain/admin)
xmpp_admin_http_url="http://localhost:5280/admin/"
xmpp_admin_https_url="https://${XMPP_DOMAIN}/admin/"
if [ "$XMPP_DOMAIN" == "localhost" ]; then
  xmpp_admin_https_url="https://localhost:5443/admin/"
fi

declare -a CHECK_NAMES=()
declare -a CHECK_URLS=()
declare -a CHECK_STATUSES=()
declare -a CHECK_DETAILS=()

add_check() {
  CHECK_NAMES+=("$1")
  CHECK_URLS+=("$2")
}

curl_check() {
  local url="$1"
  local max_seconds="${2:-4}"
  local attempts="${3:-2}"
  local i
  for i in $(seq 1 "$attempts"); do
    # -k: allow self-signed (common in local)
    # -f: fail on >= 400
    if curl -k -fsS --max-time "$max_seconds" "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

status_ok() { echo "OK"; }
status_warn() { echo "WARN"; }
status_fail() { echo "FAIL"; }

run_checks() {
  # Core HTTP checks
  add_check "Backend API /ping" "${api_base}/ping"
  add_check "Backend API docs (/api-docs)" "${api_base}/api-docs/"
  add_check "Frontend (web)" "${frontend_url}/"
  add_check "MinIO live" "${minio_health_url}"
  add_check "MinIO console" "${minio_console_url}/"
  add_check "Centrifugo (root)" "${centrifugo_url}"
  add_check "Crawler /health" "${crawler_health_url}"

  # XMPP admin: check both (prod usually uses 5443; localhost has both)
  if [ "$is_localhost" == "true" ]; then
    add_check "Ejabberd admin (HTTP 5280)" "${xmpp_admin_http_url}"
    add_check "Ejabberd admin (HTTPS 5443)" "${xmpp_admin_https_url}"
  else
    add_check "Ejabberd admin (HTTPS 443)" "${xmpp_admin_https_url}"
  fi

  local idx=0
  local total="${#CHECK_NAMES[@]}"
  while [ "$idx" -lt "$total" ]; do
    local name="${CHECK_NAMES[$idx]}"
    local url="${CHECK_URLS[$idx]}"

    if curl_check "$url" 4 2; then
      CHECK_STATUSES+=("OK")
      CHECK_DETAILS+=("")
    else
      # Some endpoints are expected to be unavailable depending on mode.
      # We mark them WARN instead of FAIL when they are "optional in local".
      if [ "$is_localhost" == "true" ] && [[ "$name" == Ejabberd\ admin\ \(HTTPS* ]]; then
        CHECK_STATUSES+=("WARN")
        CHECK_DETAILS+=("HTTPS admin may be unavailable in localhost mode (self-signed/port mapping).")
      else
        CHECK_STATUSES+=("FAIL")
        CHECK_DETAILS+=("Request failed.")
      fi
    fi

    idx=$((idx + 1))
  done
}

docker_health_lines() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi

  local containers=("deploy_mongo_1" "deploy_mysql_1" "deploy_redis-server_1" "deploy_minio_1" "deploy_xmpp_1" "centrifugo")
  if [ "${CRAWLER_ENABLED:-false}" == "true" ]; then
    containers+=("crawler-service")
  fi
  echo "Docker containers:"
  for c in "${containers[@]}"; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${c}$"; then
      # Prefer health status when present
      local health
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo "unknown")"
      echo "  - ${c}: ${health}"
    else
      echo "  - ${c}: not running"
    fi
  done
}

print_terminal() {
  echo
  echo "Ethora QA Health Report"
  echo "======================"
  echo "Time: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  echo "Config: $CONFIG_FILE"
  echo "API: ${api_base}"
  echo "Web: ${frontend_url}"
  echo "XMPP: ${XMPP_DOMAIN}"
  echo

  local idx=0
  local total="${#CHECK_NAMES[@]}"
  local fails=0
  local warns=0

  while [ "$idx" -lt "$total" ]; do
    local name="${CHECK_NAMES[$idx]}"
    local url="${CHECK_URLS[$idx]}"
    local st="${CHECK_STATUSES[$idx]}"
    local detail="${CHECK_DETAILS[$idx]}"

    if [ "$st" == "OK" ]; then
      echo -e "${GREEN}[OK]${NC}   ${name} -> ${url}"
    elif [ "$st" == "WARN" ]; then
      echo -e "${YELLOW}[WARN]${NC} ${name} -> ${url}${detail:+  ($detail)}"
      warns=$((warns + 1))
    else
      echo -e "${RED}[FAIL]${NC} ${name} -> ${url}${detail:+  ($detail)}"
      fails=$((fails + 1))
    fi

    idx=$((idx + 1))
  done

  echo
  if command -v docker >/dev/null 2>&1; then
    docker_health_lines
    echo
  fi

  if [ "$fails" -eq 0 ]; then
    if [ "$warns" -eq 0 ]; then
      echo -e "${GREEN}Overall: PASS${NC}"
    else
      echo -e "${YELLOW}Overall: PASS (with warnings)${NC}"
    fi
  else
    echo -e "${RED}Overall: FAIL (${fails} failing check(s))${NC}"
  fi
}

html_escape() {
  # Minimal escape for HTML text nodes
  echo "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

write_html() {
  local out="$1"
  local ts
  ts="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"

  {
    echo "<!doctype html>"
    echo "<html><head><meta charset=\"utf-8\" />"
    echo "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />"
    echo "<title>Ethora QA Health Report</title>"
    echo "<style>"
    echo "body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Cantarell,Helvetica,Arial,sans-serif;margin:24px;background:#0b0f14;color:#e6edf3}"
    echo "a{color:#7cc0ff}"
    echo ".meta{color:#9fb1c1;margin-bottom:16px}"
    echo "table{width:100%;border-collapse:collapse;background:#0f1620;border:1px solid #223042}"
    echo "th,td{padding:10px;border-bottom:1px solid #223042;text-align:left;vertical-align:top}"
    echo "th{background:#121c28}"
    echo ".ok{color:#2ea043;font-weight:700}"
    echo ".warn{color:#d29922;font-weight:700}"
    echo ".fail{color:#f85149;font-weight:700}"
    echo ".pill{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;border:1px solid #223042}"
    echo ".pill.ok{background:rgba(46,160,67,.15)}"
    echo ".pill.warn{background:rgba(210,153,34,.15)}"
    echo ".pill.fail{background:rgba(248,81,73,.15)}"
    echo "</style></head><body>"
    echo "<h2>Ethora QA Health Report</h2>"
    echo "<div class=\"meta\">"
    echo "Time: $(html_escape "$ts")<br/>"
    echo "Config: $(html_escape "$CONFIG_FILE")<br/>"
    echo "API: $(html_escape "$api_base")<br/>"
    echo "Web: $(html_escape "$frontend_url")<br/>"
    echo "XMPP: $(html_escape "$XMPP_DOMAIN")"
    echo "</div>"

    echo "<table>"
    echo "<thead><tr><th>Status</th><th>Check</th><th>URL</th><th>Details</th></tr></thead><tbody>"

    local idx=0
    local total="${#CHECK_NAMES[@]}"
    while [ "$idx" -lt "$total" ]; do
      local name="${CHECK_NAMES[$idx]}"
      local url="${CHECK_URLS[$idx]}"
      local st="${CHECK_STATUSES[$idx]}"
      local detail="${CHECK_DETAILS[$idx]}"
      local cls="fail"
      if [ "$st" == "OK" ]; then cls="ok"; fi
      if [ "$st" == "WARN" ]; then cls="warn"; fi
      echo "<tr>"
      echo "<td><span class=\"pill ${cls}\">${st}</span></td>"
      echo "<td>$(html_escape "$name")</td>"
      echo "<td><a href=\"$(html_escape "$url")\">$(html_escape "$url")</a></td>"
      echo "<td>$(html_escape "$detail")</td>"
      echo "</tr>"
      idx=$((idx + 1))
    done

    echo "</tbody></table>"

    if command -v docker >/dev/null 2>&1; then
      echo "<h3>Docker containers</h3>"
      echo "<pre style=\"background:#0f1620;border:1px solid #223042;padding:12px;overflow:auto\">"
      docker_health_lines | sed 's/&/\\&amp;/g; s/</\\&lt;/g; s/>/\\&gt;/g'
      echo "</pre>"
    fi

    echo "</body></html>"
  } > "$out"
}

run_checks
print_terminal

if [ -n "$HTML_OUT" ]; then
  write_html "$HTML_OUT"
  echo
  echo "HTML report written to: $HTML_OUT"
fi


