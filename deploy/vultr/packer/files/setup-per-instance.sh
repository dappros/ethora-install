#!/bin/bash
# First boot of an Ethora Core Vultr instance: give the setup page a password.
# Vultr's metadata carries no instance id the page could use (EC2 and
# DigitalOcean do), so a random one is generated here, handed to the page
# through its environment file and shown at SSH login by the message of the
# day. Runs once per instance (cloud-init per-instance).
set -u
mkdir -p /etc/ethora
if [ ! -s /etc/ethora/setup-web.env ]; then
  ( umask 077; echo "SETUP_PASSWORD=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 16)" > /etc/ethora/setup-web.env )
fi
systemctl restart ethora-setup.service 2>/dev/null || true
echo "$(date -u) ethora setup page password written" >> /var/log/ethora-per-instance.log
