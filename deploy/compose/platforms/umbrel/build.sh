#!/usr/bin/env bash
# build.sh - generate the Umbrel app package of Ethora Core in ethora/ (the
# directory to copy into getumbrel/umbrel-apps as-is) from the single-file
# form, deploy/compose/single/docker-compose.yml:
#
#   docker-compose.yml  the single file with anchors expanded, Umbrel's
#                       app_proxy in front of caddy (one origin on the
#                       app's port, plain HTTP, path routing), every named
#                       volume as a bind mount under ${APP_DATA_DIR}/data,
#                       images pinned from ../images.env (tag@digest), the
#                       admin password = APP_PASSWORD and the other secrets
#                       from exports.sh, restart on-failure on every service
#                       (Umbrel's linter asks for it on the one-shot steps
#                       too; they exit 0, so it never restarts them), no
#                       verify profile.
#   umbrel-app.yml      umbrel-app.in.yml with the release build as version.
#   exports.sh          copied.
#   data/<volume>/.gitkeep for every bind-mount source.
#
# Needs yq v4. Checked by deploy/scripts/tests/compose-bundle.test.sh
# (regenerate, expect no diff).
#   run: deploy/compose/platforms/umbrel/build.sh [--check]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGLE="$HERE/../../single/docker-compose.yml"
PINS="$HERE/../images.env"
PORT=8456
# Anchors are expanded in a first pass; yq >= 4.45 wants to be told to
# follow the YAML spec for merge keys (older versions do so already).
YQ_FLAGS=""
yq --help 2>/dev/null | grep -q -- --yaml-fix-merge-anchor-to-spec && YQ_FLAGS="--yaml-fix-merge-anchor-to-spec=true"

