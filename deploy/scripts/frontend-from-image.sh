#!/bin/bash
# Deploy the admin panel / web app from the prebuilt ethora-frontend image
# instead of building it from source on this host.
#
# The image carries one universal bundle; this script renders /config.js and
# the CSP origins from the frontend .env that setup-env.sh already produced,
# and drops the result into the directory host nginx serves
# (deploy/nginx/web.conf.template `root`), so nothing else on the host
# changes. Re-run after every `setup-env.sh` (domains, toggles) or to move
# to a new image tag.
#
#   ETHORA_FRONTEND_IMAGE=docker.io/dappros/ethora-frontend:2610 \
#   deploy/scripts/frontend-from-image.sh
#
# Env:
#   ETHORA_FRONTEND_IMAGE   image ref (default docker.io/dappros/ethora-frontend:2610)
#   FRONTEND_ENV_FILE       rendered frontend env (default <root>/ethora-app-reactjs/.env)
#   FRONTEND_BUILD_DIR      output dir (default <root>/ethora-app-reactjs/dist)
#   DOCKER_ENV_FILE         where the docker-clean env copy is written
#                           (default deploy/generated/frontend.image.env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

IMAGE="${ETHORA_FRONTEND_IMAGE:-docker.io/dappros/ethora-frontend:2610}"
ENV_FILE="${FRONTEND_ENV_FILE:-$ROOT_DIR/ethora-app-reactjs/.env}"
OUT_DIR="${FRONTEND_BUILD_DIR:-$ROOT_DIR/ethora-app-reactjs/dist}"
DOCKER_ENV="${DOCKER_ENV_FILE:-$DEPLOY_DIR/generated/frontend.image.env}"

log() { echo "[frontend-from-image] $*"; }
die() { echo "[frontend-from-image] ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required"
[ -f "$ENV_FILE" ] || die "frontend env not found at $ENV_FILE (run deploy/scripts/setup-env.sh first)"

# Docker's --env-file accepts KEY=value lines only. The rendered .env still
# carries comments and a couple of template leftovers, so write a clean copy.
mkdir -p "$(dirname "$DOCKER_ENV")"
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | grep -vE '\{\{|_PLACEHOLDER$' > "$DOCKER_ENV"
chmod 600 "$DOCKER_ENV"
log "using $(grep -c '^VITE_' "$DOCKER_ENV") VITE_* values from $ENV_FILE"

# A locally loaded image (docker load, or a local build) is used as-is;
# anything else is pulled. ETHORA_FRONTEND_PULL=always forces a pull.
if [ "${ETHORA_FRONTEND_PULL:-auto}" = "always" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "pulling $IMAGE"
  docker pull --quiet "$IMAGE" >/dev/null
else
  log "using local image $IMAGE"
fi

# Render into a staging directory, then swap, so nginx never serves a
# half-written bundle.
STAGE="$(mktemp -d "${OUT_DIR%/}.image.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
# Run as the invoking user so the exported files are ours to replace on
# the next run (a root-owned tree cannot be cleaned up without sudo).
docker run --rm --user "$(id -u):$(id -g)" --env-file "$DOCKER_ENV" -v "$STAGE:/out" "$IMAGE" export /out >/dev/null
[ -f "$STAGE/index.html" ] && [ -f "$STAGE/config.js" ] || die "image did not produce a bundle"
grep -q '__ETHORA_CSP_ENV_ORIGINS__' "$STAGE/index.html" && die "CSP placeholder was not rendered; image and script disagree"

# mktemp creates the staging dir mode 700; the web server runs as another
# user, so open it up (dirs 755, files 644) and keep the ownership the
# previous bundle had (what setup-nginx / the source build produced), falling
# back to the parent directory's owner on a first deploy.
chmod -R u+rwX,go+rX,go-w "$STAGE"
if [ -d "$OUT_DIR" ]; then
  owner="$(stat -c '%u:%g' "$OUT_DIR" 2>/dev/null || true)"
else
  owner="$(stat -c '%u:%g' "$(dirname "$OUT_DIR")" 2>/dev/null || true)"
fi
[ -n "$owner" ] && chown -R "$owner" "$STAGE" 2>/dev/null || true

if [ -d "$OUT_DIR" ]; then
  OLD="$(mktemp -d "${OUT_DIR%/}.old.XXXXXX")"
  mv "$OUT_DIR" "$OLD/dist"
fi
mv "$STAGE" "$OUT_DIR"
trap - EXIT
[ -n "${OLD:-}" ] && rm -rf "$OLD"

log "bundle from $IMAGE is live at $OUT_DIR"
log "version: $(grep -o '"VITE_BUILD_VERSION": "[^"]*"' "$OUT_DIR/config.js" || echo 'from image')"
