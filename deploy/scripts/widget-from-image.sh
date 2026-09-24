#!/bin/bash
# Deploy the AI chat widget bundle from the prebuilt ethora-ai image instead
# of building it from source on this host (services.ai_service.mode: image).
#
# The image carries one bundle built with placeholders; this renders the
# VITE_WIDGET_* values from ethora-ai-chat-widget/.env.production.local
# (written by setup-env.sh) into it, writes the assistant.js /
# assistant<version>.js copies the platform serves, and swaps the result into
# the directory host nginx already serves (widget.conf.template `root`).
#
#   ETHORA_AI_IMAGE=ghcr.io/dappros/ethora-ai:2610 WIDGET_SCRIPT_VERSION=2610 \
#   deploy/scripts/widget-from-image.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
IMAGE="${ETHORA_AI_IMAGE:-ghcr.io/dappros/ethora-ai:2610}"
WIDGET_DIR="${WIDGET_DIR:-$ROOT_DIR/ethora-ai-chat-widget}"
ENV_FILE="${WIDGET_ENV_FILE:-$WIDGET_DIR/.env.production.local}"
OUT_DIR="${WIDGET_BUILD_DIR:-$WIDGET_DIR/dist}"
DOCKER_ENV="${DOCKER_ENV_FILE:-$DEPLOY_DIR/generated/widget.image.env}"
log() { echo "[widget-from-image] $*"; }
die() { echo "[widget-from-image] ERROR: $*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || die "docker is required"
[ -f "$ENV_FILE" ] || die "widget env not found at $ENV_FILE (run deploy/scripts/setup-env.sh first)"
mkdir -p "$(dirname "$DOCKER_ENV")"
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | grep -vE '\{\{|_PLACEHOLDER$' > "$DOCKER_ENV"
[ -n "${WIDGET_SCRIPT_VERSION:-}" ] && echo "WIDGET_SCRIPT_VERSION=$WIDGET_SCRIPT_VERSION" >> "$DOCKER_ENV"
chmod 600 "$DOCKER_ENV"
if [ "${ETHORA_AI_PULL:-auto}" = "always" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "pulling $IMAGE"; docker pull --quiet "$IMAGE" >/dev/null
else
  log "using local image $IMAGE"
fi
mkdir -p "$(dirname "$OUT_DIR")"
STAGE="$(mktemp -d "${OUT_DIR%/}.image.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
docker run --rm --user "$(id -u):$(id -g)" --env-file "$DOCKER_ENV" -v "$STAGE:/out" "$IMAGE" widget-export /out >/dev/null
[ -f "$STAGE/assistant.js" ] || die "image did not produce assistant.js"
grep -q "__ETHORA_WIDGET_" "$STAGE/assistant.js" && die "widget placeholders were not rendered; image and script disagree"
chmod -R u+rwX,go+rX,go-w "$STAGE"
if [ -d "$OUT_DIR" ]; then owner="$(stat -c '%u:%g' "$OUT_DIR" 2>/dev/null || true)"; else owner="$(stat -c '%u:%g' "$(dirname "$OUT_DIR")" 2>/dev/null || true)"; fi
[ -n "$owner" ] && chown -R "$owner" "$STAGE" 2>/dev/null || true
if [ -d "$OUT_DIR" ]; then OLD="$(mktemp -d "${OUT_DIR%/}.old.XXXXXX")"; mv "$OUT_DIR" "$OLD/dist"; fi
mv "$STAGE" "$OUT_DIR"; trap - EXIT
[ -n "${OLD:-}" ] && rm -rf "$OLD"
log "widget bundle from $IMAGE is live at $OUT_DIR"
