#!/bin/bash
#
# Migrate stateful data (Mongo / MinIO / MySQL) from legacy bind-mount
# locations - nested under submodule directory names that look like
# leftover code - to a cleaner $ROOT_DIR/data/<service>/ layout.
#
# Why: we have lost a Mongo data directory because someone (an AI assistant
# in fact) saw `deploy/ethora-backend/` and recommended `rm -rf` of what
# looked like a stale submodule checkout. The leaf actually contained live
# Mongo state. Moving data out of submodule-named paths removes that trap.
#
# What this does:
#   1. Stops the compose stack (mongo, minio, mysql, and dependents)
#   2. For each service whose current bind path is "legacy" (inside an
#      ethora-backend/ or ejabberd-docker/ path), rsyncs the data to
#      $ROOT_DIR/data/<service>/
#   3. Persists explicit MONGO_DATA_DIR / MINIO_DATA_DIR / MYSQL_DATA_DIR
#      in .deploy.env so subsequent runs use the new location
#   4. Restarts the stack
#   5. Verifies the mount points changed and key data is present
#
# Safety:
#   - --dry-run shows what would happen without touching anything
#   - Original data is NOT removed (rsync without --delete; old dir is left
#     in place so you can manually `rm -rf` after verifying the new install
#     works). Cleanup is operator's call.
#   - Idempotent: re-running after success is a no-op.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$DEPLOY_DIR/.deploy.env"

DRY_RUN="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--dry-run]

Moves Mongo / MinIO / MySQL bind-mount data from legacy nested-under-submodule
locations to \$ROOT_DIR/data/<service>/ and updates .deploy.env to point at
the new paths.

Options:
  --dry-run    Show what would be moved, change nothing
  -h, --help   This help
EOF
      exit 0
      ;;
    *) echo "[ERROR] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
warn() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1" >&2; }
error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2; exit 1; }

[ -f "$ENV_FILE" ] || error "Missing $ENV_FILE - run install.sh first"
# shellcheck disable=SC1090
source "$ENV_FILE"

ROOT_DIR="${ROOT_DIR:?ROOT_DIR not set in $ENV_FILE}"
# Data migrates OUT of both trees into a dedicated dir, default $HOME/ethora-data.
_deploy_home() { getent passwd "${SUDO_USER:-$USER}" 2>/dev/null | cut -d: -f6 | grep . || echo "${HOME:-/root}"; }
NEW_ROOT="${DATA_DIR:-$(_deploy_home)/ethora-data}"

# Resolve the CURRENT data paths. Prefer explicit per-service vars, fall back
# to legacy umbrella vars, fall back to literal defaults that match what
# docker-compose.enterprise.yml ships.
LEGACY_BACKEND_DATA_DIR="${BACKEND_DATA_DIR:-$DEPLOY_DIR/ethora-backend/infra/docker/data}"
LEGACY_EJABBERD_DATA_DIR="${EJABBERD_DIR:-$DEPLOY_DIR/ejabberd-docker}/docker-data"

CURRENT_MONGO="${MONGO_DATA_DIR:-$LEGACY_BACKEND_DATA_DIR/mongo}"
CURRENT_MINIO="${MINIO_DATA_DIR:-$LEGACY_BACKEND_DATA_DIR/minio}"
CURRENT_MYSQL="${MYSQL_DATA_DIR:-$LEGACY_EJABBERD_DATA_DIR/my-sql}"
# In-place installs kept MySQL under the source tree's ejabberd-docker/. When
# EJABBERD_DIR has already been repointed at a not-yet-populated target tree,
# the derived path is empty while the live data still sits next to deploy/.
SRC_EJABBERD_MYSQL="$(cd "$DEPLOY_DIR/.." && pwd)/ejabberd-docker/docker-data/my-sql"
if [ -z "${MYSQL_DATA_DIR:-}" ] && [ ! -d "$CURRENT_MYSQL" ] && [ -d "$SRC_EJABBERD_MYSQL" ]; then
  CURRENT_MYSQL="$SRC_EJABBERD_MYSQL"
fi
CURRENT_REDIS="${REDIS_DATA_DIR:-$LEGACY_BACKEND_DATA_DIR/redis}"

