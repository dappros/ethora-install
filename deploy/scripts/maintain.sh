#!/bin/bash

# Ethora System Maintenance Script
# Checks all services and restarts any that are down
# Can be run manually or scheduled via cron

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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Source environment variables
ENV_FILE="$DEPLOY_DIR/.deploy.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    error "Environment file not found: $ENV_FILE. Please run install.sh first."
    exit 1
fi

# Get paths from environment or use defaults
BACKEND_DIR="${BACKEND_DIR:-$ROOT_DIR/ethora-backend}"
FRONTEND_DIR="${FRONTEND_DIR:-$ROOT_DIR/ethora-app-reactjs}"
EJABBERD_DIR="${EJABBERD_DIR:-$ROOT_DIR/ejabberd-docker}"

# Backend repo layout support:
# - legacy layout:   $BACKEND_DIR/backend, $BACKEND_DIR/ai_service, $BACKEND_DIR/docs_parse_service
# - new layout:      $BACKEND_DIR/services/api, $BACKEND_DIR/services/ai/ai-service, $BACKEND_DIR/services/ai/docs-parse
if [ -d "$BACKEND_DIR/services/api" ]; then
    BACKEND_API_DIR="$BACKEND_DIR/services/api"
    AI_SERVICE_DIR="$BACKEND_DIR/services/ai/ai-service"
    DOCS_PARSE_DIR="$BACKEND_DIR/services/ai/docs-parse"
else
    BACKEND_API_DIR="$BACKEND_DIR/backend"
    AI_SERVICE_DIR="$BACKEND_DIR/ai_service"
    DOCS_PARSE_DIR="$BACKEND_DIR/docs_parse_service"
fi

RESTARTED_SERVICES=0
FAILED_SERVICES=0

# Check and restart PM2 service
check_pm2_service() {
    local service_name="$1"
    local service_path="$2"
    local start_command="$3"
    
    if ! command -v pm2 >/dev/null 2>&1; then
        warn "PM2 not installed, skipping PM2 service checks"
        return 1
    fi
    
    # Check if service is running
    if pm2 pid "$service_name" >/dev/null 2>&1; then
        local status=$(pm2 jlist 2>/dev/null | grep -o "\"name\":\"$service_name\".*\"pm2_env\":{[^}]*\"status\":\"[^\"]*\"" | grep -o "\"status\":\"[^\"]*\"" | cut -d'"' -f4)
        if [ "$status" == "online" ]; then
            info "✓ PM2 service '$service_name' is running"
            return 0
        fi
    fi
    
    # Service is not running, restart it
    warn "PM2 service '$service_name' is not running, attempting to restart..."
    
    if [ -n "$service_path" ] && [ -d "$service_path" ]; then
        cd "$service_path" || {
            error "Failed to change to $service_path"
            ((FAILED_SERVICES++))
            return 1
        }
    fi
    
    if eval "$start_command" >/dev/null 2>&1; then
        log "✓ Restarted PM2 service '$service_name'"
        ((RESTARTED_SERVICES++))
        return 0
    else
        error "✗ Failed to restart PM2 service '$service_name'"
        ((FAILED_SERVICES++))
        return 1
    fi
}

# Check and restart Docker container
check_docker_service() {
    local container_name="$1"
    local service_name="$2"
    
    # Check if container is running
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
        local status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
        if [ "$status" == "running" ]; then
            info "✓ Docker container '$container_name' is running"
            return 0
        fi
    fi
    
    # Container is not running, restart it
    warn "Docker container '$container_name' is not running, attempting to restart..."
    
    cd "$ROOT_DIR" || {
        error "Failed to change to root directory"
        ((FAILED_SERVICES++))
        return 1
    }
    
    export BACKEND_DIR
    # Backend data dir for docker bind-mounts (Mongo/Redis/MinIO). Keep consistent with ethora-backend docker-compose.yml.
    export BACKEND_DATA_DIR="${BACKEND_DIR}/infra/docker/data"
    export EJABBERD_DIR
    export ROOT_DIR
    
    if docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" up -d "$service_name" >/dev/null 2>&1; then
        log "✓ Restarted Docker container '$container_name'"
        ((RESTARTED_SERVICES++))
        sleep 2  # Give container time to start
        return 0
    else
        error "✗ Failed to restart Docker container '$container_name'"
        ((FAILED_SERVICES++))
        return 1
    fi
}

