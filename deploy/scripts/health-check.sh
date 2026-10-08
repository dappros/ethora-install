#!/bin/bash

# Health Check Script
# Verifies that all services are running and accessible

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# docker-compose.enterprise.yml has fail-closed data volumes (${MONGO_DATA_DIR:?...}),
# so compose refuses to interpolate the file - even for `ps`/`logs`/`down` - unless
# these are exported. Matters when this script is run standalone rather than from
# install.sh / update.sh, which export them already.
# shellcheck source=deploy/scripts/load-data-env.sh
source "$SCRIPT_DIR/load-data-env.sh"
ethora_load_data_env "$DEPLOY_DIR" || exit 1
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
}

warn() {
    echo "[WARN] $1"
}

info() {
    echo "[INFO] $1"
}

# Source environment variables
ENV_FILE="$DEPLOY_DIR/.deploy.env"
# .deploy.env is root-only (it holds secrets); the docs run this script without
# sudo, so re-run under sudo instead of failing on the first line.
if [ -f "$ENV_FILE" ] && [ ! -r "$ENV_FILE" ] && [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
    exec sudo -E "$0" "$@"
fi
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    error "Environment file not found: $ENV_FILE. Please run install.sh first."
    exit 1
fi

if [ -z "$API_DOMAIN" ]; then
    error "Environment variables not set. Please run install.sh first."
    exit 1
fi

FAILED_CHECKS=0

check_service() {
    local service_name="$1"
    local check_command="$2"
    
    if eval "$check_command" > /dev/null 2>&1; then
        info "✓ $service_name is healthy"
        return 0
    else
        error "✗ $service_name health check failed"
        ((FAILED_CHECKS++))
        return 1
    fi
}

# Like check_service, but retries the command up to $3 times with $4 seconds
# between attempts. Useful for services that are reported as "Up" by docker
# but whose Node/Express listener takes a few seconds to actually bind the port
# (e.g. uptime, which connects to Postgres + runs ensureSchema before app.listen).
check_service_with_retry() {
    local service_name="$1"
    local check_command="$2"
    local max_attempts="${3:-15}"
    local sleep_seconds="${4:-2}"

    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if eval "$check_command" > /dev/null 2>&1; then
            if [ "$attempt" -gt 1 ]; then
                info "✓ $service_name is healthy (after $attempt attempts)"
            else
                info "✓ $service_name is healthy"
            fi
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "$sleep_seconds"
    done
    error "✗ $service_name health check failed after $max_attempts attempts (~$((max_attempts * sleep_seconds))s)"
    ((FAILED_CHECKS++))
    return 1
}

log "Running health checks..."

# Check Docker containers
log "Checking Docker containers..."
if docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" ps | grep -q "Up"; then
    info "✓ Docker containers are running"
else
    error "✗ Some Docker containers are not running"
    ((FAILED_CHECKS++))
fi

# Optional: Uptime monitoring stack
if [ "${UPTIME_ENABLED:-false}" == "true" ] && [ -f "$DEPLOY_DIR/docker-compose.uptime.yml" ]; then
    log "Checking Ethora Uptime containers..."
    # Guard: docker-compose will error if env/config files are missing.
    if [ ! -f "$DEPLOY_DIR/generated/uptime/uptime.env" ]; then
        warn "Uptime is enabled but env file is missing: $DEPLOY_DIR/generated/uptime/uptime.env (run ./scripts/setup-env.sh)"
        ((FAILED_CHECKS++))
    elif [ ! -f "$DEPLOY_DIR/generated/uptime/uptime.yml" ]; then
        warn "Uptime is enabled but config file is missing: $DEPLOY_DIR/generated/uptime/uptime.yml (run ./scripts/setup-env.sh)"
        ((FAILED_CHECKS++))
    elif docker-compose -f "$DEPLOY_DIR/docker-compose.uptime.yml" ps uptime uptime-db 2>/dev/null | grep -q "Up"; then
        # Note: `ps | grep Up` on the whole compose can be a false positive if only uptime-db is up.
        if docker-compose -f "$DEPLOY_DIR/docker-compose.uptime.yml" ps uptime 2>/dev/null | grep -q "Up"; then
            info "✓ Ethora Uptime container is running"
        else
            error "✗ Ethora Uptime container is not running (uptime-db may still be up)"
            ((FAILED_CHECKS++))
        fi
    else
        error "✗ Ethora Uptime containers are not running"
        ((FAILED_CHECKS++))
    fi
    # NOTE: docker reports the uptime container as "Up" as soon as the entrypoint runs,
    # but the Node process needs a few seconds to connect to Postgres, run `ensureSchema`,
    # `upsertConfig` (loops through every check in uptime.yml), and only THEN `app.listen`.
    # Use a retry loop so a single transient race during update.sh doesn't false-fail.
    check_service_with_retry "Ethora Uptime /health" "curl -f -s http://localhost:${UPTIME_PORT:-8099}/health > /dev/null" 20 2

    # Optional but high-signal: end-to-end XMPP chat echo.
    # This does NOT rely on Mongo and catches the common "XMPP looks up but messages aren't delivered" class of issues.
    # Requires uptime to have the xmpp_muc_echo check configured. Also retried because the
    # echo check itself can take several seconds and depends on /api being live.
    check_service_with_retry "XMPP chat heartbeat (uptime)" "curl -fsS -H 'Content-Type: application/json' -d '{\"checkId\":\"local:xmpp_muc_echo\"}' http://localhost:${UPTIME_PORT:-8099}/api/run-check | grep -q '\"ok\":true'" 6 5
fi

# Optional: AI crawler.
#
# The failure this guards against is silent: with DAPPROS_URL unset the crawler
# still answers /crawl and still reports "Crawled N pages", but its background
# deep-crawl pass POSTs to the literal "None/<appId>" and throws the result
# away. Nothing in the container's status reflects that, so check the env and
# the callback's reachability explicitly.
if [ "${CRAWLER_ENABLED:-false}" == "true" ]; then
    log "Checking AI crawler..."
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^crawler-service$'; then
        error "✗ Crawler is enabled but crawler-service is not running"
        ((FAILED_CHECKS++))
    else
        # Probed from the host, where curl is available.
        check_service "Crawler /health" "curl -f -s http://localhost:${CRAWLER_PORT:-8000}/health > /dev/null"

        crawler_callback="$(docker exec crawler-service sh -c 'printf %s "$DAPPROS_URL"' 2>/dev/null || echo '')"
        if [ -z "$crawler_callback" ]; then
            error "✗ Crawler DAPPROS_URL is empty - deep-crawl results will be discarded (run ./scripts/setup-env.sh, then recreate the crawler container)"
            ((FAILED_CHECKS++))
        else
            info "✓ Crawler callback configured: $crawler_callback"

            crawler_secret="$(docker exec crawler-service sh -c 'printf %s "$CRAWLER_CALLBACK_SECRET"' 2>/dev/null || echo '')"
            if [ -z "$crawler_secret" ]; then
                error "✗ Crawler CRAWLER_CALLBACK_SECRET is empty - the backend will reject its results (run ./scripts/setup-env.sh, then recreate the crawler container)"
                ((FAILED_CHECKS++))
            fi

            # POST an empty JSON object with the crawler's own secret. This
            # exercises the real callback path - reachability, auth, and the
            # controller - while writing nothing.
            #
            # The empty body is load-bearing: internalForCrawlerService only
            # touches the database when appId, pages AND url are all present,
            # and an empty `pages` ARRAY is truthy, so {"pages": []} would still
            # reach an upsert on the apps collection. {} skips that branch.
            #
            # Probed with python, not curl: the crawler image ships wget only.
            # 2xx = accepted; 403 = the two sides disagree on the secret; a
            # connection failure reports 000.
            callback_status="$(docker exec crawler-service python -c "
import json, os, urllib.request, urllib.error
url = os.environ.get('DAPPROS_URL', '') + '/healthcheck'
body = json.dumps({}).encode()
headers = {'Content-Type': 'application/json', 'x-secret': os.environ.get('CRAWLER_CALLBACK_SECRET', '')}
try:
    print(urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers), timeout=5).status)
