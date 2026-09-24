#!/bin/bash

# Quick test script for localhost deployment
# This script helps test the deployment automation locally

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

log "Setting up for localhost testing..."

# Check if deploy.yml exists, if not create from local template
if [ ! -f "$DEPLOY_DIR/config/deploy.yml" ]; then
    log "Creating deploy.yml from localhost template..."
    cp "$DEPLOY_DIR/config/deploy-local.yml.template" "$DEPLOY_DIR/config/deploy.yml"
    log "Configuration file created. You can edit it if needed: $DEPLOY_DIR/config/deploy.yml"
else
    log "Using existing deploy.yml"
fi

# Run the installer
log "Starting installation..."
"$SCRIPT_DIR/install.sh"

log "Installation complete!"
log ""
log "Services should now be accessible on:"
log "  - Backend API: http://localhost:8080"
log "  - Ejabberd: http://localhost:5280 (HTTP), https://localhost:5443 (HTTPS)"
log "  - MinIO: http://localhost:9000 (API), http://localhost:9001 (Console)"
log ""
log "Test the API:"
log "  curl http://localhost:8080/v1/ping"
log ""
log "Run health checks:"
log "  ./scripts/health-check.sh"