render_into() { # render_into <dir>
  local out="$1"
  set -a; # shellcheck disable=SC1090
  . "$PINS"; set +a
  mkdir -p "$out"
  {
    echo '# Ethora Core for umbrelOS. GENERATED from deploy/compose/single/docker-compose.yml'
    echo '# by deploy/compose/platforms/umbrel/build.sh; edit those, not this.'
    echo 'version: "3.7"'
    echo
    yq $YQ_FLAGS 'explode(.)' "$SINGLE" | PORT="$PORT" yq '
      del(.name) | del(.volumes) | del(.["x-logging"]) | del(.["x-api"])
      | del(.services.verify)
      | del(.services[] | select(has("profiles")))   # Enterprise modules: not in the store package
      | del(.services.caddy.ports) | del(.services.caddy.profiles)
      | del(.services.config.env_file)
      | (.services[] | select(.restart == "unless-stopped" or .restart == "no") | .restart) = "on-failure"
      | (.services[] | select(has("volumes")) | .volumes[] | select(test("^[a-z][a-z0-9-]*:")))
          |= sub("^([a-z][a-z0-9-]*):", "$${APP_DATA_DIR}/data/${1}:")
      | .services.config.image = strenv(ETHORA_COMPOSE_INIT_IMAGE)
      | .services.api.image = strenv(ETHORA_API_IMAGE)
      | .services.jobs.image = strenv(ETHORA_API_IMAGE)
      | .services.init.image = strenv(ETHORA_API_IMAGE)
      | .services.frontend.image = strenv(ETHORA_FRONTEND_IMAGE)
      | .services.xmpp.image = strenv(ETHORA_XMPP_IMAGE)
      | .services.mongo.image = strenv(MONGO_IMAGE)
      | .services["mongo-init"].image = strenv(MONGO_IMAGE)
      | .services.mysql.image = strenv(MYSQL_IMAGE)
      | .services.redis.image = strenv(REDIS_IMAGE)
      | .services.minio.image = strenv(MINIO_IMAGE)
      | .services.centrifugo.image = strenv(CENTRIFUGO_IMAGE)
      | .services.caddy.image = strenv(CADDY_IMAGE)
      | .services.config.environment = {
          "PUBLIC_URL": "http://${DEVICE_DOMAIN_NAME}:" + strenv(PORT),
          "ADMIN_EMAIL": "umbrel@umbrel.local",
          "ADMIN_PASSWORD": "${APP_PASSWORD}",
          "BASE_APP_DISPLAY_NAME": "Ethora",
          "ETHORA_LICENSE_CALL_HOME": "true",
          "JWT_SECRET": "${APP_ETHORA_JWT_SECRET}",
          "REFRESH_SECRET": "${APP_ETHORA_REFRESH_SECRET}",
          "XMPP_SECRET": "${APP_ETHORA_XMPP_SECRET}",
          "XMPP_JWT_SECRET": "${APP_ETHORA_XMPP_JWT_SECRET}",
          "CRYPTOPAIR_SECRET": "${APP_ETHORA_CRYPTOPAIR_SECRET}",
          "SECRET_FOR_DB_ENCRYPTION": "${APP_ETHORA_SECRET_FOR_DB_ENCRYPTION}",
          "SECRET_FOR_FILES_ENCRYPTION": "${APP_ETHORA_SECRET_FOR_FILES_ENCRYPTION}",
          "XMPP_ADMIN_PASSWORD": "${APP_ETHORA_XMPP_ADMIN_PASSWORD}",
          "INTERNAL_REQUESTS_SECRET": "${APP_ETHORA_INTERNAL_REQUESTS_SECRET}",
          "MYSQL_ROOT_PASSWORD": "${APP_ETHORA_MYSQL_ROOT_PASSWORD}",
          "MINIO_ROOT_USER": "${APP_ETHORA_MINIO_ROOT_USER}",
          "MINIO_ROOT_PASSWORD": "${APP_ETHORA_MINIO_ROOT_PASSWORD}",
          "CENTRIFUGO_API_KEY": "${APP_ETHORA_CENTRIFUGO_API_KEY}",
          "CENTRIFUGO_HMAC_SECRET": "${APP_ETHORA_CENTRIFUGO_HMAC_SECRET}",
          "CENTRIFUGO_ADMIN_PASSWORD": "${APP_ETHORA_CENTRIFUGO_ADMIN_PASSWORD}",
          "CENTRIFUGO_ADMIN_SECRET": "${APP_ETHORA_CENTRIFUGO_ADMIN_SECRET}"
        }
      | .services = ({"app_proxy": {"environment": {
          "APP_HOST": "ethora_caddy_1",
          "APP_PORT": 80,
          "PROXY_AUTH_WHITELIST": "/v1,/v1/*,/v2,/v2/*,/api-docs,/api-docs/*,/ws,/ws/*,/bosh,/bosh/*,/connection/*,/files/*"
        }}} + .services)
      | ... comments = ""
    ' -
  } > "$out/docker-compose.yml"
  sed "s/@VERSION@/$ETHORA_BUILD/" "$HERE/umbrel-app.in.yml" > "$out/umbrel-app.yml"
  cp "$HERE/exports.sh" "$out/exports.sh"
  # One bind-mount source per volume the remaining services use (the
  # Enterprise modules' volumes are not among them).
  local v
  for v in $(yq '.services[] | select(has("volumes")) | .volumes[]' "$out/docker-compose.yml" | sed -n 's#^\${APP_DATA_DIR}/data/\([a-z-]*\):.*#\1#p' | sort -u); do
    mkdir -p "$out/data/$v" && : > "$out/data/$v/.gitkeep"
  done
}

if [ "${1:-}" = "--check" ]; then
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
  render_into "$t/ethora"
  diff -ru "$HERE/ethora" "$t/ethora" && echo "[umbrel] $HERE/ethora is up to date"
else
  rm -rf "$HERE/ethora"
  render_into "$HERE/ethora"
  echo "[umbrel] wrote $HERE/ethora ($(find "$HERE/ethora" -type f | wc -l) files)"
fi
