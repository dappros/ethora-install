#!/bin/bash
# <UDF name="root_domain" label="Root domain (api., app., xmpp. and files. derive from it). Leave empty to use <ip-with-dashes>.sslip.io, which needs no DNS." default="" />
# <UDF name="admin_email" label="Admin e-mail (platform admin, base app owner, Let's Encrypt contact)" example="you@example.com" />
# <UDF name="admin_password" label="Admin password (empty: generated, then in /root/ethora-admin-password.txt)" default="" />
# <UDF name="license_key" label="Enterprise license key (empty: Ethora Core, free)" default="" />
#
# Ethora Core on Akamai (Linode): installs the self-hosted chat and messaging
# server from the public installer (github.com/dappros/ethora-install) at
# first boot. Ubuntu 24.04 LTS, 4 GB plan or larger. Log:
# /var/log/ethora-stackscript.log. Same steps as the unattended path of the
# AWS CloudFormation template. Licence: https://ethora.com/legal/ethora-core-license/
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

git clone -q --branch "$BRANCH" --depth 1 https://github.com/dappros/ethora-install.git "$SRC"
export ETHORA_SETUP_LICENSE_KEY="${LICENSE_KEY:-}"
export ETHORA_SETUP_ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
bash "$SRC/deploy/scripts/setup.sh" --yes --domain "$ROOT_DOMAIN" --admin-email "$ADMIN_EMAIL" \
  --edition core --all-modes image --target /root/ethora
rc=$?
[ "$rc" = 0 ] || { echo "[ethora] setup.sh failed ($rc)"; exit "$rc"; }
# The generated admin password lives in deploy.yml; keep a copy for root.
pw=$(yq eval '.admin.password' "$SRC/deploy/config/deploy.yml" 2>/dev/null)
# Subshell: the umask must not leak into install.sh (rendered configs are read by container users).
[ -n "$pw" ] && [ "$pw" != null ] && ( umask 077; echo "$pw" > /root/ethora-admin-password.txt )

cd "$SRC/deploy" && NON_INTERACTIVE=true bash scripts/install.sh --yes
rc=$?
if [ "$rc" = 0 ]; then
  mkdir -p /etc/ethora && date -u +%FT%TZ > /etc/ethora/setup-done
  cat > /etc/update-motd.d/99-ethora <<MSG
#!/bin/sh
cat <<EOM
********************************************************************************
Ethora Core is installed. Web app and admin panel: https://app.$ROOT_DOMAIN
Admin e-mail: $ADMIN_EMAIL, password: see /root/ethora-admin-password.txt
Configuration: $SRC/deploy/config/deploy.yml, then deploy/scripts/update.sh
Data: /root/ethora-data (back this up). Docs: https://github.com/dappros/ethora-install
********************************************************************************
EOM
MSG
  chmod +x /etc/update-motd.d/99-ethora
  echo "[ethora] $(date -u +%FT%TZ) install complete: https://app.$ROOT_DOMAIN"
else
  echo "[ethora] install.sh failed ($rc); see /var/log/ethora-stackscript.log and $SRC/deploy/deploy.log"
fi
exit "$rc"
