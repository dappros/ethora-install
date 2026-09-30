#!/usr/bin/env bash
# pin.sh - pin the Cloudron package to the release build in
# deploy/compose/platforms/images.env (the store packages' pins, written by
# pin-images.sh): the Dockerfile's image ARGs as tag@digest, and the
# manifest's upstreamVersion. After a release build:
#
#   deploy/compose/platforms/pin-images.sh 2610.9
#   deploy/cloudron/pin.sh
#
# Checked by deploy/scripts/tests/compose-bundle.test.sh (--check: exit 1
# when the files are not what this would write).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINS="$HERE/../compose/platforms/images.env"
check=""; [ "${1:-}" = "--check" ] && check=1

set -a; # shellcheck disable=SC1090
. "$PINS"; set +a

render() { # render <Dockerfile> <CloudronManifest.json> <out dir>
  awk '
    /^ARG API_IMAGE=/        { print "ARG API_IMAGE=" ENVIRON["ETHORA_API_IMAGE"]; next }
    /^ARG FRONTEND_IMAGE=/   { print "ARG FRONTEND_IMAGE=" ENVIRON["ETHORA_FRONTEND_IMAGE"]; next }
    /^ARG INIT_IMAGE=/       { print "ARG INIT_IMAGE=" ENVIRON["ETHORA_COMPOSE_INIT_IMAGE"]; next }
    /^ARG MINIO_IMAGE=/      { print "ARG MINIO_IMAGE=" ENVIRON["MINIO_IMAGE"]; next }
    /^ARG CENTRIFUGO_IMAGE=/ { print "ARG CENTRIFUGO_IMAGE=" ENVIRON["CENTRIFUGO_IMAGE"]; next }
    /^ARG CADDY_IMAGE=/      { print "ARG CADDY_IMAGE=" ENVIRON["CADDY_IMAGE"]; next }
    { print }' "$1" > "$3/Dockerfile"
  sed -E "s/^(  \"upstreamVersion\": )\"[^\"]*\"/\1\"$ETHORA_BUILD\"/" "$2" > "$3/CloudronManifest.json"
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
render "$HERE/Dockerfile" "$HERE/CloudronManifest.json" "$tmp"
if [ -n "$check" ]; then
  diff -u "$HERE/Dockerfile" "$tmp/Dockerfile" && diff -u "$HERE/CloudronManifest.json" "$tmp/CloudronManifest.json"
  exit
fi
cp "$tmp/Dockerfile" "$HERE/Dockerfile"
cp "$tmp/CloudronManifest.json" "$HERE/CloudronManifest.json"
echo "[pin] Cloudron package pinned to $ETHORA_BUILD"