# Main maintenance function
main() {
    log "Starting Ethora system maintenance check"
    log "========================================"
    
    # Check Docker services
    log "Checking Docker services..."
    
    check_docker_service "deploy_mongo_1" "mongo"
    check_docker_service "deploy_mysql_1" "mysql"
    check_docker_service "deploy_redis-server_1" "redis-server"
    check_docker_service "deploy_minio_1" "minio"
    check_docker_service "deploy_xmpp_1" "xmpp"
    check_docker_service "centrifugo" "centrifugo"
    # Crawler is optional (AI feature). Only check/restart it when explicitly enabled.
    if [ "${CRAWLER_ENABLED:-false}" == "true" ]; then
        check_docker_service "crawler-service" "crawler"
    fi
    
    # Check PM2 services
    log "Checking PM2 services..."
    
    # Backend
    if [ -f "$BACKEND_API_DIR/dist/app.js" ] || [ -f "$BACKEND_API_DIR/dist/src/app.js" ]; then
        PM2_BACKEND_CWD="$BACKEND_API_DIR/dist"
        BACKEND_ENTRY="./app.js"
        if [ ! -f "$BACKEND_API_DIR/dist/app.js" ] && [ -f "$BACKEND_API_DIR/dist/src/app.js" ]; then
            BACKEND_ENTRY="./src/app.js"
        fi
        check_pm2_service "backend" "$PM2_BACKEND_CWD" "pm2 start $BACKEND_ENTRY --name backend --time --update-env"
    else
        warn "Backend not built, skipping backend check"
    fi

    # Backend jobs (optional)
    if [ -f "$BACKEND_API_DIR/dist/src/jobs.js" ] || [ -f "$BACKEND_API_DIR/dist/jobs.js" ]; then
        PM2_BACKEND_CWD="$BACKEND_API_DIR/dist"
        JOBS_ENTRY="./src/jobs.js"
        if [ ! -f "$BACKEND_API_DIR/dist/src/jobs.js" ] && [ -f "$BACKEND_API_DIR/dist/jobs.js" ]; then
            JOBS_ENTRY="./jobs.js"
        fi
        check_pm2_service "backend-jobs" "$PM2_BACKEND_CWD" "pm2 start $JOBS_ENTRY --name backend-jobs --time --update-env"
    fi

    # Backend bc.worker (Bull queue consumer for add-app-chat, walletPreCreating, web3request)
    if [ -f "$BACKEND_API_DIR/dist/src/worker/bc.worker.js" ] || [ -f "$BACKEND_API_DIR/dist/worker/bc.worker.js" ]; then
        PM2_BACKEND_CWD="$BACKEND_API_DIR/dist"
        BC_WORKER_ENTRY="./src/worker/bc.worker.js"
        if [ ! -f "$BACKEND_API_DIR/dist/src/worker/bc.worker.js" ] && [ -f "$BACKEND_API_DIR/dist/worker/bc.worker.js" ]; then
            BC_WORKER_ENTRY="./worker/bc.worker.js"
        fi
        check_pm2_service "backend-bc-worker" "$PM2_BACKEND_CWD" "pm2 start $BC_WORKER_ENTRY --name backend-bc-worker --time --update-env"
    fi
    
    # Frontend (check if in localhost mode)
    if [ "${API_DOMAIN}" == "localhost" ]; then
        if [ -d "$FRONTEND_DIR" ]; then
            check_pm2_service "frontend" "$FRONTEND_DIR" "pm2 start npm --name frontend --time --update-env -- run dev"
        fi
    else
        info "Frontend is in production mode (not managed by PM2)"
    fi
    
    # AI Service (if enabled)
    if [ "${AI_SERVICE_ENABLED}" == "true" ]; then
        if [ -f "$AI_SERVICE_DIR/dist/server.js" ]; then
            check_pm2_service "ai-service" "$AI_SERVICE_DIR" "pm2 start ./dist/server.js --name ai-service --time --update-env"
        else
            warn "AI service not built, skipping AI service check"
        fi
    fi
    
    # Docs Parse Service (if enabled)
    if [ "${DOCS_PARSE_ENABLED}" == "true" ]; then
        if [ -f "$DOCS_PARSE_DIR/ecosystem.config.js" ]; then
            check_pm2_service "docs-parse-service" "$DOCS_PARSE_DIR" "pm2 start ecosystem.config.js --only docs-parse --time --update-env"
        elif [ -f "$DOCS_PARSE_DIR/index.js" ]; then
            check_pm2_service "docs-parse-service" "$DOCS_PARSE_DIR" "pm2 start index.js --name docs-parse --time --update-env"
        else
            warn "Docs parse service not found, skipping docs parse service check"
        fi
    fi
    
    # pm2-exporter (pm2 process metrics for the monitoring stack) runs only
    # when services.monitoring.mode is local or remote; see setup-node-services.sh.
    MONITORING_MODE_FOR_PM2="$(sed -n 's/^MONITORING_MODE=//p' "$DEPLOY_DIR/monitoring/.env" 2>/dev/null | head -n1 | tr -d '"')"
    if [ "${MONITORING_MODE_FOR_PM2:-off}" != "off" ] && [ -f "$DEPLOY_DIR/monitoring/pm2-exporter/pm2-exporter.js" ]; then
        check_pm2_service "pm2-exporter" "$DEPLOY_DIR/monitoring/pm2-exporter" "pm2 start ./pm2-exporter.js --name pm2-exporter --time --update-env"
    fi

    # Summary
    log "========================================"
    log "Maintenance check completed"
    log "Services restarted: $RESTARTED_SERVICES"
    if [ $FAILED_SERVICES -gt 0 ]; then
        error "Services failed to restart: $FAILED_SERVICES"
        exit 1
    else
        log "All services are running"
        exit 0
    fi
}

# Parse command line arguments
DRY_RUN=false
if [[ "$1" == "--dry-run" ]] || [[ "$1" == "--check-only" ]]; then
    DRY_RUN=true
    log "Dry run mode - will only check, not restart"
fi

# Run main function
main "$@"