except urllib.error.HTTPError as exc:
    print(exc.code)
except Exception:
    print('000')
" 2>/dev/null || echo '000')"
            case "$callback_status" in
                000)
                    error "✗ Crawler cannot reach its callback ($crawler_callback) - check services.crawler.callback_url"
                    ((FAILED_CHECKS++))
                    ;;
                403)
                    error "✗ Backend rejected the crawler's secret (HTTP 403) - backend and crawler envs disagree; re-run ./scripts/setup-env.sh, restart the backend and recreate the crawler container"
                    ((FAILED_CHECKS++))
                    ;;
                2*)
                    info "✓ Crawler callback accepted by the backend (HTTP $callback_status)"
                    ;;
                *)
                    warn "Crawler callback returned HTTP $callback_status (expected 2xx)"
                    ((FAILED_CHECKS++))
                    ;;
            esac
        fi
    fi
fi

# Optional: managed AI embeddings Postgres
if [ "${AI_SERVICE_ENABLED:-false}" == "true" ]; then
    if [ "${AI_POSTGRES_MANAGED:-false}" == "true" ] && [ -f "$DEPLOY_DIR/docker-compose.ai.yml" ]; then
        log "Checking AI Postgres container..."
        if docker-compose -f "$DEPLOY_DIR/docker-compose.ai.yml" ps ai-postgres 2>/dev/null | grep -q "Up"; then
            info "✓ AI Postgres container is running"
        else
            error "✗ AI Postgres container is not running"
            ((FAILED_CHECKS++))
        fi
        check_service "AI Postgres readiness" "docker-compose -f $DEPLOY_DIR/docker-compose.ai.yml exec -T ai-postgres pg_isready -U \"$AI_POSTGRES_USER\" -d \"$AI_POSTGRES_DB\""
        check_service "AI Postgres schema" "docker-compose -f $DEPLOY_DIR/docker-compose.ai.yml exec -T ai-postgres psql -U \"$AI_POSTGRES_USER\" -d \"$AI_POSTGRES_DB\" -Atqc \"SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='documents'\" | grep -q '^1$'"
    else
        info "AI Postgres uses an external PG_URL override; reachability/schema are validated during AI service setup."
    fi
