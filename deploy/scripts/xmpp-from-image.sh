#!/usr/bin/env bash
# xmpp-from-image.sh - ejabberd image mode.
#
# When deploy.yml says services.ejabberd.mode: image, pull the published
# ethora-xmpp image (if not present), extract the files the compose file
# mounts from the host (config templates, entrypoint, custom module sources,
# compiled beams) out of the image's /ethora-dist into $EJABBERD_DIR/docker,
# and tag the image as the name compose expects (deploy-xmpp) so
# docker-compose.enterprise.yml runs it without building. Everything after
# this point (config rendering, jwt.key, sitecert.pem, the module hash that
# purges stale beams) is identical to source mode. No-op in source mode.
#
# Runs before setup-ejabberd-config.sh on every install and update, so the
# templates always match the image that will run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CANONICAL_DEPLOY_CONFIG_FILE:-$DEPLOY_DIR/config/deploy.yml}"
ENV_FILE="${ENV_FILE:-$DEPLOY_DIR/.deploy.env}"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2; exit 1; }

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set +u; source "$ENV_FILE" >/dev/null 2>&1 || true; set -u
fi
ROOT_DIR="${ROOT_DIR:-$(cd "$DEPLOY_DIR/.." && pwd)}"
EJABBERD_DIR="${EJABBERD_DIR:-$ROOT_DIR/ejabberd-docker}"

mode="source"; image=""
if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    mode="$(yq eval '.services.ejabberd.mode // "source"' "$CONFIG_FILE" 2>/dev/null || echo source)"
    image="$(yq eval '.services.ejabberd.image // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
fi
[ "$mode" = "null" ] && mode="source"
[ "$image" = "null" ] && image=""
[ "$mode" = "image" ] || exit 0
[ -n "$image" ] || error "services.ejabberd.mode is image but services.ejabberd.image is empty"
command -v docker >/dev/null 2>&1 || error "docker is required for image mode"

if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "Pulling $image..."
    docker pull --quiet "$image" >/dev/null || error "could not pull $image (private images need: docker login ghcr.io)"
fi

dest="$EJABBERD_DIR/docker"
mkdir -p "$dest"
cid="$(docker create "$image")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
# docker cp merges into dest: rendered files that live next to the templates
# (jwt.key, sitecert.pem, a rendered ejabberd-prod.yml) are overwritten only
# where the image ships the same name, which is exactly the refresh we want.
docker cp "$cid:/ethora-dist/." "$dest/" || error "the image has no /ethora-dist; it predates image mode"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown -R "$SUDO_USER":"$SUDO_USER" "$dest" 2>/dev/null || true
fi
docker tag "$image" deploy-xmpp:latest
n="$(ls "$dest/custom_mod_compiled"/*.beam 2>/dev/null | wc -l)"
log "ejabberd runs from image $image (tagged deploy-xmpp); $n compiled modules and the config templates extracted to $dest"
