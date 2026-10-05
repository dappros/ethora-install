#!/bin/bash
# Provisioning of the Ethora Core Vultr image. Runs as root on the build
# instance from the Packer template next to it.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
mkdir -p /root/ethora-build
chmod +x /root/ethora-build/vultr-helper.sh
. /root/ethora-build/vultr-helper.sh
error_detect_on

# Vultr's cloud-init build (their per-instance scripts and metadata rely on it).
install_cloud_init latest

systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
apt_update_safe
apt_upgrade_safe
apt_safe ca-certificates curl gnupg git jq unzip rsync acl nginx certbot python3-certbot-nginx ufw

# docker (official repo)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt_update_safe
apt_safe docker-ce docker-ce-cli containerd.io docker-compose-plugin

# node 24 (the first-boot page is a Node script) + yq v4
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt_safe nodejs
wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" && chmod +x /usr/local/bin/yq

# the public installer at the release ref
git clone --branch "$INSTALL_REF" --depth 1 "$INSTALL_REPO" /root/ethora-install-shared
git -C /root/ethora-install-shared log -1 --format='%h %s' | tee /root/ethora-install-shared/.image-source

# every image an install needs
for i in $IMAGES; do echo "== $i"; docker pull "$i"; done
for i in $IMAGES; do docker image inspect "$i" >/dev/null || { echo "missing image: $i"; exit 1; }; done

# first-boot setup page (single use; password generated per instance, see setup-per-instance.sh)
/root/ethora-install-shared/deploy/setup-web/install-setup-web.sh --no-enable
systemctl enable ethora-setup.service

# swap for the 4 GB plan
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab

# firewall
ufw limit ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8888/tcp
ufw --force enable

# per-instance script and message of the day
mkdir -p /var/lib/cloud/scripts/per-instance /etc/ethora
install -m 0755 /root/ethora-build/setup-per-instance.sh /var/lib/cloud/scripts/per-instance/ethora-setup-password.sh
install -m 0755 /root/ethora-build/99-one-click /etc/update-motd.d/99-one-click

rm -rf /root/ethora-build /root/ethora.sh /root/.docker /root/.gitconfig /root/.npm /root/.cache
truncate -s 0 /etc/machine-id && rm -f /var/lib/dbus/machine-id && ln -s /etc/machine-id /var/lib/dbus/machine-id
clean_system
