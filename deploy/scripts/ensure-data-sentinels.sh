#!/bin/bash
#
# Drop a sentinel README into each stateful bind-mount target so any operator
# (or AI assistant) listing the data dirs sees a clear warning before deleting.
#
# Why this exists: stateful data paths default to locations nested under
# submodule directories (e.g. deploy/ethora-backend/infra/docker/data/mongo).
# Those look like stale-checkout dirs to anyone unfamiliar with the deploy
# layout, and we have lost a Mongo data directory because of an `rm -rf` on
# what was assumed to be code but actually contained live DB data.
#
# This script is idempotent. Call it from install.sh and update.sh after the
# stack is up. The sentinel does not prevent `rm -rf` — it just makes the
# data nature of the directory obvious to anyone looking.
#
# Resolution matches docker-compose.enterprise.yml's defaults:
#   ${BACKEND_DATA_DIR:-./ethora-backend/infra/docker/data}/mongo:/data/db
#   ${BACKEND_DATA_DIR:-./ethora-backend/infra/docker/data}/minio:/data
#   ${EJABBERD_DIR:-./ejabberd-docker}/docker-data/my-sql:/var/lib/mysql
#
# (compose's `./` resolves relative to the compose file's directory, i.e.
# $DEPLOY_DIR, so we replicate that here.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$DEPLOY_DIR/.deploy.env"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
fi

BACKEND_DATA_DIR_RESOLVED="${BACKEND_DATA_DIR:-$DEPLOY_DIR/ethora-backend/infra/docker/data}"
EJABBERD_DIR_RESOLVED="${EJABBERD_DIR:-$DEPLOY_DIR/ejabberd-docker}"

SENTINEL_NAME=".ETHORA-DO-NOT-DELETE-PRODUCTION-DATA.md"

# Honor per-service overrides (set by setup-env.sh / migrate-data-paths.sh)
# before falling back to the legacy umbrella paths. Keeps the sentinel
# writer in sync with whatever location docker actually mounts.
MONGO_PATH="${MONGO_DATA_DIR:-$BACKEND_DATA_DIR_RESOLVED/mongo}"
MINIO_PATH="${MINIO_DATA_DIR:-$BACKEND_DATA_DIR_RESOLVED/minio}"
MYSQL_PATH="${MYSQL_DATA_DIR:-$EJABBERD_DIR_RESOLVED/docker-data/my-sql}"
REDIS_PATH="${REDIS_DATA_DIR:-$BACKEND_DATA_DIR_RESOLVED/redis}"

declare -a TARGETS=(
  "$MONGO_PATH|MongoDB|user, app, chat, and platform state for the Ethora backend"
  "$MINIO_PATH|MinIO/S3|uploaded files, media, and avatars"
  "$MYSQL_PATH|MySQL|ejabberd XMPP server state (rosters, MUC rooms, offline messages)"
  "$REDIS_PATH|Redis|cache + queue state (durable if AOF/RDB enabled)"
)

# The sentinel is always written as a sibling file, never inside the
# bind-mounted data dir itself: several of these official images (confirmed
# for both mysql and mongo) run a `chown -R` over their datadir on every
# container (re)start. A host-written file in there (e.g. dropped by a
# sudo-run install.sh, while every other file was written by the container
# itself through Docker Desktop's bind-mount identity mapping) trips a real
# Permission denied on that chown, which is fatal (entrypoint runs under
# `set -e`) and crash-loops the container. Keeping the marker next to the
# directory still makes the data nature obvious to anyone browsing, without
# sitting inside a path an entrypoint recursively chowns.
write_sentinel() {
  local dir="$1"
  local service="$2"
  local what="$3"

  mkdir -p "$dir"

  local target="${dir%/}-$SENTINEL_NAME"
  cat > "$target" <<EOF
# ETHORA PRODUCTION DATA - DO NOT DELETE THIS DIRECTORY

Service:  **$service**
Contains: $what

This directory is the host-side bind-mount target that Docker mounts into
the **$service** container as its working data location. Every file under
here is **live production state**.

Deleting any file in this directory results in **permanent data loss**
unless you have an out-of-band backup (EBS snapshot, mongodump, etc).

## Why this directory might look like throwaway code

Stateful paths in this deploy default to locations nested under submodule
directory names, for example:

    deploy/ethora-backend/infra/docker/data/mongo
    deploy/ejabberd-docker/docker-data/my-sql

If you (or an AI assistant) see a path like \`deploy/ethora-backend/\`
or \`deploy/ejabberd-docker/\` that wasn't checked out by submodule init
and think "stale leftover, safe to remove" - **STOP**. The leaf
directories contain database state, not code.

## If you need to remove the parent directories anyway

Exclude the data subtree first:

    # WRONG (loses data):
    sudo rm -rf deploy/ethora-backend

    # RIGHT (keeps data):
    sudo find deploy/ethora-backend -mindepth 1 -maxdepth 1 \\
      ! -name infra -exec rm -rf {} +

Or use the dedicated reset tool, which understands the data layout:

    sudo deploy/scripts/install.sh --reset       # wipes app/user/chat data only
    sudo deploy/scripts/install.sh --reinstall   # wipes everything under paths.base

## Backups

This file does not back you up. Set up real backups for $service.
See deploy/docs/BACKUPS.md (or the deploy README) for the recommended
EBS snapshot + dump-to-S3 pattern.
EOF
  chmod 0644 "$target" 2>/dev/null || true
}

echo "[ensure-data-sentinels] Writing sentinels next to stateful data directories:"
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r dir service what <<< "$entry"
  write_sentinel "$dir" "$service" "$what"
  echo "  $service:  ${dir%/}-$SENTINEL_NAME"
done