declare -A MOVES=(
  [mongo]="$CURRENT_MONGO|$NEW_ROOT/mongo"
  [minio]="$CURRENT_MINIO|$NEW_ROOT/minio"
  [mysql]="$CURRENT_MYSQL|$NEW_ROOT/mysql"
  [redis]="$CURRENT_REDIS|$NEW_ROOT/redis"
)

# Ambiguity guard: if a service has data at MORE THAN ONE candidate location,
# refuse and make the operator consolidate - never guess which copy is live.
# This is exactly the two-Mongo-dirs situation behind the 2026-08 data-dir incident.
_nonempty() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null | head -1)" ]; }
for svc in mongo minio mysql redis; do
  case "$svc" in mysql) sub="ejabberd-docker/docker-data/my-sql" ;; *) sub="ethora-backend/infra/docker/data/$svc" ;; esac
  seen=" "; copies=""
  for cand in "${MOVES[$svc]%%|*}" "$DEPLOY_DIR/$sub" "$DEPLOY_DIR/../$sub" "$ROOT_DIR/$sub" "$NEW_ROOT/$svc"; do
    rp="$(readlink -f "$cand" 2>/dev/null || echo "$cand")"
    case "$seen" in *" $rp "*) continue ;; esac
    seen="$seen$rp "
    _nonempty "$cand" && copies="${copies}    $cand ($(du -sh "$cand" 2>/dev/null | cut -f1))"$'\n'
  done
  if [ "$(printf '%s' "$copies" | grep -c .)" -gt 1 ]; then
    error "$svc has data at MULTIPLE locations - refusing to guess which is live:
${copies}  Consolidate to ONE (delete/move the stale copies), or set ${svc^^}_DATA_DIR, then re-run."
  fi
done

