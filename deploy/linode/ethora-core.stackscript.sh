#!/bin/bash
# <UDF name="root_domain" label="Root domain (api., app., xmpp., files. and secure-files. derive from it; a wildcard DNS record covers them). Leave empty to use <ip-with-dashes>.sslip.io, which needs no DNS." default="" />
# <UDF name="admin_email" label="Admin e-mail (platform admin, base app owner, Let's Encrypt contact)" example="you@example.com" />
# <UDF name="admin_password" label="Admin password (empty: generated, then in /root/ethora-admin-password.txt)" default="" />
# <UDF name="license_key" label="Enterprise license key (empty: Ethora Core, free)" default="" />
#
# Ethora Core on Akamai (Linode): installs the self-hosted chat and messaging
# server from the public installer (github.com/dappros/ethora-install) at
# first boot: Docker, then the compose bundle (deploy/compose) through
# deploy/cloud/install.sh, the same engine the cloud images' setup page runs.
# Ubuntu 24.04 LTS, 4 GB plan or larger. Log: /var/log/ethora-stackscript.log.
# Licence: https://ethora.com/legal/ethora-core-license/
set -uo pipefail
exec > >(tee -a /var/log/ethora-stackscript.log) 2>&1
echo "[ethora] $(date -u +%FT%TZ) start"
export DEBIAN_FRONTEND=noninteractive
SRC=/root/ethora-install-shared
BRANCH="${ETHORA_BRANCH:-main}"

# cloud-init and unattended-upgrades run at first boot; wait for the lock.
command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1 || true
for _ in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; sleep 5; done
apt-get update -qq && apt-get install -y -qq git curl >/dev/null

if [ -z "${ROOT_DOMAIN:-}" ]; then
  ip=$(curl -fs --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')
  ROOT_DOMAIN="$(echo "$ip" | tr . -).sslip.io"
  echo "[ethora] no root domain given; using $ROOT_DOMAIN"
fi
[ -n "${ADMIN_EMAIL:-}" ] || { echo "[ethora] ERROR: admin_email is required"; exit 1; }

# Docker and the installer checkout (the image bake's base step), then the install.
git clone -q --branch "$BRANCH" --depth 1 https://github.com/dappros/ethora-install.git "$SRC"
ETHORA_STEP=base INSTALL_REF="$BRANCH" ETHORA_USER=root ETHORA_HOME=/root bash "$SRC/deploy/cloud/provision.sh" || { echo "[ethora] provisioning failed"; exit 1; }
export ETHORA_SETUP_LICENSE_KEY="${LICENSE_KEY:-}"
export ETHORA_SETUP_ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
bash "$SRC/deploy/cloud/install.sh" --domain "$ROOT_DOMAIN" --admin-email "$ADMIN_EMAIL"
rc=$?
# The admin password lives in deploy/compose/.env; keep a copy for root.
pw=$(sed -n "s/^ADMIN_PASSWORD='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$SRC/deploy/compose/.env" 2>/dev/null | head -n 1)
[ -n "$pw" ] && ( umask 077; echo "$pw" > /root/ethora-admin-password.txt )
if [ "$rc" = 0 ]; then
  echo "[ethora] $(date -u +%FT%TZ) install complete: https://app.$ROOT_DOMAIN (admin password: /root/ethora-admin-password.txt)"
else
  echo "[ethora] install failed ($rc); see /var/log/ethora-stackscript.log and: cd $SRC/deploy/compose && docker compose logs"
fi
exit "$rc"
