#!/bin/bash
# start.sh - entrypoint of the Ethora Core Cloudron app.
#
# Maps Cloudron's addons onto the compose bundle's renderer
# (/ethora/scripts/render-config.sh, see deploy/compose), renders every
# config file into /run/ethora/config, prepares the writable trees the
# read-only image needs, and hands over to supervisord
# (/etc/supervisor/conf.d/ethora.conf).
#
#   /app/data/secrets    generated secrets (initial admin password included)
#   /app/data/minio      uploaded files (MinIO, served under /files/)
#   /app/data/ejabberd   ejabberd's Mnesia database and HTTP uploads
#   /app/data/env.sh     optional operator settings, sourced on every start
#                        (any variable of deploy/compose/.env.example)
# MongoDB, MySQL and Redis are Cloudron addons; the chat archive shares the
# app's one MongoDB database.
set -eu

log() { echo "[ethora] $*"; }

mkdir -p /run/ethora /tmp/ethora-uploads \
  /app/data/minio /app/data/ejabberd/database /app/data/ejabberd/upload

# ------------------------------------------------------------ renderer --
# In a subshell, so the renderer's inputs (and env.sh) stay out of the
# processes' environment: caddy, for one, substitutes its whole environment
# into its config.
(
  if [ -f /app/data/env.sh ]; then
    log "loading /app/data/env.sh"
    set -a
    # shellcheck disable=SC1091
    . /app/data/env.sh
    set +a
  fi

  # One origin: the app's Cloudron domain. Cloudron's proxy terminates TLS and
  # forwards everything to caddy on :3000, which routes by path.
  export PUBLIC_URL="$CLOUDRON_APP_ORIGIN"
  export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@$CLOUDRON_APP_DOMAIN}"
  export ETHORA_SITE_ADDRESS=":3000"
  export CADDY_GLOBAL_OPTIONS="${CADDY_GLOBAL_OPTIONS:-auto_https off
  	admin off
  	servers {
  		trusted_proxies static private_ranges
  	}}"
  # The web app bundle, rendered below, served on loopback for the :3000 site.
  export ETHORA_EXTRA_SITES=":8081 {
  	bind 127.0.0.1
  	root * /run/ethora/html
  	encode gzip
  	@mutable not path /assets/*
  	header @mutable Cache-Control \"no-store, must-revalidate\"
  	header /assets/* Cache-Control \"public, max-age=31536000, immutable\"
  	try_files {path} /index.html
  	file_server
  }"

  # Addons.
  export ETHORA_MONGO_URI="$CLOUDRON_MONGODB_URL"
  export ETHORA_CHAT_DATABASE_URI="$CLOUDRON_MONGODB_URL"
  export MONGO_DB="$CLOUDRON_MONGODB_DATABASE"
  export ETHORA_MYSQL_HOST="$CLOUDRON_MYSQL_HOST"
  export ETHORA_MYSQL_PORT="$CLOUDRON_MYSQL_PORT"
  export ETHORA_MYSQL_USER="$CLOUDRON_MYSQL_USERNAME"
  export ETHORA_MYSQL_DATABASE="$CLOUDRON_MYSQL_DATABASE"
  export MYSQL_ROOT_PASSWORD="$CLOUDRON_MYSQL_PASSWORD"
  export ETHORA_REDIS_HOST="$CLOUDRON_REDIS_HOST"
  export ETHORA_REDIS_PORT="$CLOUDRON_REDIS_PORT"
  # In-app processes, on loopback.
  export ETHORA_MINIO_HOST=127.0.0.1 ETHORA_MINIO_PORT=9000
  export ETHORA_CENTRIFUGO_URL=http://127.0.0.1:8000
  export ETHORA_XMPP_URL=http://127.0.0.1:5280
  export ETHORA_API_URL=http://127.0.0.1:8080
  export ETHORA_FRONTEND_URL=http://127.0.0.1:8081
  # Everything runs as the cloudron user.
  export API_UID=1000 XMPP_UID=1000 CENTRIFUGO_UID=1000 MYSQL_UID=1000 MINIO_UID=1000 FRONTEND_UID=1000
  export CONFIG_OUT_DIR=/run/ethora/config SECRETS_DIR=/app/data/secrets MYSQL_INITDB_DIR=/run/ethora/mysql-initdb

  /bin/sh /ethora/scripts/render-config.sh
)

# ------------------------------------------------------- ejabberd schema --
# The compose bundle's MySQL loads it on first start; here the database is
# the addon's, so load it once, into the addon's database name.
mysql_cli() {
  MYSQL_PWD="$CLOUDRON_MYSQL_PASSWORD" mysql -h "$CLOUDRON_MYSQL_HOST" -P "$CLOUDRON_MYSQL_PORT" \
    -u "$CLOUDRON_MYSQL_USERNAME" "$CLOUDRON_MYSQL_DATABASE" "$@"
}
if [ -z "$(mysql_cli -N -e "SHOW TABLES LIKE 'users'")" ]; then
  log "loading the ejabberd schema into $CLOUDRON_MYSQL_DATABASE"
  sed -e '/^CREATE DATABASE /d' -e '/^USE /d' /ethora-dist/mysql2.sql | mysql_cli
fi

# ------------------------------------------------------- ejabberd home --
# /opt/ejabberd -> /run/ethora/ejabberd: the release's static files linked
# from /app/code/ejabberd, conf copied (xmpp-start.sh writes into it), the
# database and uploads in /app/data.
home=/run/ethora/ejabberd
rm -rf "$home"
mkdir -p "$home/logs"
for f in /app/code/ejabberd/* /app/code/ejabberd/.[!.]*; do
  case "${f##*/}" in conf|database|logs|upload) continue ;; esac
  ln -s "$f" "$home/${f##*/}"
done
cp -a /app/code/ejabberd/conf "$home/conf"
ln -s /app/data/ejabberd/database "$home/database"
ln -s /app/data/ejabberd/upload "$home/upload"

# ------------------------------------------------------------- web app --
rm -rf /run/ethora/html
cp -a /app/code/frontend/html /run/ethora/html
ETHORA_FRONTEND_ENV_FILE=/run/ethora/config/frontend/frontend.env \
  /bin/sh /ethora/scripts/frontend-start.sh render /run/ethora/html

chown -R cloudron:cloudron /run/ethora /tmp/ethora-uploads /app/data/minio /app/data/ejabberd

log "starting ${CLOUDRON_APP_ORIGIN}"
exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf --nodaemon -i Ethora
