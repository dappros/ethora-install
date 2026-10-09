#!/bin/bash
# Register the first-boot setup page as a systemd unit. Used by the AMI build
# (Packer) and usable by hand on any host with the monoserver checked out.
#
#   sudo deploy/setup-web/install-setup-web.sh [--port 8888] [--mode host|compose] [--no-enable]
#
# --mode compose runs the compose bundle (deploy/cloud/install.sh) instead of
# the host installer; it is what the cloud images use.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$HERE/../.." && pwd)"
PORT=8888; ENABLE=true; MODE=host
while [ $# -gt 0 ]; do case "$1" in --port) PORT="$2"; shift 2 ;; --mode) MODE="$2"; shift 2 ;; --no-enable) ENABLE=false; shift ;; *) echo "unknown option $1" >&2; exit 2 ;; esac; done
case "$MODE" in host|compose) ;; *) echo "--mode must be host or compose" >&2; exit 2 ;; esac
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node is required (install.sh installs it; on an AMI it is preinstalled)" >&2; exit 1; }
sed -e "s|__SOURCE_ROOT__|$SOURCE_ROOT|g" -e "s|SETUP_PORT=8888|SETUP_PORT=$PORT|" -e "s|__SETUP_MODE__|$MODE|" "$HERE/ethora-setup.service" > /etc/systemd/system/ethora-setup.service
mkdir -p /etc/ethora
systemctl daemon-reload
if [ "$ENABLE" = true ]; then
  systemctl enable ethora-setup.service >/dev/null
  systemctl restart ethora-setup.service
  echo "ethora-setup: enabled on port $PORT ($MODE mode); password = EC2 instance id, droplet id or Azure VM id (or see: journalctl -u ethora-setup)"
else
  echo "ethora-setup: unit installed ($MODE mode), not enabled"
fi
