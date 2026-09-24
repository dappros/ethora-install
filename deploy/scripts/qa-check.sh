#!/bin/bash
#
# Quick QA checks for an Ethora instance (intended for staging updates).
# - Uses deploy/config/deploy.yml by default (or --config)
# - Checks key endpoints, response codes, and validates Swagger JSON
#
# Usage:
#   ./deploy/scripts/qa-check.sh
#   ./deploy/scripts/qa-check.sh --config ./deploy/config/deploy.yml
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"

usage() {
  cat <<EOF
Usage: $0 [--config <path>]

Options:
  --config <path>   Path to deploy.yml (default: $CONFIG_FILE)
  -h, --help        Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
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
need_cmd node

# Require yq v4 (scripts use `yq eval ...`)
if ! yq --version 2>/dev/null | grep -qE 'version v4\.'; then
  echo "[ERROR] yq v4 is required (deploy scripts use 'yq eval'). Current: $(yq --version 2>/dev/null || echo 'unknown')" >&2
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[ERROR] Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

API_DOMAIN="$(yq eval '.domains.api' "$CONFIG_FILE")"
XMPP_DOMAIN="$(yq eval '.domains.xmpp' "$CONFIG_FILE")"
WIDGET_DOMAIN="$(yq eval '.domains.widget // ""' "$CONFIG_FILE")"
WIDGET_ENABLED="$(yq eval '.services.widget.enabled // "false"' "$CONFIG_FILE")"
MCP_ENABLED="$(yq eval '.services.mcp.enabled // "false"' "$CONFIG_FILE")"
MCP_DOMAIN="$(yq eval '.domains.mcp // ""' "$CONFIG_FILE")"
MCP_PORT="$(yq eval '.services.mcp.port // 3030' "$CONFIG_FILE")"
WEB_DOMAIN="$(yq eval '.domains.web' "$CONFIG_FILE")"
BACKEND_PORT="$(yq eval '.services.backend.port' "$CONFIG_FILE")"
SSL_METHOD="$(yq eval '.ssl.method' "$CONFIG_FILE")"

is_localhost=false
if [ "$API_DOMAIN" == "localhost" ] || [ "$SSL_METHOD" == "none" ]; then
  is_localhost=true
fi

api_base="https://${API_DOMAIN}"
if [ "$is_localhost" == "true" ]; then
  api_base="http://localhost:${BACKEND_PORT}"
fi

ok=0
warn=0
fail=0

print_ok() { echo "[OK]   $1"; ok=$((ok + 1)); }
print_warn() { echo "[WARN] $1"; warn=$((warn + 1)); }
print_fail() { echo "[FAIL] $1"; fail=$((fail + 1)); }

curl_json_ok() {
  local url="$1"
  # Fetch and validate JSON
  local body
  if ! body="$(curl -k -fsS --max-time 8 "$url")"; then
    return 1
  fi
  echo "$body" | node -e "const fs=require('fs'); JSON.parse(fs.readFileSync(0,'utf8'));"
}

curl_status() {
  local url="$1"
  curl -k -sS -o /dev/null --max-time 6 -w "%{http_code}" "$url" || echo "000"
}

echo "Ethora QA check"
echo "==============="
echo "Config: $CONFIG_FILE"
echo "API: $api_base"
echo "XMPP domain: $XMPP_DOMAIN"
if [ "${WIDGET_ENABLED:-false}" == "true" ] && [ -n "${WIDGET_DOMAIN:-}" ] && [ "${WIDGET_DOMAIN:-}" != "null" ]; then
  echo "Widget domain: https://${WIDGET_DOMAIN}"
fi
# MCP: derive mcp.<root-of-web> when enabled and domains.mcp is blank (same rule as deploy scripts).
mcp_base=""
if [ "${MCP_ENABLED:-false}" == "true" ]; then
  if [ "$is_localhost" == "true" ]; then
    mcp_base="http://localhost:${MCP_PORT}"
  else
    if { [ -z "${MCP_DOMAIN:-}" ] || [ "${MCP_DOMAIN:-}" == "null" ]; } && [[ "$WEB_DOMAIN" == *.* ]]; then
      MCP_DOMAIN="mcp.${WEB_DOMAIN#*.}"
    fi
    [ -n "${MCP_DOMAIN:-}" ] && [ "${MCP_DOMAIN:-}" != "null" ] && mcp_base="https://${MCP_DOMAIN}"
  fi
  [ -n "$mcp_base" ] && echo "MCP server: ${mcp_base}/mcp"
fi
echo

# 1) API ping
if curl -k -fsS --max-time 6 "${api_base}/ping" >/dev/null 2>&1; then
  print_ok "API /ping"
else
  print_fail "API /ping"
fi

# 2) Swagger JSON must be valid JSON (machine-readable)
if curl_json_ok "${api_base}/api-docs/swagger.json" >/dev/null 2>&1; then
  print_ok "Swagger JSON (/api-docs/swagger.json) parses"
else
  print_fail "Swagger JSON (/api-docs/swagger.json) invalid or not reachable"
fi

# 3) Swagger UI reachable
if curl -k -fsS --max-time 6 "${api_base}/api-docs/" >/dev/null 2>&1; then
  print_ok "Swagger UI (/api-docs/)"
else
  print_warn "Swagger UI (/api-docs/) not reachable"
fi

# 4) MinIO health (local port, because installer runs on same machine)
if curl -k -fsS --max-time 4 "http://localhost:9000/minio/health/live" >/dev/null 2>&1; then
  print_ok "MinIO live (localhost:9000)"
else
  print_fail "MinIO live (localhost:9000)"
fi

# 5) XMPP websocket endpoint (best-effort)
# We can't do a full WS handshake without extra tooling, but we can detect that the endpoint exists.
if [ "$XMPP_DOMAIN" != "null" ] && [ -n "$XMPP_DOMAIN" ]; then
  ws_probe_url="https://${XMPP_DOMAIN}/ws"
  if [ "$XMPP_DOMAIN" == "localhost" ]; then
    ws_probe_url="https://localhost:5443/ws"
  fi
  code="$(curl_status "$ws_probe_url")"
  # Common \"healthy\" responses without WS Upgrade headers:
  # - 200 OK (endpoint exists, WS handshake not verified)
  # - 400 Bad Request (nginx/ejabberd expects Upgrade)
  # - 426 Upgrade Required
  if [ "$code" == "200" ]; then
    print_ok "XMPP /ws reachable (${ws_probe_url}) -> HTTP ${code} (no WS upgrade check)"
  elif [ "$code" == "400" ] || [ "$code" == "426" ]; then
    print_ok "XMPP /ws reachable (${ws_probe_url}) -> HTTP ${code}"
  elif [ "$code" == "000" ] || [ "$code" == "502" ] || [ "$code" == "503" ]; then
    print_fail "XMPP /ws not reachable (${ws_probe_url}) -> HTTP ${code}"
  else
    print_warn "XMPP /ws unexpected status (${ws_probe_url}) -> HTTP ${code}"
  fi
else
  print_warn "XMPP domain not set in config"
fi

# 6) Widget bundle endpoint (optional)
if [ "${WIDGET_ENABLED:-false}" == "true" ] && [ -n "${WIDGET_DOMAIN:-}" ] && [ "${WIDGET_DOMAIN:-}" != "null" ]; then
  if curl -k -fsS --max-time 6 "https://${WIDGET_DOMAIN}/assistant.js" >/dev/null 2>&1; then
    print_ok "Widget bundle (/assistant.js)"
  else
    print_fail "Widget bundle (/assistant.js)"
  fi
fi

# 7) Hosted MCP server (optional)
if [ "${MCP_ENABLED:-false}" == "true" ]; then
  if [ -n "$mcp_base" ]; then
    if curl_json_ok "${mcp_base}/.well-known/mcp" >/dev/null 2>&1; then
      print_ok "MCP server (/.well-known/mcp)"
    else
      print_fail "MCP server (/.well-known/mcp) at ${mcp_base}"
    fi
    if curl_json_ok "${mcp_base}/.well-known/oauth-protected-resource" >/dev/null 2>&1; then
      print_ok "MCP OAuth resource metadata (/.well-known/oauth-protected-resource)"
    else
      print_fail "MCP OAuth resource metadata (/.well-known/oauth-protected-resource) at ${mcp_base}"
    fi
    if curl_json_ok "${api_base}/.well-known/oauth-authorization-server" >/dev/null 2>&1; then
      print_ok "OAuth authorization server metadata (/.well-known/oauth-authorization-server)"
    else
      print_fail "OAuth authorization server metadata (/.well-known/oauth-authorization-server) at ${api_base}"
    fi
  else
    print_warn "MCP server enabled but no domain could be resolved"
  fi
fi

echo
echo "Summary: OK=${ok} WARN=${warn} FAIL=${fail}"

if [ "$fail" -gt 0 ]; then
  exit 2
fi

exit 0


