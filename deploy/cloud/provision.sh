#!/bin/bash
# provision.sh - bake an Ethora Core cloud image: the steps every cloud shares.
# The Packer templates (deploy/aws, deploy/azure, deploy/digitalocean,
# deploy/vultr) upload this file and run it once per step, as root, with the
# step in ETHORA_STEP; what differs between clouds (login user, swap, ufw,
# how a detached pull survives the SSH session, the final hardening and
# generalisation) is a variable here or a step in the template.
#
# Steps, in order:
#   base        updates, Docker, Node (the setup page), the public installer
#               cloned at INSTALL_REF under $ETHORA_HOME/ethora-install-shared
#   pull-start  pull every image of the compose bundle, detached
#   pull-wait   wait for the pulls (the template runs it with expect_disconnect)
#   finish      check the pulls, enable the setup page in compose mode,
#               optional swap and firewall
#   clean       credentials, caches, logs and history; never the identity or
#               the SSH setup (cloud specific, done in the template)
#
# Variables: INSTALL_REF (main), INSTALL_REPO, ETHORA_USER (ubuntu|root),
# ETHORA_HOME (/home/ubuntu|/root), ETHORA_SWAP (e.g. 2G, empty = none),
# ETHORA_UFW (yes|no), PULL_RUNNER (nohup|systemd-run), PULL_TIMEOUT (seconds).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

STEP="${ETHORA_STEP:-base}"
INSTALL_REF="${INSTALL_REF:-main}"
INSTALL_REPO="${INSTALL_REPO:-https://github.com/dappros/ethora-install.git}"
ETHORA_USER="${ETHORA_USER:-ubuntu}"
ETHORA_HOME="${ETHORA_HOME:-/home/$ETHORA_USER}"
ETHORA_SWAP="${ETHORA_SWAP:-}"
ETHORA_UFW="${ETHORA_UFW:-no}"
PULL_RUNNER="${PULL_RUNNER:-nohup}"
PULL_TIMEOUT="${PULL_TIMEOUT:-3600}"
SRC="$ETHORA_HOME/ethora-install-shared"
BUNDLE="$SRC/deploy/compose"
PULL_LOG=/tmp/ethora-pulls.log
PULL_DONE=/tmp/ethora-pulls.done

log() { echo "[provision:$STEP] $*"; }
case "$STEP" in base|pull-start|pull-wait|finish|clean) ;; *) echo "unknown ETHORA_STEP: $STEP" >&2; exit 2 ;; esac
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

case "$STEP" in
base)
  # A fresh image runs cloud-init and unattended-upgrades at boot; both can
  # restart sshd under the build. Wait, then stop them.
  cloud-init status --wait >/dev/null 2>&1 || true
  systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
  systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
  id "$ETHORA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$ETHORA_USER"
  # Every pending update: the marketplaces scan the image.
  apt-get update -y
  apt-get -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade -y
  apt-get install -y --no-install-recommends ca-certificates curl gnupg git jq
  [ "$ETHORA_UFW" = yes ] && apt-get install -y --no-install-recommends ufw
  # Docker from the official repository (compose plugin included).
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin
  [ "$ETHORA_USER" = root ] || usermod -aG docker "$ETHORA_USER"
  # Node 24: the first-boot setup page is a dependency-free Node script.
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y --no-install-recommends nodejs
  # The public installer at the release ref. Recorded before the tree is
  # handed to the login user (git refuses another user's repository).
  rm -rf "$SRC"
  git clone --branch "$INSTALL_REF" --depth 1 "$INSTALL_REPO" "$SRC"
  git -C "$SRC" log -1 --format='%h %s' | tee "$SRC/.image-source"
  chown -R "$ETHORA_USER:$ETHORA_USER" "$SRC"
  docker --version; docker compose version; node --version
  ;;
pull-start)
  # Every image the bundle runs, from the compose file itself (including the
  # caddy and verify profiles), so the list never drifts from the bundle.
  cd "$BUNDLE"
  docker compose --profile caddy --profile verify config --images | sort -u > /tmp/ethora-images
  log "images: $(tr '\n' ' ' < /tmp/ethora-images)"
  rm -f "$PULL_DONE" "$PULL_LOG"
  script='for i in $(cat /tmp/ethora-images); do echo "== $i"; docker pull "$i" || echo "PULL FAILED: $i"; done; echo done > '"$PULL_DONE"
  if [ "$PULL_RUNNER" = systemd-run ]; then
    # A nohup child of the SSH session dies with it on some images (Azure).
    systemd-run --unit=ethora-pulls --collect --property=StandardOutput=file:$PULL_LOG --property=StandardError=file:$PULL_LOG bash -c "$script"
  else
    nohup bash -c "$script" > "$PULL_LOG" 2>&1 &
  fi
  log "pulls started ($PULL_RUNNER)"
  ;;
pull-wait)
  t=0
  while [ ! -f "$PULL_DONE" ]; do
    [ $t -lt "$PULL_TIMEOUT" ] || { echo "pulls did not finish in $PULL_TIMEOUT s"; tail -5 "$PULL_LOG" 2>/dev/null; exit 1; }
    sleep 15; t=$((t + 15)); tail -1 "$PULL_LOG" 2>/dev/null | cut -c1-100
  done
  ;;
finish)
  while [ ! -f "$PULL_DONE" ]; do sleep 15; done
  if grep -q 'PULL FAILED' "$PULL_LOG"; then grep 'PULL FAILED' "$PULL_LOG"; exit 1; fi
  for i in $(cat /tmp/ethora-images); do docker image inspect "$i" >/dev/null || { echo "missing image: $i"; exit 1; }; done
  docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}'
  rm -f "$PULL_DONE" "$PULL_LOG" /tmp/ethora-images
  # First-boot setup page, compose mode, single use; enabled, not started.
  "$SRC/deploy/setup-web/install-setup-web.sh" --mode compose --no-enable
  systemctl enable ethora-setup.service
  if [ -n "$ETHORA_SWAP" ] && [ ! -f /swapfile ]; then
    fallocate -l "$ETHORA_SWAP" /swapfile && chmod 600 /swapfile && mkswap /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  if [ "$ETHORA_UFW" = yes ]; then
    ufw limit ssh; ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 8888/tcp; ufw --force enable
  fi
  ;;
clean)
  rm -rf /root/.docker "$ETHORA_HOME/.docker" /root/.gitconfig "$ETHORA_HOME/.gitconfig" /root/.npm "$ETHORA_HOME/.npm" /root/.cache "$ETHORA_HOME/.cache"
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
  find /var/log -type f -exec truncate -s 0 {} +
  rm -f /root/.bash_history "$ETHORA_HOME/.bash_history"
  ;;
*) echo "unknown ETHORA_STEP: $STEP" >&2; exit 2 ;;
esac