fi

# Check MongoDB
check_service "MongoDB" "docker-compose -f $DEPLOY_DIR/docker-compose.enterprise.yml exec -T mongo mongosh --eval 'db.adminCommand(\"ping\")' --quiet"

# Check MySQL
check_service "MySQL" "docker-compose -f $DEPLOY_DIR/docker-compose.enterprise.yml exec -T mysql mysqladmin ping -h localhost -u root -p\"$MYSQL_ROOT_PASSWORD\" --silent"

# Check Redis
check_service "Redis" "docker-compose -f $DEPLOY_DIR/docker-compose.enterprise.yml exec -T redis-server redis-cli ping"

# Check MinIO
check_service "MinIO" "curl -f http://localhost:9000/minio/health/live"

# Check Centrifugo
# Centrifugo doesn't have a /health endpoint, so we check if the service is responding on root
check_service "Centrifugo" "curl -f -s http://localhost:8001/ > /dev/null"

# Check Ejabberd
check_service "Ejabberd" "docker-compose -f $DEPLOY_DIR/docker-compose.enterprise.yml exec -T xmpp /home/ejabberd/bin/ejabberdctl ping"

# Check PM2 processes
log "Checking PM2 processes..."
if command -v pm2 &> /dev/null; then
    pm2_list_for_user() {
        # Print pm2 list output for a given user (best-effort). Returns non-zero if it can't be obtained.
        # Usage: pm2_list_for_user "ubuntu"  (or "root")
        local u="$1"
        if [ -z "$u" ] || [ "$u" = "root" ]; then
            pm2 list 2>/dev/null
            return $?
        fi
        if command -v sudo >/dev/null 2>&1 && id "$u" >/dev/null 2>&1; then
            sudo -u "$u" -H pm2 list 2>/dev/null
            return $?
        fi
        return 1
    }

    pm2_has_online() {
        # Usage: pm2_has_online "<pm2-list-output>" "<process-name>"
        local out="$1"
        local name="$2"
        echo "$out" | grep -q "${name}.*online"
    }

    # Check both user and root PM2 instances (since install script may run as root)
    BACKEND_RUNNING=false
    pm2_out_current="$(pm2_list_for_user "${USER:-}" || true)"
    pm2_out_root="$(pm2_list_for_user "root" || true)"
    pm2_out_deploy_user=""
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        pm2_out_deploy_user="$(pm2_list_for_user "$SUDO_USER" || true)"
    fi

    if pm2_has_online "$pm2_out_current" "backend"; then
        BACKEND_RUNNING=true
    elif pm2_has_online "$pm2_out_deploy_user" "backend"; then
        BACKEND_RUNNING=true
    elif pm2_has_online "$pm2_out_root" "backend"; then
        BACKEND_RUNNING=true
    fi

    # Image mode (services.backend.mode: image): the API is a container, not a PM2 app.
    BACKEND_CONTAINER=""
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -qE '^ethora-backend Up'; then
        BACKEND_CONTAINER="$(docker ps --format '{{.Image}}' --filter name='^ethora-backend$' 2>/dev/null | head -1)"
        BACKEND_RUNNING=true
    fi

    if [ "$BACKEND_RUNNING" == "true" ]; then
        if [ -n "$BACKEND_CONTAINER" ]; then
            info "✓ Backend is running (image mode: $BACKEND_CONTAINER)"
        else
            info "✓ Backend is running"
        fi
    else
        # If PM2 check fails, verify backend is actually responding via API.
        # Backend exposes /ping (not /v1/ping).
        if curl -f -s "http://localhost:${BACKEND_PORT:-8080}/ping" > /dev/null 2>&1; then
            info "✓ Backend is running (API responding, PM2 status unclear)"
        else
            error "✗ Backend is not running"
            ((FAILED_CHECKS++))
        fi
    fi
    
    # License state, from the public /ping summary (no auth needed). Not a
    # pass/fail check: a grace or restricted install is still healthy, the
    # operator just needs to know. See docs/LICENSING.md.
    _ping_json="$(curl -s "http://localhost:${BACKEND_PORT:-8080}/ping" 2>/dev/null || true)"
    _lic_state="$(printf '%s' "$_ping_json" | sed -n 's/.*"license":{"state":"\([a-z_]*\)".*/\1/p')"
    _lic_reason="$(printf '%s' "$_ping_json" | sed -n 's/.*"license":{[^}]*"reason":"\([a-z_]*\)".*/\1/p')"
    _lic_grace="$(printf '%s' "$_ping_json" | sed -n 's/.*"license":{[^}]*"graceEndsAt":"\([^"]*\)".*/\1/p')"
    _lic_exp="$(printf '%s' "$_ping_json" | sed -n 's/.*"license":{[^}]*"expiresAt":"\([^"]*\)".*/\1/p')"
    _lic_lid="$(printf '%s' "$_ping_json" | sed -n 's/.*"license":{[^}]*"lid":"\([^"]*\)".*/\1/p')"
    _lic_tier="$(printf '%s' "$_ping_json" | sed -n 's/.*"license":{[^}]*"tier":"\([a-z-]*\)".*/\1/p')"
    _lic_apps="$(printf '%s' "$_ping_json" | sed -n 's/.*"license":{[^}]*"limits":{"apps":\([0-9]*\).*/\1/p')"
    _lic_users="$(printf '%s' "$_ping_json" | sed -n 's/.*"license":{[^}]*"limits":{[^}]*"users":\([0-9]*\).*/\1/p')"
    _lic_caps=""; [ -n "$_lic_apps" ] && _lic_caps=", ${_lic_apps} apps / ${_lic_users:-?} users per server"
    case "$_lic_state:$_lic_tier" in
        licensed:core-registered)
            info "✓ Edition: Ethora Core, registered (${_lic_lid:-?}${_lic_caps}, no expiry)" ;;
        unlicensed:core)
            info "✓ Edition: Ethora Core, unregistered (free${_lic_caps}; register on the admin panel License page to raise the caps)" ;;
    esac
    case "$_lic_state" in
        licensed)
            [ "$_lic_tier" = core-registered ] || info "✓ License: licensed (${_lic_lid:-?}, ${_lic_tier:-enterprise}, expires ${_lic_exp:-?})" ;;
        grace)
            warn "⚠ License: GRACE PERIOD until ${_lic_grace:-?} (${_lic_reason:-?}). Install a license key via deploy.yml license.key or the admin panel License page. See docs/LICENSING.md" ;;
        restricted)
            warn "✗ License: RESTRICTED (${_lic_reason:-?}). Chat works, but creating apps/users is disabled until a valid key is installed. See docs/LICENSING.md" ;;
        ""|unlicensed)
            ;;
        *)
            warn "License: state ${_lic_state}" ;;
    esac

    # Image-mode containers (services.*.mode: image) are not PM2 apps.
    container_up() { command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -qE "^$1 Up"; }

    if [ "${AI_SERVICE_ENABLED}" == "true" ]; then
        if container_up ethora-ai-service; then
            info "✓ AI Service is running (image mode)"
        elif pm2_has_online "$pm2_out_current" "ai-service" || pm2_has_online "$pm2_out_deploy_user" "ai-service" || pm2_has_online "$pm2_out_root" "ai-service"; then
            info "✓ AI Service is running"
        else
            warn "✗ AI Service is not running (but may be disabled)"
        fi
    fi
    if container_up ethora-push; then info "✓ Push service is running (image mode)"; fi
    if container_up ethora-playground; then info "✓ SDK playground is running (image mode)"; fi
    if container_up ethora-mcp; then info "✓ MCP server is running (image mode)"; fi

    if [ "${DOCS_PARSE_ENABLED}" == "true" ]; then
        if container_up ethora-docs-parse; then
            info "✓ Docs Parse Service is running (image mode)"
        elif pm2_has_online "$pm2_out_current" "docs-parse" || pm2_has_online "$pm2_out_deploy_user" "docs-parse" || pm2_has_online "$pm2_out_root" "docs-parse"; then
            info "✓ Docs Parse Service is running"
        else
            warn "✗ Docs Parse Service is not running (but may be disabled)"
        fi
    fi
