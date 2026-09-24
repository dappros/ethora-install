#!/bin/bash

# Pre-deployment Validation Script
# Validates prerequisites and configuration before deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

warn() {
    echo "[WARN] $1"
}

log "Running pre-deployment validation..."

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    error "Configuration file not found: $CONFIG_FILE. Please copy deploy.yml.template to deploy.yml and configure it."
fi

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    error "yq is required but not installed. Install it or the install script will attempt to install it."
fi
if ! yq --version 2>/dev/null | grep -qE 'version v4\.'; then
    error "yq v4 is required (deploy scripts use 'yq eval'). Your current yq is: $(yq --version 2>/dev/null || echo 'unknown')."
fi

# Validate required fields in config
log "Validating configuration file..."

API_DOMAIN=$(yq eval '.domains.api' "$CONFIG_FILE" 2>/dev/null || echo "")
WEB_DOMAIN=$(yq eval '.domains.web' "$CONFIG_FILE" 2>/dev/null || echo "")
XMPP_DOMAIN=$(yq eval '.domains.xmpp' "$CONFIG_FILE" 2>/dev/null || echo "")
FILES_DOMAIN=$(yq eval '.domains.files' "$CONFIG_FILE" 2>/dev/null || echo "")
WIDGET_DOMAIN=$(yq eval '.domains.widget // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
WIDGET_ENABLED=$(yq eval '.services.widget.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")
HOSTED_APPS_ROOT_DOMAIN=$(yq eval '.domains.hosted_apps_root // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
HOSTED_APPS_ENABLED=$(yq eval '.services.hosted_apps.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")
SSL_METHOD=$(yq eval '.ssl.method' "$CONFIG_FILE" 2>/dev/null || echo "certbot")
HOSTED_APPS_CERT_PATH=$(yq eval '.ssl.hosted_apps_cert_path // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
HOSTED_APPS_KEY_PATH=$(yq eval '.ssl.hosted_apps_key_path // ""' "$CONFIG_FILE" 2>/dev/null || echo "")

if [ -z "$API_DOMAIN" ] || [ "$API_DOMAIN" == "null" ] || [ "$API_DOMAIN" == "api.example.com" ]; then
    error "domains.api must be configured in deploy.yml"
fi

if [ -z "$WEB_DOMAIN" ] || [ "$WEB_DOMAIN" == "null" ] || [ "$WEB_DOMAIN" == "app.example.com" ]; then
    error "domains.web must be configured in deploy.yml"
fi

if [ -z "$XMPP_DOMAIN" ] || [ "$XMPP_DOMAIN" == "null" ] || [ "$XMPP_DOMAIN" == "xmpp.example.com" ]; then
    error "domains.xmpp must be configured in deploy.yml"
fi

if [ -z "$FILES_DOMAIN" ] || [ "$FILES_DOMAIN" == "null" ] || [ "$FILES_DOMAIN" == "files.example.com" ]; then
    error "domains.files must be configured in deploy.yml"
fi

# License (license:). A key is optional, but if one is given it has to look
# like a key, and a key_file has to exist - a typo here would otherwise
# surface weeks later as an unexpected restricted state.
LICENSE_KEY=$(yq eval '.license.key // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
[ "$LICENSE_KEY" == "null" ] && LICENSE_KEY=""
LICENSE_KEY_FILE=$(yq eval '.license.key_file // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
[ "$LICENSE_KEY_FILE" == "null" ] && LICENSE_KEY_FILE=""
if [ -n "$LICENSE_KEY_FILE" ]; then
    if [ ! -f "$LICENSE_KEY_FILE" ]; then
        error "license.key_file is set to '$LICENSE_KEY_FILE' but that file does not exist."
    else
        LICENSE_KEY=$(tr -d '[:space:]' < "$LICENSE_KEY_FILE")
    fi
fi
LICENSE_KEY=$(printf '%s' "$LICENSE_KEY" | tr -d '[:space:]')
if [ -n "$LICENSE_KEY" ] && ! [[ "$LICENSE_KEY" =~ ^ETHORA1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
    error "license.key does not look like an Ethora license key (expected ETHORA1.<payload>.<signature>). Paste the key exactly as issued, or leave it empty."
fi
LICENSE_CALL_HOME=$(yq eval '.license.call_home // "true"' "$CONFIG_FILE" 2>/dev/null || echo "true")
if [ "$LICENSE_CALL_HOME" != "true" ] && [ "$LICENSE_CALL_HOME" != "false" ] && [ "$LICENSE_CALL_HOME" != "null" ]; then
    error "license.call_home must be true or false (got: '$LICENSE_CALL_HOME')."
fi
LICENSE_SERVER_URL=$(yq eval '.license.server_url // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
if [ -n "$LICENSE_SERVER_URL" ] && [ "$LICENSE_SERVER_URL" != "null" ] && ! [[ "$LICENSE_SERVER_URL" =~ ^https?:// ]]; then
    error "license.server_url must be an http(s) URL (got: '$LICENSE_SERVER_URL')."
fi
LICENSE_GRACE_DAYS=$(yq eval '.license.grace_days // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
if [ -n "$LICENSE_GRACE_DAYS" ] && [ "$LICENSE_GRACE_DAYS" != "null" ] && ! [[ "$LICENSE_GRACE_DAYS" =~ ^[0-9]+$ ]]; then
    error "license.grace_days must be a whole number of days or empty (got: '$LICENSE_GRACE_DAYS')."
fi

# Run modes (services.backend.mode / services.frontend.mode): source | image.
for svc in backend frontend ai_service push playground mcp ejabberd; do
    mode=$(yq eval ".services.${svc}.mode // \"source\"" "$CONFIG_FILE" 2>/dev/null || echo "source")
    [ "$mode" == "null" ] && mode="source"
    if [ "$mode" != "source" ] && [ "$mode" != "image" ]; then
        error "services.${svc}.mode must be 'source' or 'image' (got: '$mode')."
    fi
    if [ "$mode" == "image" ]; then
        image=$(yq eval ".services.${svc}.image // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ -z "$image" ] || [ "$image" == "null" ]; then
            case "$svc" in backend) hint=api ;; frontend) hint=frontend ;; ai_service) hint=ai ;; ejabberd) hint=xmpp ;; *) hint="$svc" ;; esac
            error "services.${svc}.mode is image but services.${svc}.image is empty. Set it to e.g. ghcr.io/dappros/ethora-${hint}:2610."
        fi
    fi
done

# Immutable audit logs (features.immutable_logs).
# When the flag is on, the S3 connection settings and the upload interval are
# mandatory - a half-configured install would otherwise silently produce a log
# export job that can never upload anything.
IMMUTABLE_LOGS_ENABLED=$(yq eval '.features.immutable_logs // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")
if [ "$IMMUTABLE_LOGS_ENABLED" == "true" ]; then
    log "Validating immutable audit log (S3) configuration..."

    IMMUTABLE_LOGS_INTERVAL_HOURS=$(yq eval '.integrations.immutable_logs.interval_hours // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    [ "$IMMUTABLE_LOGS_INTERVAL_HOURS" == "null" ] && IMMUTABLE_LOGS_INTERVAL_HOURS=""

    for field in aws_access_key_id aws_secret_access_key aws_region aws_s3_bucket_name; do
        value=$(yq eval ".integrations.immutable_logs.${field} // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ -z "$value" ] || [ "$value" == "null" ]; then
            error "features.immutable_logs is true but integrations.immutable_logs.${field} is missing or empty in deploy.yml. Set all of aws_access_key_id, aws_secret_access_key, aws_region, aws_s3_bucket_name, or set features.immutable_logs: false."
        fi
    done

    if [ -z "$IMMUTABLE_LOGS_INTERVAL_HOURS" ]; then
        error "features.immutable_logs is true but integrations.immutable_logs.interval_hours is missing in deploy.yml. Set it to a positive integer number of hours (e.g. 6)."
    fi
    if ! [[ "$IMMUTABLE_LOGS_INTERVAL_HOURS" =~ ^[0-9]+$ ]] || [ "$IMMUTABLE_LOGS_INTERVAL_HOURS" -lt 1 ]; then
        error "integrations.immutable_logs.interval_hours must be a positive integer number of hours (got: '$IMMUTABLE_LOGS_INTERVAL_HOURS')."
    fi

    log "  Immutable logs: enabled (every ${IMMUTABLE_LOGS_INTERVAL_HOURS}h -> s3://$(yq eval '.integrations.immutable_logs.aws_s3_bucket_name' "$CONFIG_FILE" 2>/dev/null))"
fi

# BCP-47 tag normalisation, used by the translation-server check below.
# 'EN-ca' -> 'en-CA'; a bare 'fr' is lowercased and passed through.
normalize_locale() {
    # 'EN-ca' -> 'en-CA'; a bare 'fr' is lowercased and passed through.
    local tag lang region
    tag="$(echo "$1" | tr -d '[:space:]')"
    lang="${tag%%-*}"
    region="${tag#*-}"
    if [ "$region" != "$tag" ] && [ -n "$region" ]; then
        echo "$(echo "$lang" | tr '[:upper:]' '[:lower:]')-$(echo "$region" | tr '[:lower:]' '[:upper:]')"
    else
        echo "$lang" | tr '[:upper:]' '[:lower:]'
    fi
}

# Translation-server languages (translate.languages), served to clients as
# `translateLanguages` from GET /v1/apps/get-config.
#
# Nothing here is fatal. Empty is a real configuration ("no translation server
# installed") and codes outside the bundle are expected - the translator is a
# separate deployment and may well support languages the web bundle has no UI
# dictionary for, which is fine because this list is not a UI catalogue. What is
# worth flagging is a malformed tag, since it will be stored and advertised
# verbatim.
TRANSLATE_LANGUAGES_RAW=$(yq eval '.translate.languages // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
[ "$TRANSLATE_LANGUAGES_RAW" = "null" ] && TRANSLATE_LANGUAGES_RAW=""

TRANSLATE_LANGUAGES_LIST=""
IFS=',' read -ra _tr_codes <<< "$TRANSLATE_LANGUAGES_RAW"
for _code in "${_tr_codes[@]}"; do
    _norm="$(normalize_locale "$_code")"
    [ -z "$_norm" ] && continue
    case "$_norm" in
        [a-z][a-z]|[a-z][a-z]-[A-Z][A-Z]) ;;
        *) warn "translate.languages contains '$_norm', which is not a well-formed BCP-47 tag (expected 'xx' or 'xx-YY'). It will be advertised to clients as-is." ;;
    esac
    TRANSLATE_LANGUAGES_LIST="$TRANSLATE_LANGUAGES_LIST $_norm"
done

if [ -z "${TRANSLATE_LANGUAGES_LIST// /}" ]; then
    log "  Translation server: no languages configured - get-config reports translateLanguages: []"
else
    log "  Translation server:${TRANSLATE_LANGUAGES_LIST}"
fi

# Check DNS resolution (skip for localhost)
if [ "$API_DOMAIN" != "localhost" ]; then
    log "Checking DNS resolution..."
    for domain in "$API_DOMAIN" "$WEB_DOMAIN" "$XMPP_DOMAIN" "$FILES_DOMAIN"; do
        if ! host "$domain" > /dev/null 2>&1; then
            warn "Domain $domain does not resolve. Ensure DNS is configured before deployment."
        fi
    done
    if [ "${WIDGET_ENABLED:-false}" == "true" ] && [ -n "${WIDGET_DOMAIN:-}" ] && [ "${WIDGET_DOMAIN:-}" != "null" ]; then
        if ! host "$WIDGET_DOMAIN" > /dev/null 2>&1; then
            warn "Domain $WIDGET_DOMAIN does not resolve. Ensure DNS is configured before enabling widget hosting."
        fi
    fi
    if [ "${HOSTED_APPS_ENABLED:-false}" == "true" ] && [ -n "${HOSTED_APPS_ROOT_DOMAIN:-}" ] && [ "${HOSTED_APPS_ROOT_DOMAIN:-}" != "null" ]; then
        if ! host "$HOSTED_APPS_ROOT_DOMAIN" > /dev/null 2>&1; then
            warn "Hosted apps root domain $HOSTED_APPS_ROOT_DOMAIN does not resolve. Ensure wildcard DNS is configured before enabling tenant web-app hosting."
        fi
        if [ -n "${HOSTED_APPS_CERT_PATH:-}" ] || [ -n "${HOSTED_APPS_KEY_PATH:-}" ]; then
            if [ -z "${HOSTED_APPS_CERT_PATH:-}" ] || [ -z "${HOSTED_APPS_KEY_PATH:-}" ]; then
                error "Hosted apps wildcard SSL requires both ssl.hosted_apps_cert_path and ssl.hosted_apps_key_path when either one is set"
            fi
        elif [ "${SSL_METHOD:-certbot}" == "certbot" ]; then
            warn "Hosted apps wildcard HTTPS usually requires ssl.hosted_apps_cert_path + ssl.hosted_apps_key_path with a wildcard certificate for *.${HOSTED_APPS_ROOT_DOMAIN}."
        fi
    fi
else
    log "Localhost mode detected - skipping DNS checks"
fi

# Check required directories exist
log "Checking required directories..."

# Get base path from config or use default
CONFIG_BASE_DIR=$(yq eval '.paths.base' "$CONFIG_FILE" 2>/dev/null || echo "")
CONFIG_SOURCE_DIR=$(yq eval '.paths.source // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
if [ -n "$CONFIG_BASE_DIR" ] && [ "$CONFIG_BASE_DIR" != "null" ]; then
    if [ -d "$CONFIG_BASE_DIR" ]; then
        ROOT_DIR="$(cd "$CONFIG_BASE_DIR" && pwd)"
    else
        # Directory will be created by install.sh, so just warn here
        warn "Base directory does not exist yet: $CONFIG_BASE_DIR (will be created during installation)"
        ROOT_DIR="$CONFIG_BASE_DIR"
    fi
fi

# Calculate paths relative to base
BACKEND_DIR="$ROOT_DIR/ethora-backend"
FRONTEND_DIR="$ROOT_DIR/ethora-app-reactjs"
EJABBERD_DIR="$ROOT_DIR/ejabberd-docker"
WIDGET_DIR="$ROOT_DIR/ethora-ai-chat-widget"
CHAT_COMPONENT_DIR="$ROOT_DIR/ethora-chat-component"

# If using custom path, directories might not exist yet (will be copied by install.sh)
# So we only check if they exist, but don't error if they don't (install.sh will handle it)
if [ -n "$CONFIG_BASE_DIR" ] && [ "$CONFIG_BASE_DIR" != "null" ]; then
    log "Custom base path detected - directories will be copied during installation if needed"
    log "Target paths:"
    log "  Base: $ROOT_DIR"
    log "  Backend: $BACKEND_DIR"
    log "  Frontend: $FRONTEND_DIR"
    log "  Chat component: $CHAT_COMPONENT_DIR"
    log "  Ejabberd: $EJABBERD_DIR"
    SOURCE_CHAT_COMPONENT_DIR="$ROOT_DIR/ethora-chat-component"
    if [ -n "$CONFIG_SOURCE_DIR" ] && [ "$CONFIG_SOURCE_DIR" != "null" ]; then
        SOURCE_CHAT_COMPONENT_DIR="$CONFIG_SOURCE_DIR/ethora-chat-component"
    fi
    if [ ! -d "$SOURCE_CHAT_COMPONENT_DIR" ]; then
        error "Source chat component directory is missing: $SOURCE_CHAT_COMPONENT_DIR"
    fi
    if [ "${WIDGET_ENABLED:-false}" == "true" ]; then
        log "  Widget: $WIDGET_DIR"
        SOURCE_WIDGET_DIR="$ROOT_DIR/ethora-ai-chat-widget"
        if [ -n "$CONFIG_SOURCE_DIR" ] && [ "$CONFIG_SOURCE_DIR" != "null" ]; then
            SOURCE_WIDGET_DIR="$CONFIG_SOURCE_DIR/ethora-ai-chat-widget"
        fi
        if [ ! -d "$SOURCE_WIDGET_DIR" ]; then
            error "Widget hosting is enabled, but source widget directory is missing: $SOURCE_WIDGET_DIR"
        fi
    fi
else
    # For default path, directories must exist
    REQUIRED_DIRS=(
        "$BACKEND_DIR"
        # Backend repo layout support:
        # - legacy layout: $BACKEND_DIR/backend
        # - new layout:    $BACKEND_DIR/services/api
        "$BACKEND_DIR/backend"
        "$BACKEND_DIR/services/api"
        "$FRONTEND_DIR"
        "$EJABBERD_DIR"
    )
    if [ "${WIDGET_ENABLED:-false}" == "true" ]; then
        REQUIRED_DIRS+=("$WIDGET_DIR")
    fi
    
    for dir in "${REQUIRED_DIRS[@]}"; do
        # backend path is an either/or check (legacy vs new layout)
        if [[ "$dir" == "$BACKEND_DIR/backend" || "$dir" == "$BACKEND_DIR/services/api" ]]; then
            continue
        fi
        if [ ! -d "$dir" ]; then error "Required directory not found: $dir"; fi
    done

    if [ ! -d "$BACKEND_DIR/backend" ] && [ ! -d "$BACKEND_DIR/services/api" ]; then
        error "Backend API directory not found. Expected either '$BACKEND_DIR/backend' (legacy) or '$BACKEND_DIR/services/api' (new layout)."
    fi
    
    log "Using paths:"
    log "  Base: $ROOT_DIR"
    log "  Backend: $BACKEND_DIR"
    log "  Frontend: $FRONTEND_DIR"
    log "  Ejabberd: $EJABBERD_DIR"
    if [ "${WIDGET_ENABLED:-false}" == "true" ]; then
        log "  Widget: $WIDGET_DIR"
    fi
fi

# Check if Docker is running
log "Checking Docker..."
if ! docker info > /dev/null 2>&1; then
    error "Docker is not running. Please start Docker."
fi

# Check if ports are available
log "Checking port availability..."

# If this is a re-run and the Ethora docker stack is already up, ports are expected to be in use.
# The installer will stop/recreate the stack as needed.
#
# IMPORTANT: don't rely on `docker-compose ps` here; depending on environment/paths it can error before showing status.
is_ethora_stack_running=false
if docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^(deploy_mongo_1|deploy_mysql_1|deploy_redis-server_1|deploy_minio_1|deploy_xmpp_1|centrifugo)$'; then
    is_ethora_stack_running=true
fi

if [ "$is_ethora_stack_running" == "true" ]; then
    warn "Detected an existing Ethora Docker stack already running. Skipping port availability checks (ports are expected to be in use)."
else

# Get ports from config if available, otherwise use defaults
MONGO_PORT=$(yq eval '.databases.mongo.port' "$CONFIG_FILE" 2>/dev/null || echo "27017")
MYSQL_PORT=$(yq eval '.databases.mysql.port' "$CONFIG_FILE" 2>/dev/null || echo "3306")
REDIS_PORT=$(yq eval '.databases.redis.port' "$CONFIG_FILE" 2>/dev/null || echo "6379")
BACKEND_PORT=$(yq eval '.services.backend.port' "$CONFIG_FILE" 2>/dev/null || echo "8080")
AI_SERVICE_PORT=$(yq eval '.services.ai_service.port' "$CONFIG_FILE" 2>/dev/null || echo "8013")
DOCS_PARSE_PORT=$(yq eval '.services.docs_parse_service.port' "$CONFIG_FILE" 2>/dev/null || echo "8201")

# NOTE: Port 80/443 are handled separately below.
# In production, nginx is expected to bind 80/443. For certbot standalone, nginx will be stopped temporarily.
PORTS=(
    "$MONGO_PORT"
    "$MYSQL_PORT"
    "$REDIS_PORT"
    "8000"  # Crawler
    "$BACKEND_PORT"
    "9000"  # MinIO API
    "9001"  # MinIO Console
    "8001"  # Centrifugo
    "5280"  # Ejabberd HTTP
    "5443"  # Ejabberd HTTPS
)

if [ "$AI_SERVICE_PORT" != "null" ] && [ -n "$AI_SERVICE_PORT" ]; then
    PORTS+=("$AI_SERVICE_PORT")
fi

if [ "$DOCS_PARSE_PORT" != "null" ] && [ -n "$DOCS_PARSE_PORT" ]; then
    PORTS+=("$DOCS_PARSE_PORT")
fi

PORT_CONFLICTS=()

check_port() {
    local port=$1
    local process_info=""
    
    # Try to find process using the port
    if command -v lsof &> /dev/null; then
        # LISTEN only (avoid showing established client connections as "conflicts")
        process_info=$(sudo lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -n 1)
    elif command -v fuser &> /dev/null; then
        local pid=$(sudo fuser $port/tcp 2>/dev/null | awk '{print $1}')
        if [ -n "$pid" ]; then
            process_info=$(ps -p $pid -o pid,comm,args 2>/dev/null | tail -n +2)
        fi
    fi
    
    if netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; then
        PORT_CONFLICTS+=("$port|$process_info")
        return 1
    fi
    return 0
}

is_nginx_listening_on_port() {
    local port="$1"
    # Return 0 if nginx is the only listener we can detect (best effort).
    if command -v lsof &> /dev/null; then
        local cmd
        cmd="$(sudo lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $1}' | head -n 1)"
        [ "$cmd" == "nginx" ]
        return $?
    fi
    return 1
}

PORT_80_IN_USE=false
PORT_443_IN_USE=false
if ss -tuln 2>/dev/null | grep -q ":80 " || netstat -tuln 2>/dev/null | grep -q ":80 "; then
    PORT_80_IN_USE=true
fi
if ss -tuln 2>/dev/null | grep -q ":443 " || netstat -tuln 2>/dev/null | grep -q ":443 "; then
    PORT_443_IN_USE=true
fi

# Special handling for 80/443
SSL_METHOD=$(yq eval '.ssl.method' "$CONFIG_FILE" 2>/dev/null || echo "certbot")
if [ "$API_DOMAIN" != "localhost" ]; then
    if [ "$PORT_80_IN_USE" == "true" ] && ! is_nginx_listening_on_port 80; then
        warn "Port 80 is already in use by a non-nginx process. Certbot (standalone) requires port 80."
        warn "Stop the service using port 80, or switch ssl.method to 'provided'."
    fi
    if [ "$PORT_443_IN_USE" == "true" ] && ! is_nginx_listening_on_port 443; then
        warn "Port 443 is already in use by a non-nginx process. Nginx will need to bind 443 for HTTPS."
        warn "Stop the service using port 443 before continuing."
    fi
fi

for port in "${PORTS[@]}"; do
    if ! check_port "$port"; then
        warn "Port $port is already in use"
        if [ ${#PORT_CONFLICTS[@]} -gt 0 ]; then
            for conflict in "${PORT_CONFLICTS[@]}"; do
                if [[ "$conflict" == "$port|"* ]]; then
                    process_info="${conflict#*|}"
                    if [ -n "$process_info" ]; then
                        echo "  Process using port $port: $process_info"
                    fi
                fi
            done
        fi
    fi
done

# If there are conflicts, offer to kill processes
if [ ${#PORT_CONFLICTS[@]} -gt 0 ]; then
    echo
    warn "Port conflicts detected. You have the following options:"
    echo "  1. Stop the conflicting services manually"
    echo "  2. Change ports in deploy.yml"
    echo "  3. Let the script attempt to kill processes using these ports (interactive)"
    echo
    read -p "Would you like to attempt to kill processes using these ports? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for conflict in "${PORT_CONFLICTS[@]}"; do
            port="${conflict%%|*}"
            process_info="${conflict#*|}"
            
            if command -v lsof &> /dev/null; then
                # LISTEN only (avoid killing clients that merely have established connections)
                pids=$(sudo lsof -nP -tiTCP:$port -sTCP:LISTEN 2>/dev/null)
                if [ -n "$pids" ]; then
                    for pid in $pids; do
                        process_name=$(ps -p $pid -o comm= 2>/dev/null)
                        read -p "Kill process $pid ($process_name) using port $port? (y/N): " -n 1 -r
                        echo
                        if [[ $REPLY =~ ^[Yy]$ ]]; then
                            if sudo kill -9 $pid 2>/dev/null; then
                                log "Killed process $pid using port $port"
                            else
                                warn "Failed to kill process $pid"
                            fi
                        fi
                    done
                fi
            elif command -v fuser &> /dev/null; then
                pids=$(sudo fuser $port/tcp 2>/dev/null | awk '{print $1}')
                if [ -n "$pids" ]; then
                    for pid in $pids; do
                        process_name=$(ps -p $pid -o comm= 2>/dev/null)
                        read -p "Kill process $pid ($process_name) using port $port? (y/N): " -n 1 -r
                        echo
                        if [[ $REPLY =~ ^[Yy]$ ]]; then
                            if sudo kill -9 $pid 2>/dev/null; then
                                log "Killed process $pid using port $port"
                            else
                                warn "Failed to kill process $pid"
                            fi
                        fi
                    done
                fi
            fi
        done
        
        # Re-check ports after killing
        log "Re-checking ports..."
        RECHECK_FAILED=0
        for port in "${PORTS[@]}"; do
            if ! check_port "$port"; then
                RECHECK_FAILED=1
                warn "Port $port is still in use"
            fi
        done
        
        if [ $RECHECK_FAILED -eq 1 ]; then
            error "Some ports are still in use. Please resolve conflicts manually or change ports in deploy.yml"
        else
            log "All ports are now available"
        fi
    else
        warn "Continuing with port conflicts. Services may fail to start."
    fi
fi

fi # end: skip port check when stack is already running

# Check SSL method
SSL_METHOD=$(yq eval '.ssl.method' "$CONFIG_FILE" 2>/dev/null || echo "certbot")
if [ "$SSL_METHOD" == "provided" ]; then
    CERT_PATH=$(yq eval '.ssl.cert_path' "$CONFIG_FILE" 2>/dev/null || echo "")
    KEY_PATH=$(yq eval '.ssl.key_path' "$CONFIG_FILE" 2>/dev/null || echo "")
    
    if [ -z "$CERT_PATH" ] || [ -z "$KEY_PATH" ]; then
        error "SSL method is 'provided' but cert_path or key_path is not specified"
    fi
    
    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
        error "SSL certificate files not found: $CERT_PATH or $KEY_PATH"
    fi
fi

if [ "${HOSTED_APPS_ENABLED:-false}" == "true" ] && [ -n "${HOSTED_APPS_CERT_PATH:-}" ]; then
    if [ ! -f "$HOSTED_APPS_CERT_PATH" ] || [ ! -f "$HOSTED_APPS_KEY_PATH" ]; then
        error "Hosted apps SSL certificate files not found: $HOSTED_APPS_CERT_PATH or $HOSTED_APPS_KEY_PATH"
    fi
fi

# Check Node.js version
log "Checking Node.js version..."
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
    if [ "$NODE_VERSION" -lt 24 ]; then
        warn "Node.js version should be 24 or higher. Current: $(node --version)"
    fi
else
    error "Node.js is not installed"
fi

# Check if PM2 is installed (warn if not, as it will be needed)
if ! command -v pm2 &> /dev/null; then
    warn "PM2 is not installed. It will be needed to run Node.js services."
fi

log "Validation completed successfully"

