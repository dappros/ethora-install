#!/usr/bin/env bash
# build.sh - generate the CasaOS / ZimaOS app of Ethora Core
# (docker-compose.yml here, the file the AppStore takes as
# Apps/Ethora/docker-compose.yml) from the single-file form,
# deploy/compose/single/docker-compose.yml:
#
#   - anchors expanded, the bundled Caddy serving one origin over plain HTTP
#     on port 8456 (path routing; PUBLIC_URL is the device address, editable
#     in the install dialog), no 443, no verify profile, no .env file;
#   - every named volume as a bind mount under /DATA/AppData/$AppID;
#   - images at the exact release build of ../images.env (tag, no digest);
#   - secrets left empty, so the config service generates them per install
#     into /DATA/AppData/$AppID/secrets;
#   - the store metadata block x-casaos.
#
# Needs yq v4. Checked by deploy/scripts/tests/compose-bundle.test.sh
# (regenerate, expect no diff).
#   run: deploy/compose/platforms/casaos/build.sh [--check]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGLE="$HERE/../../single/docker-compose.yml"
PINS="$HERE/../images.env"
OUT="$HERE/docker-compose.yml"
PORT=8456
YQ_FLAGS=""
yq --help 2>/dev/null | grep -q -- --yaml-fix-merge-anchor-to-spec && YQ_FLAGS="--yaml-fix-merge-anchor-to-spec=true"

render() {
  set -a; # shellcheck disable=SC1090
  . "$PINS"; set +a
  tag() { printf '%s' "${1%@*}"; }   # tag@digest -> tag
  export T_INIT="$(tag "$ETHORA_COMPOSE_INIT_IMAGE")" T_API="$(tag "$ETHORA_API_IMAGE")" \
         T_FRONTEND="$(tag "$ETHORA_FRONTEND_IMAGE")" T_XMPP="$(tag "$ETHORA_XMPP_IMAGE")" \
         T_MONGO="$(tag "$MONGO_IMAGE")" T_MYSQL="$(tag "$MYSQL_IMAGE")" T_REDIS="$(tag "$REDIS_IMAGE")" \
         T_MINIO="$(tag "$MINIO_IMAGE")" T_CENTRIFUGO="$(tag "$CENTRIFUGO_IMAGE")" T_CADDY="$(tag "$CADDY_IMAGE")" \
         PORT VERSION="${ETHORA_BUILD:0:2}.$((10#${ETHORA_BUILD:2:2})).${ETHORA_BUILD#*.}"
  echo '# Ethora Core for CasaOS / ZimaOS. GENERATED from deploy/compose/single/docker-compose.yml'
  echo '# by deploy/compose/platforms/casaos/build.sh; edit those, not this.'
  yq $YQ_FLAGS 'explode(.)' "$SINGLE" | yq '
    del(.volumes) | del(.["x-logging"]) | del(.["x-api"])
    | del(.services.verify)
    | del(.services[] | select(has("profiles")))   # Enterprise modules: not in the store package
    | del(.services.caddy.profiles)
    | del(.services.config.env_file)
    | .services.caddy.ports = [{"target": 80, "published": strenv(PORT), "protocol": "tcp"}]
    | (.services[] | select(has("volumes")) | .volumes[] | select(test("^[a-z][a-z0-9-]*:")))
        |= sub("^([a-z][a-z0-9-]*):", "/DATA/AppData/$$AppID/${1}:")
    | .services.config.image = strenv(T_INIT)
    | .services.api.image = strenv(T_API)
    | .services.jobs.image = strenv(T_API)
    | .services.init.image = strenv(T_API)
    | .services.frontend.image = strenv(T_FRONTEND)
    | .services.xmpp.image = strenv(T_XMPP)
    | .services.mongo.image = strenv(T_MONGO)
    | .services["mongo-init"].image = strenv(T_MONGO)
    | .services.mysql.image = strenv(T_MYSQL)
    | .services.redis.image = strenv(T_REDIS)
    | .services.minio.image = strenv(T_MINIO)
    | .services.centrifugo.image = strenv(T_CENTRIFUGO)
    | .services.caddy.image = strenv(T_CADDY)
    | .services.config.environment = {
        "PUBLIC_URL": "http://casaos.local:" + strenv(PORT),
        "ADMIN_EMAIL": "admin@casaos.local",
        "ADMIN_PASSWORD": "",
        "BASE_APP_DISPLAY_NAME": "Ethora",
        "ETHORA_LICENSE_CALL_HOME": "true"
      }
    | ... comments = ""
    | .["x-casaos"] = {
        "id": "com.ethora.core",
        "architectures": ["amd64", "arm64"],
        "main": "caddy",
        "store_app_id": "ethora",
        "index": "/",
        "port_map": strenv(PORT),
        "scheme": "http",
        "category": "Social",
        "author": "Dappros",
        "developer": "Dappros",
        "icon": "https://cdn.jsdelivr.net/gh/IceWhaleTech/CasaOS-AppStore@main/Apps/Ethora/icon.svg",
        "thumbnail": "https://cdn.jsdelivr.net/gh/IceWhaleTech/CasaOS-AppStore@main/Apps/Ethora/thumbnail.png",
        "screenshot_link": [
          "https://cdn.jsdelivr.net/gh/IceWhaleTech/CasaOS-AppStore@main/Apps/Ethora/screenshot-1.png",
          "https://cdn.jsdelivr.net/gh/IceWhaleTech/CasaOS-AppStore@main/Apps/Ethora/screenshot-2.png",
          "https://cdn.jsdelivr.net/gh/IceWhaleTech/CasaOS-AppStore@main/Apps/Ethora/screenshot-3.png"
        ],
        "title": {"en_US": "Ethora"},
        "tagline": {"en_US": "Your own chat server with a web app, admin panel and SDKs"},
        "description": {"en_US": "Ethora is a chat and messaging platform you run yourself: a web chat and admin panel, an API, an XMPP server (ejabberd) and file storage, with mobile and web SDKs on top. This is Ethora Core: free, with per-server limits of 5 apps and 500 user accounts, raised to 10 and 5,000 by registering for free on the License page of the admin panel. Licence: https://ethora.com/legal/ethora-core-license/"},
        "tips": {"before_install": {"en_US": "Before installing, set two variables of the config container: PUBLIC_URL to the address you open this device by, with port " + strenv(PORT) + " (for example http://192.168.1.20:" + strenv(PORT) + "; shared file links point there), and ADMIN_PASSWORD to the password of the admin account (sign-in e-mail: ADMIN_EMAIL, admin@casaos.local by default). Left empty, a password is generated and printed once in the log of the config container. Every other secret is generated on the first start and kept under /DATA/AppData/ethora/secrets."}},
        "version": strenv(VERSION),
        "website": "https://ethora.com",
        "repo": "https://github.com/dappros/ethora-install",
        "support": "https://github.com/dappros/ethora-install/issues",
        "docs": "https://github.com/dappros/ethora-install/tree/main/deploy/compose"
      }
  ' -
}

if [ "${1:-}" = "--check" ]; then
  diff -u "$OUT" <(render) && echo "[casaos] $OUT is up to date"
else
  render > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
  echo "[casaos] wrote $OUT ($(wc -c < "$OUT") bytes)"
fi