is_legacy_path() {
  case "$1" in
    */ethora-backend/*|*/ejabberd-docker/*) return 0 ;;
    *) return 1 ;;
  esac
}

# What actually needs moving?
NEEDED_SERVICES=()
log "Inspecting current data paths:"
for svc in mongo minio mysql redis; do
  IFS='|' read -r src dst <<< "${MOVES[$svc]}"
  if [ "$src" = "$dst" ]; then
    log "  $svc: already at $dst (skip)"
    continue
  fi
  if ! is_legacy_path "$src"; then
    log "  $svc: $src (not a legacy nested path, skip)"
    continue
  fi
  if [ ! -d "$src" ] || [ -z "$(ls -A "$src" 2>/dev/null | head -1)" ]; then
    log "  $svc: $src empty / missing, will use new path $dst with no data move"
    NEEDED_SERVICES+=("$svc")
    continue
  fi
  log "  $svc: MOVE  $src  ->  $dst"
  NEEDED_SERVICES+=("$svc")
done

if [ "${#NEEDED_SERVICES[@]}" -eq 0 ]; then
  log "Nothing to migrate. .deploy.env paths are already clean."
  exit 0
fi

if [ "$DRY_RUN" = "true" ]; then
  log "--dry-run: no changes made"
  exit 0
fi

# Stop the affected services so rsync gets a clean copy (mongo's WT engine
# in particular doesn't like hot copies). We stop the whole stack because
# mysql is used by ejabberd, minio by backend, mongo by everything - safer.
# The compose file fails closed on unset *_DATA_DIR (no relative default), so
# hand it the paths the containers are running with NOW; a legacy .deploy.env
# has none of these set yet.
log "Stopping docker stack to migrate data..."
( cd "$DEPLOY_DIR" && \
  MONGO_DATA_DIR="$CURRENT_MONGO" MINIO_DATA_DIR="$CURRENT_MINIO" \
  MYSQL_DATA_DIR="$CURRENT_MYSQL" REDIS_DATA_DIR="$CURRENT_REDIS" \
  docker compose -f docker-compose.enterprise.yml stop ) || \
  warn "Some services were not running; continuing"

# Per service, rsync src -> dst (preserve permissions, no delete - keep src
# around as backup). Create the dst parent first.
for svc in "${NEEDED_SERVICES[@]}"; do
  IFS='|' read -r src dst <<< "${MOVES[$svc]}"
  mkdir -p "$(dirname "$dst")"
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null | head -1)" ]; then
    log "rsync $src/ -> $dst/"
    mkdir -p "$dst"
    rsync -a --info=progress2 "$src/" "$dst/" || error "rsync failed for $svc"
  else
    mkdir -p "$dst"
  fi
done

# Persist explicit per-service paths to .deploy.env so future runs of
# setup-env.sh / docker compose pick them up. Uses a sed -i so existing
# entries are replaced rather than duplicated.
write_env_var() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  grep -v -E "^(export[[:space:]]+)?${key}=" "$ENV_FILE" >"$tmp" 2>/dev/null || true
  echo "export ${key}=\"${value}\"" >>"$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 644 "$ENV_FILE" 2>/dev/null || true
}

log "Updating $ENV_FILE with new explicit paths..."
write_env_var "MONGO_DATA_DIR" "$NEW_ROOT/mongo"
write_env_var "MINIO_DATA_DIR" "$NEW_ROOT/minio"
write_env_var "MYSQL_DATA_DIR" "$NEW_ROOT/mysql"
write_env_var "REDIS_DATA_DIR" "$NEW_ROOT/redis"
write_env_var "DATA_DIR" "$NEW_ROOT"

# write_env_var only edits the file; export the same values here so the
# setup-env.sh and `compose up` calls below interpolate the NEW paths instead
# of failing on unset variables.
export DATA_DIR="$NEW_ROOT"
export MONGO_DATA_DIR="$NEW_ROOT/mongo" MINIO_DATA_DIR="$NEW_ROOT/minio"
export MYSQL_DATA_DIR="$NEW_ROOT/mysql" REDIS_DATA_DIR="$NEW_ROOT/redis"

# Drop sentinels into the new locations immediately so a `find` finds them.
if [ -x "$SCRIPT_DIR/ensure-data-sentinels.sh" ]; then
  bash "$SCRIPT_DIR/ensure-data-sentinels.sh" || true
fi

# Re-render rendered env files so backend / ejabberd / etc. see updated paths.
if [ -x "$SCRIPT_DIR/setup-env.sh" ]; then
  bash "$SCRIPT_DIR/setup-env.sh" || warn "setup-env.sh returned non-zero; review manually"
fi

# setup-env.sh persists more vars into .deploy.env; pick them up before compose.
# shellcheck disable=SC1090
source "$ENV_FILE"

# Render the ejabberd config and its JWT key file BEFORE the stack comes up.
# compose binds docker/jwt.key as a file; if it does not exist yet docker
# creates the mount point as a directory inside ejabberd's persistent volume
# and the container can never start again until that directory is removed.
if [ -x "$SCRIPT_DIR/setup-ejabberd-config.sh" ]; then
  bash "$SCRIPT_DIR/setup-ejabberd-config.sh" || warn "setup-ejabberd-config.sh returned non-zero; review manually"
fi

# Restart the stack.
log "Starting docker stack with new data paths..."
( cd "$DEPLOY_DIR" && docker compose -f docker-compose.enterprise.yml up -d )

# Verification: docker inspect each service's mount, confirm it matches.
sleep 3
log "Verifying mount points..."
verify_mount() {
  local container="$1"
  local container_path="$2"
  local expected_host_path="$3"
  local actual
  actual="$(docker inspect "$container" --format "{{range .Mounts}}{{if eq .Destination \"$container_path\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null || echo "")"
  if [ "$actual" = "$expected_host_path" ]; then
    log "  OK $container:$container_path -> $expected_host_path"
  else
    warn "  MISMATCH $container:$container_path -> actual='$actual' expected='$expected_host_path'"
  fi
}
verify_mount deploy-mongo-1        /data/db        "$NEW_ROOT/mongo"
verify_mount deploy-minio-1        /data           "$NEW_ROOT/minio"
verify_mount deploy-mysql-1        /var/lib/mysql  "$NEW_ROOT/mysql"
verify_mount deploy-redis-server-1 /data           "$NEW_ROOT/redis"

log ""
log "Migration complete."
log ""
log "Old data still lives at the legacy paths (rsync did NOT delete it):"
for svc in "${NEEDED_SERVICES[@]}"; do
  IFS='|' read -r src dst <<< "${MOVES[$svc]}"
  log "  $svc: $src"
done
log ""
log "After verifying the stack works at the new paths (give it a day or two"
log "of normal traffic), you can reclaim the disk with:"
for svc in "${NEEDED_SERVICES[@]}"; do
  IFS='|' read -r src dst <<< "${MOVES[$svc]}"
  log "  sudo rm -rf $src"
done