else
    warn "PM2 is not installed, skipping PM2 health checks"
fi

# Check API endpoint
log "Checking API endpoint..."
if [ "$API_DOMAIN" == "localhost" ]; then
    # Localhost mode - check HTTP
    api_ok=false
    for i in {1..10}; do
        if curl -f "http://localhost:${BACKEND_PORT}/ping" > /dev/null 2>&1; then
            api_ok=true
            break
        fi
        sleep 1
    done
    if [ "$api_ok" == "true" ]; then
        info "✓ API endpoint is accessible (localhost)"
    else
        error "✗ API endpoint is not accessible"
        ((FAILED_CHECKS++))
    fi
else
    # Production mode - check HTTPS
    api_ok=false
    for i in {1..10}; do
        if curl -f -k "https://$API_DOMAIN/ping" > /dev/null 2>&1; then
            api_ok=true
            break
        fi
        sleep 1
    done
    if [ "$api_ok" == "true" ]; then
        info "✓ API endpoint is accessible"
    else
        error "✗ API endpoint is not accessible"
        ((FAILED_CHECKS++))
    fi
fi

if [ "${WIDGET_ENABLED:-false}" == "true" ] && [ -n "${WIDGET_DOMAIN:-}" ] && [ "${WIDGET_DOMAIN:-}" != "null" ]; then
    log "Checking widget endpoint..."
    if curl -f -k "https://${WIDGET_DOMAIN}/assistant.js" > /dev/null 2>&1; then
        info "✓ Widget endpoint is accessible"
    else
        error "✗ Widget endpoint is not accessible"
        ((FAILED_CHECKS++))
    fi
