#!/usr/bin/env bash
# Ethora Core bootstrap: clone the installer and run it.
#
#   curl -fsSL https://raw.githubusercontent.com/dappros/ethora-install/2610/get.sh | bash -s -- --domain chat.example.com --admin-email you@example.com
#
# Without arguments it asks for the domain and e-mail (needs a terminal).
# Everything else is the documented two steps: setup.sh, then sudo install.sh.
set -euo pipefail

main() {

  BRANCH="${ETHORA_BRANCH:-2610}"
  DEST="${ETHORA_DIR:-$HOME/ethora-install-shared}"
  REPO="https://github.com/dappros/ethora-install.git"

  say() { printf '\033[1;34m[ethora]\033[0m %s\n' "$*"; }
  die() { printf '\033[1;31m[ethora] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

  [ "$(id -u)" != 0 ] || die "run this as a normal user with sudo, not as root"
  command -v sudo >/dev/null 2>&1 || die "sudo is required"
  case "$(. /etc/os-release 2>/dev/null && echo "${ID:-}")" in ubuntu|debian) ;; *) say "warning: only Ubuntu is tested";; esac

  if ! command -v git >/dev/null 2>&1; then
    say "installing git"
    sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null
  fi

  if [ -d "$DEST/.git" ]; then
    say "updating $DEST"
    git -C "$DEST" fetch -q origin "$BRANCH" && git -C "$DEST" checkout -q "$BRANCH" && git -C "$DEST" pull -q --ff-only
  else
    say "cloning $REPO ($BRANCH) into $DEST"
    git clone -q -b "$BRANCH" "$REPO" "$DEST"
  fi
  cd "$DEST"

  # When piped from curl, stdin is the script; give setup.sh the terminal so it
  # can prompt for what was not passed as arguments. Without a usable terminal
  # (cloud-init, ssh without -t) setup.sh takes its defaults instead.
  if [ ! -t 0 ] && ( : </dev/tty ) 2>/dev/null; then exec </dev/tty; fi

  # A second run must not regenerate the secrets of a working install:
  # reconfigure from the existing file instead (--from keeps every value not
  # overridden by an argument).
  if [ -f deploy/config/deploy.yml ]; then
    say "existing deploy/config/deploy.yml found; reconfiguring from it (secrets kept)"
    set -- --from deploy/config/deploy.yml "$@"
  fi
  say "configuring (deploy/scripts/setup.sh)"
  deploy/scripts/setup.sh "$@"

  say "installing (sudo deploy/scripts/install.sh); this takes about 10 minutes"
  sudo deploy/scripts/install.sh
}

main "$@"
