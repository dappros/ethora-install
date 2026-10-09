#!/bin/bash
# Provisioning of the Ethora Core Vultr image. Runs as root on the build
# instance from the Packer template next to it; the steps shared with the
# other clouds are deploy/cloud/provision.sh (uploaded to /root/ethora-build).
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
mkdir -p /root/ethora-build
chmod +x /root/ethora-build/vultr-helper.sh /root/ethora-build/provision.sh
. /root/ethora-build/vultr-helper.sh
error_detect_on

# Vultr's cloud-init build (their per-instance scripts and metadata rely on it).
install_cloud_init latest

export ETHORA_USER=root ETHORA_HOME=/root ETHORA_UFW=yes ETHORA_SWAP=2G
# Vultr keeps the SSH session up for the pulls, so they run in the foreground.
for step in base pull-start pull-wait finish; do
  ETHORA_STEP=$step PULL_RUNNER=nohup /root/ethora-build/provision.sh
done

# per-instance script and message of the day
mkdir -p /var/lib/cloud/scripts/per-instance /etc/ethora
install -m 0755 /root/ethora-build/setup-per-instance.sh /var/lib/cloud/scripts/per-instance/ethora-setup-password.sh
install -m 0755 /root/ethora-build/99-one-click /etc/update-motd.d/99-one-click

ETHORA_STEP=clean /root/ethora-build/provision.sh
rm -rf /root/ethora-build /root/ethora.sh
truncate -s 0 /etc/machine-id && rm -f /var/lib/dbus/machine-id && ln -s /etc/machine-id /var/lib/dbus/machine-id
clean_system