fi

# Hosted MCP server (optional)
if [ "${MCP_ENABLED:-false}" == "true" ]; then
    log "Checking hosted MCP server..."
    check_service_with_retry "MCP server /healthz" "curl -f -s http://127.0.0.1:${MCP_PORT:-3030}/healthz > /dev/null" 10 2
    if [ "$API_DOMAIN" != "localhost" ] && [ -n "${MCP_DOMAIN:-}" ] && [ "${MCP_DOMAIN:-}" != "null" ]; then
        if curl -f -k -s "https://${MCP_DOMAIN}/.well-known/mcp" > /dev/null 2>&1; then
            info "✓ MCP public endpoint is accessible (https://${MCP_DOMAIN}/.well-known/mcp)"
        else
            error "✗ MCP public endpoint is not accessible (https://${MCP_DOMAIN}/.well-known/mcp)"
            ((FAILED_CHECKS++))
        fi
        if curl -f -k -s "https://${MCP_DOMAIN}/.well-known/oauth-protected-resource" > /dev/null 2>&1; then
            info "✓ MCP OAuth resource metadata is accessible (https://${MCP_DOMAIN}/.well-known/oauth-protected-resource)"
        else
            error "✗ MCP OAuth resource metadata is not accessible (https://${MCP_DOMAIN}/.well-known/oauth-protected-resource)"
            ((FAILED_CHECKS++))
        fi
    fi
    if [ -n "${OAUTH_ISSUER:-}" ]; then
        if curl -f -k -s "${OAUTH_ISSUER}/.well-known/oauth-authorization-server" > /dev/null 2>&1; then
            info "✓ OAuth authorization server metadata is accessible (${OAUTH_ISSUER}/.well-known/oauth-authorization-server)"
        else
            error "✗ OAuth authorization server metadata is not accessible (${OAUTH_ISSUER}/.well-known/oauth-authorization-server)"
            ((FAILED_CHECKS++))
        fi
    fi
