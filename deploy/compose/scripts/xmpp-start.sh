#!/bin/sh
# xmpp-start.sh - entrypoint of the xmpp service in the compose bundle.
#
# 1. Installs the ejabberd.yml and jwt.key the config service rendered.
# 2. Starts ejabberd through the image's own entrypoint.
# 3. In the background, once ejabberd answers, makes sure admin@<xmpp host>
#    exists with XMPP_ADMIN_PASSWORD (register, or change_password when it
#    already exists). The host installer does this with `docker exec ...
#    ejabberdctl`; here it runs in the container, where ejabberdctl can reach
#    the node, and it re-runs on every start so a changed password follows.
set -eu

CONF_SRC="${ETHORA_XMPP_CONFIG_DIR:-/ethora/config/xmpp}"
CONF_DIR=/opt/ejabberd/conf
CTL=/opt/ejabberd/bin/ejabberdctl

[ -r "$CONF_SRC/ejabberd.yml" ] || { echo "[xmpp] $CONF_SRC/ejabberd.yml missing; the config service did not run" >&2; exit 1; }
# XMPP_DOMAIN normally arrives from compose (${XMPP_DOMAIN:-xmpp.${ROOT_DOMAIN}}).
# A platform that resolves compose defaults itself (Coolify) hands an empty
# override through as an empty value, so fall back to the host the config
# service rendered into ejabberd.yml.
if [ -z "${XMPP_DOMAIN:-}" ]; then
  XMPP_DOMAIN="$(sed -n '/^hosts:/,/^[a-z]/{s/^  - //p;}' "$CONF_SRC/ejabberd.yml" | head -n 1)"
  export XMPP_DOMAIN
fi
# The password comes from the environment when compose passes it, else from
# the file the config service rendered (it may have generated it).
if [ -z "${XMPP_ADMIN_PASSWORD:-}" ] && [ -r "$CONF_SRC/admin-password" ]; then
  XMPP_ADMIN_PASSWORD="$(cat "$CONF_SRC/admin-password")"
  export XMPP_ADMIN_PASSWORD
fi
cp "$CONF_SRC/ejabberd.yml" "$CONF_DIR/ejabberd.yml"
cp "$CONF_SRC/jwt.key" "$CONF_DIR/jwt.key"
chmod 600 "$CONF_DIR/ejabberd.yml" "$CONF_DIR/jwt.key"

ensure_admin() {
  host="${XMPP_DOMAIN:?}"
  pass="${XMPP_ADMIN_PASSWORD:?}"
  i=0
  until "$CTL" status >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -gt 150 ] && { echo "[xmpp] ejabberd did not start within 5 minutes; admin account not ensured" >&2; return 1; }
    sleep 2
  done
  if "$CTL" check_account admin "$host" >/dev/null 2>&1; then
    "$CTL" change_password admin "$host" "$pass" >/dev/null 2>&1 \
      && echo "[xmpp] admin@$host present (password ensured)" \
      || echo "[xmpp] WARN: could not set the password of admin@$host" >&2
  else
    "$CTL" register admin "$host" "$pass" >/dev/null 2>&1 \
      && echo "[xmpp] admin@$host created" \
      || echo "[xmpp] WARN: could not register admin@$host" >&2
  fi
  : > /tmp/ethora-admin-ready
}
rm -f /tmp/ethora-admin-ready
ensure_admin &

exec /entrypoint.sh "$@"