fi

# Check SSL certificates (skip for localhost)
if [ "$API_DOMAIN" != "localhost" ]; then
    log "Checking SSL certificates..."
    for domain in "$API_DOMAIN" "$WEB_DOMAIN" "$FILES_DOMAIN" "${SECURE_FILES_DOMAIN:-}" "$WIDGET_DOMAIN" "${MCP_DOMAIN:-}"; do
        if [ -z "$domain" ] || [ "$domain" == "null" ]; then
            continue
        fi
        if [ -d "/etc/letsencrypt/live/$domain" ]; then
            if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$domain/privkey.pem" ]; then
                info "✓ SSL certificate exists for $domain"
            else
                error "✗ SSL certificate files missing for $domain"
                ((FAILED_CHECKS++))
            fi
        else
            warn "SSL certificate directory not found for $domain"
        fi
    done
else
    log "Skipping SSL certificate checks (localhost mode)"
fi

# Check Nginx (skip for localhost)
if [ "$API_DOMAIN" != "localhost" ]; then
    log "Checking Nginx..."
    if systemctl is-active --quiet nginx; then
        info "✓ Nginx is running"
        
        # Test Nginx configuration
        # NOTE:
        # `nginx -t` reads TLS private keys referenced by vhosts. Those are often mode 600 root:root,
        # so running without sudo can incorrectly fail even though nginx itself (running as root master)
        # is perfectly healthy.
        nginx_test_cmd="nginx -t"
        if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            nginx_test_cmd="sudo nginx -t"
        fi
        nginx_test_out="$($nginx_test_cmd 2>&1 || true)"
        if echo "$nginx_test_out" | grep -q "test is successful"; then
            info "✓ Nginx configuration is valid"
        else
            error "✗ Nginx configuration is invalid"
            # Print the reason; the most common cause is missing certificate files.
            if [ -n "$nginx_test_out" ]; then
                echo "$nginx_test_out" >&2
            fi
            ((FAILED_CHECKS++))
        fi
    else
        error "✗ Nginx is not running"
        ((FAILED_CHECKS++))
    fi
else
    log "Skipping Nginx checks (localhost mode)"
fi

# Summary
log "======================================"
if [ $FAILED_CHECKS -eq 0 ]; then
    log "All health checks passed!"
    exit 0
else
    error "$FAILED_CHECKS health check(s) failed"
    exit 1
fi

