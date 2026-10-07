#!/bin/bash
#
# Fast staging update script (Git-based).
# - Checks out a ref (branch/tag/sha), updates submodules, regenerates .env files, restarts services
# - Runs quick QA checks
# - Supports rollback to a previous SHA
#
# Usage:
#   sudo ./deploy/scripts/update.sh --ref dev
#   sudo ./deploy/scripts/update.sh --ref <sha-or-tag>
#   sudo ./deploy/scripts/update.sh --rollback <sha>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

DEFAULT_ROOT_DIR="$ROOT_DIR"

# We may run this script from a git checkout (monoserver), but deploy into a target ROOT_DIR
# (e.g. /home/<user>/deptest). In that case, prefer the target's deploy env if present.
ENV_FILE="$DEPLOY_DIR/.deploy.env"
RUNTIME_DEPLOY_DIR="$DEPLOY_DIR"
STATE_DIR="$DEPLOY_DIR/.deploy-state"
LAST_SHA_FILE="$STATE_DIR/last-sha"

REF="dev"
ROLLBACK_SHA=""
NO_QA="false"
# Overridable from .deploy.env too, for a host that has to hold migrations back.
SKIP_MIGRATIONS="false"

# CLI overrides should win over values sourced from .deploy.env.
# We parse args early into CLI_* vars, then apply them after sourcing env.
CLI_REF=""
CLI_ROLLBACK_SHA=""
CLI_NO_QA=""
CLI_SKIP_MIGRATIONS=""

# Original argv, kept verbatim so a self re-exec (see maybe_reexec_updated_script)
# can replay the same invocation against the newer script the deployed ref ships.
ORIGINAL_ARGS=("$@")
NO_REEXEC="false"

usage() {
  cat <<EOF
Usage: $0 [--ref <ref>] [--rollback <sha>] [--no-qa] [--skip-migrations] [--no-reexec]

Options:
  --ref <ref>        Git ref to deploy (default: ${REF})
  --rollback <sha>   Roll back to a specific commit SHA
  --no-qa            Skip qa checks
  --skip-migrations  Skip data migrations (see scripts/run-migrations.sh)
  --no-reexec        Do not re-execute the newer update.sh shipped by the deployed ref
  -h, --help         Show help

Run it from the source checkout (paths.source in deploy.yml). The fetch runs
as root, so pass the deploy key of the user who cloned on the sudo line:

  cd ~/ethora-install-shared
  # GIT_SSH_COMMAND is optional: under sudo the invoking user's ~/.ssh key and
  # known_hosts are picked up automatically (see ensure_git_ssh_command).
  sudo GIT_SSH_COMMAND="ssh -i /home/ubuntu/.ssh/id_ed25519 -o IdentitiesOnly=yes" \\
      deploy/scripts/update.sh --ref 2609

Source and target directories come from deploy.yml (paths.source, paths.base)
and deploy/.deploy.env; they are not command-line options. Docs:
deploy/README.md, docs/OPERATOR_QUICKSTART.md.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)
      CLI_REF="${2:-}"
      shift 2
      ;;
    --rollback)
      CLI_ROLLBACK_SHA="${2:-}"
      shift 2
      ;;
    --no-qa)
      CLI_NO_QA="true"
      shift 1
      ;;
    --skip-migrations)
      CLI_SKIP_MIGRATIONS="true"
      shift 1
      ;;
    --no-reexec)
      NO_REEXEC="true"
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

warn() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1" >&2
}

ensure_runtime_tree_owned_by_deploy_user() {
  local deploy_user=""
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    deploy_user="$SUDO_USER"
  else
    return 0
  fi

  local targets=(
    "$ROOT_DIR/ethora-backend/services/api"
    "$ROOT_DIR/ethora-backend/services/ai/ai-service"
    "$ROOT_DIR/ethora-backend/services/ai/docs-parse"
    "$ROOT_DIR/ethora-backend/services/push"
    "$ROOT_DIR/ethora-app-reactjs"
    "$ROOT_DIR/ethora-chat-component"
    "$ROOT_DIR/ethora-sdk-playground"
    "$ROOT_DIR/ethora-ai-chat-widget"
    "$ROOT_DIR/ethora-mcp-server"
  )

  for target in "${targets[@]}"; do
    [ -e "$target" ] || continue
    chown -R "$deploy_user":"$deploy_user" "$target" 2>/dev/null || chown -R "$deploy_user" "$target" 2>/dev/null || true
    chmod -R u+rwX "$target" 2>/dev/null || true
  done
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] '$1' not found in PATH" >&2; exit 1; }
}

need_cmd git
need_cmd docker

mkdir -p "$STATE_DIR"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
fi

CURRENT_DEPLOY_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
if [ -n "${SOURCE_ROOT:-}" ] && [ "${SOURCE_ROOT:-}" != "null" ] && [ -d "$SOURCE_ROOT" ]; then
  SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"
else
  SOURCE_ROOT="$CURRENT_DEPLOY_ROOT"
fi
SOURCE_DEPLOY_DIR="${SOURCE_DEPLOY_DIR:-$SOURCE_ROOT/deploy}"
CANONICAL_DEPLOY_CONFIG_FILE="${CANONICAL_DEPLOY_CONFIG_FILE:-$SOURCE_DEPLOY_DIR/config/deploy.yml}"

if [ "$CURRENT_DEPLOY_ROOT" != "$SOURCE_ROOT" ] && [ -d "$SOURCE_DEPLOY_DIR" ]; then
  echo "[ERROR] This deploy directory is not the canonical source deploy dir: $DEPLOY_DIR" >&2
  echo "[ERROR] Edit deploy.yml and run update.sh from the canonical source checkout instead:" >&2
  echo "[ERROR]   $SOURCE_DEPLOY_DIR" >&2
  echo "[ERROR] Canonical config: $CANONICAL_DEPLOY_CONFIG_FILE" >&2
  exit 1
fi

# Path safety guard: block in-place installs and data-dir collisions BEFORE any
# git/service/data work. Exits non-zero (aborting the update) on a dangerous layout.
if [ -f "$DEPLOY_DIR/scripts/preflight-paths.sh" ]; then
  SRC_DIR="$SOURCE_ROOT" TARGET_DIR="${ROOT_DIR:-$SOURCE_ROOT}" \
    bash "$DEPLOY_DIR/scripts/preflight-paths.sh" || exit 1
fi

hash_file_sha256() {
  local file="$1"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo ""
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi
  echo ""
  return 0
}

# The checkout below replaces update.sh on disk with the deployed ref's copy,
# but bash keeps running the copy it already loaded. Steps that only exist in
# the newer script (a new SYNC_TARGETS entry, a new image rebuild rule) would
# then be skipped while the newer setup-*.sh helpers, invoked by path, do run:
# a half-old, half-new update. So we hash the running script before any
# checkout and, once the source ref is in place, hand over to the new copy.
RUNNING_UPDATE_SH="$SCRIPT_DIR/update.sh"
RUNNING_UPDATE_SH_SHA="$(hash_file_sha256 "$RUNNING_UPDATE_SH")"

maybe_reexec_updated_script() {
  local new_script="$1"
  if [ "$NO_REEXEC" = "true" ] || [ "${ETHORA_UPDATE_REEXECED:-}" = "1" ]; then
    return 0
  fi
  [ -f "$new_script" ] || return 0
  local new_sha
  new_sha="$(hash_file_sha256 "$new_script")"
  if [ -z "$new_sha" ] || [ -z "$RUNNING_UPDATE_SH_SHA" ] || [ "$new_sha" = "$RUNNING_UPDATE_SH_SHA" ]; then
    return 0
  fi
  log "update.sh changed in the deployed ref; re-executing the new version: $new_script"
  ETHORA_UPDATE_REEXECED=1 exec bash "$new_script" "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}" --no-reexec
}

# Content hash of the ejabberd custom module SOURCES (*.erl/*.hrl/*.spec).
# Deliberately not the whole tree: on hosts where the container can write to
# the bind-mounted sources dir, compiled .beam files land next to the sources
# and would churn the hash on every start.
hash_ejabberd_modules_sha256() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo ""
    return 0
  fi
  local hasher=""
  if command -v sha256sum >/dev/null 2>&1; then
    hasher="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    hasher="shasum -a 256"
  else
    echo ""
    return 0
  fi
  (
    cd "$dir" || exit 1
    find . -type f \( -name '*.erl' -o -name '*.hrl' -o -name '*.spec' \) | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"
      cat "$f"
    done
  ) | $hasher | awk '{print $1}'
  return 0
}

hash_tree_sha256() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo ""
    return 0
  fi

  if ! command -v tar >/dev/null 2>&1; then
    echo ""
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    (
      cd "$dir" || exit 1
      tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
        --exclude='./.git' \
        --exclude='./node_modules' \
        --exclude='./dist' \
        --exclude='./.ethora_deploy' \
        --exclude='./.next' \
        --exclude='./coverage' \
        --exclude='./tmp' \
        --exclude='./.turbo' \
        -cf - .
    ) | sha256sum | awk '{print $1}'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    (
      cd "$dir" || exit 1
      tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
        --exclude='./.git' \
        --exclude='./node_modules' \
        --exclude='./dist' \
        --exclude='./.ethora_deploy' \
        --exclude='./.next' \
        --exclude='./coverage' \
        --exclude='./tmp' \
        --exclude='./.turbo' \
        -cf - .
    ) | shasum -a 256 | awk '{print $1}'
    return 0
  fi

  echo ""
  return 0
}

# Ensure ffmpeg/ffprobe are installed. The backend's file upload paths
# shell out to both for video preview generation and audio/video duration.
# Without ffprobe, audio uploads 500. Idempotent and cheap when present.
# Self-heal for hosts installed before install.sh started installing ffmpeg.
ensure_ffmpeg() {
  if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "ffmpeg/ffprobe missing and apt-get unavailable; audio/video uploads will fail until installed manually"
    return 0
  fi
  log "ffmpeg/ffprobe not found; installing (one-time self-heal)..."
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ffmpeg >/dev/null 2>&1; then
    warn "Failed to install ffmpeg; audio/video uploads will fail until installed manually (apt install ffmpeg)"
  fi
}

# Keep the host on the Node major the platform targets. install.sh only picks
# the major on a *fresh* box, but update.sh is how long-lived hosts move
# forward -- without this, a host installed on Node 20 would stay on Node 20
# forever while the code moves on. Self-heal for hosts installed before the
# Node 24 bump. Override with ETHORA_NODE_MAJOR in .deploy.env to hold a host
# back (e.g. one that still needs an older major for an out-of-tree service).
ETHORA_NODE_MAJOR="${ETHORA_NODE_MAJOR:-24}"

ensure_node_major() {
  local want="$ETHORA_NODE_MAJOR"
  local have=""
  have="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo "")"

  if [ -z "$have" ]; then
    warn "node not found; run install.sh on this host (setup-node-services.sh will fail without it)"
    return 0
  fi
  if [ "$have" -ge "$want" ] 2>/dev/null; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "Node ${have} is below the target ${want} and apt-get is unavailable; upgrade Node manually"
    return 0
  fi

  log "Node ${have} detected, platform targets ${want}; upgrading via NodeSource (one-time self-heal)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg >/dev/null 2>&1 || true
  if ! curl -fsSL "https://deb.nodesource.com/setup_${want}.x" | bash - >/dev/null 2>&1; then
    warn "Failed to configure the NodeSource repo for Node ${want}; staying on Node ${have}"
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
  # apt upgrades the existing `nodejs` package in place: the old major is
  # replaced, not left installed alongside the new one.
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >/dev/null 2>&1; then
    warn "Failed to install Node ${want}; staying on Node ${have}"
    return 0
  fi
  log "Node upgraded to $(node --version)"

  # The PM2 daemon is a long-running process still holding the previous
  # interpreter. `pm2 update` kills and resurrects it (and the managed apps)
  # under the new one; it is a no-op when the daemon is already current.
  if command -v pm2 >/dev/null 2>&1; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
      # Bounded: seen hang indefinitely after the daemon exits (client keeps
      # waiting on the old socket). The PM2 start steps below spawn a fresh
      # daemon under the new runtime anyway.
      timeout 180 sudo -u "$SUDO_USER" -H bash -lc "pm2 update" >/dev/null 2>&1 \
        || warn "pm2 update failed or timed out; the PM2 start steps below bring the daemon up on $(node --version)"
    else
      timeout 180 bash -lc "pm2 update" >/dev/null 2>&1 \
        || warn "pm2 update failed or timed out; the PM2 start steps below bring the daemon up on $(node --version)"
    fi
  fi

  # A major bump can invalidate node_modules built against the previous ABI
  # (native addons, prebuild selection). setup-node-services.sh only reinstalls
  # when the lockfile changed, which a runtime bump alone does not trip.
  warn "Node major changed ${have} -> ${want}: if a service misbehaves after this update, wipe its node_modules and re-run update.sh"
}

# Ensure swap exists on small instances (prevents "stuck" builds due to memory pressure).
# Idempotent: if any swap is already enabled, does nothing.
ensure_swapfile() {
  if [ "${ETHORA_ENABLE_SWAP:-true}" != "true" ]; then
    log "Swap auto-setup disabled (ETHORA_ENABLE_SWAP=false)"
    return 0
  fi

  if ! command -v swapon >/dev/null 2>&1 || ! command -v mkswap >/dev/null 2>&1; then
    warn "swapon/mkswap not found; skipping swap auto-setup"
    return 0
  fi

  if swapon --show 2>/dev/null | awk 'NR>1 {print}' | grep -q .; then
    log "Swap is already enabled; skipping swap auto-setup"
    return 0
  fi

  local mem_kb mem_mb
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  mem_mb="$((mem_kb / 1024))"
  if [ "$mem_mb" -le 0 ]; then
    warn "Unable to determine MemTotal; skipping swap auto-setup"
    return 0
  fi

  local threshold_mb
  threshold_mb="${ETHORA_SWAP_THRESHOLD_MB:-8192}"
  if [ "$mem_mb" -gt "$threshold_mb" ]; then
    log "Host RAM ${mem_mb}MB > ${threshold_mb}MB; skipping swap auto-setup"
    return 0
  fi

  local desired_mb
  desired_mb="$mem_mb"
  if [ "$desired_mb" -lt 2048 ]; then desired_mb=2048; fi
  if [ "$desired_mb" -gt 4096 ]; then desired_mb=4096; fi

  local avail_mb
  avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d '\r' || echo 0)"
  if [ -z "$avail_mb" ]; then avail_mb=0; fi
  if [ "$avail_mb" -lt $((desired_mb + 1024)) ]; then
    warn "Not enough free disk to allocate ${desired_mb}MB swap on /. Available=${avail_mb}MB. Skipping swap auto-setup."
    return 0
  fi

  local swap_path="/swapfile"
  log "Enabling swap (${desired_mb}MB) at ${swap_path} (helps with TS builds on small instances)..."

  if [ ! -f "$swap_path" ]; then
    if command -v fallocate >/dev/null 2>&1; then
      fallocate -l "${desired_mb}M" "$swap_path" || return 0
    else
      dd if=/dev/zero of="$swap_path" bs=1M count="$desired_mb" status=progress 2>/dev/null || return 0
    fi
  fi

  chmod 600 "$swap_path" 2>/dev/null || true
  mkswap "$swap_path" >/dev/null 2>&1 || true
  swapon "$swap_path" >/dev/null 2>&1 || true

  if swapon --show 2>/dev/null | awk 'NR>1 {print}' | grep -q "^${swap_path}"; then
    if ! grep -qE "^${swap_path}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab 2>/dev/null; then
      echo "${swap_path} none swap sw 0 0" >> /etc/fstab || true
    fi
    log "Swap enabled successfully"
  else
    warn "Swap setup attempted but swap is still not active (continuing)"
  fi
}

is_active_submodule_checkout() {
  local repo_root="$1"
  local path="$2"
  local abs_path="$repo_root/$path"
  local super_root=""

  if [ ! -e "$abs_path" ]; then
    return 1
  fi

  if ! git -C "$abs_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi

  super_root="$(git -C "$abs_path" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
  [ "$super_root" = "$repo_root" ]
}

# Stateful data lives in bind-mount directories. The compose defaults nest
# them under submodule directory names (deploy/ethora-backend/infra/docker/data/...
# and deploy/ejabberd-docker/docker-data/...). Those paths look like leftover
# code checkouts to anyone unfamiliar with the layout - and we have lost a
# Mongo data dir once because of an `rm -rf` on what was assumed to be stale
# code but actually contained live database state.
#
# This warns at the start of every update.sh run when the data paths still
# default to confusable locations, so the operator is reminded and can plan
# a migration to a clearer path (e.g. $ROOT_DIR/data/) when convenient.
warn_if_data_paths_confusable() {
  local legacy_backend_data="${BACKEND_DATA_DIR:-$SOURCE_DEPLOY_DIR/ethora-backend/infra/docker/data}"
  local legacy_ejabberd="${EJABBERD_DIR:-$SOURCE_DEPLOY_DIR/ejabberd-docker}"

  local mongo_dir minio_dir mysql_dir redis_dir
  mongo_dir="${MONGO_DATA_DIR:-$legacy_backend_data/mongo}"
  minio_dir="${MINIO_DATA_DIR:-$legacy_backend_data/minio}"
  mysql_dir="${MYSQL_DATA_DIR:-$legacy_ejabberd/docker-data/my-sql}"
  redis_dir="${REDIS_DATA_DIR:-$legacy_backend_data/redis}"

  local nested=()
  for d in "$mongo_dir" "$minio_dir" "$mysql_dir" "$redis_dir"; do
    case "$d" in
      */ethora-backend/*|*/ejabberd-docker/*)
        nested+=("$d")
        ;;
    esac
  done

  [ "${#nested[@]}" -eq 0 ] && return 0

  warn "Stateful data paths are nested under submodule directory names:"
  for p in "${nested[@]}"; do
    warn "  $p"
  done
  warn "These look like leftover code checkouts but contain live DB / file state."
  warn "Any 'rm -rf' on parent paths like 'deploy/ethora-backend' or"
  warn "'deploy/ejabberd-docker' would wipe Mongo/MinIO/MySQL/Redis data."
  warn ""
  warn "To migrate to safer paths under \$ROOT_DIR/data/ (recommended):"
  warn "  sudo deploy/scripts/migrate-data-paths.sh --dry-run    # preview"
  warn "  sudo deploy/scripts/migrate-data-paths.sh              # do it"
}

# Maintenance inside ejabberd's persistent $HOME volume (/opt/ejabberd;
# /home/ejabberd is a symlink to it). The volume is anonymous, so it is found
# from the existing xmpp container's mounts and mounted explicitly by name
# into a throwaway helper container. `--volumes-from` is deliberately NOT used:
# it replays every bind of the source container too, and one bad bind (a
# file bound where a directory now sits, or vice versa) makes the helper fail
# the same way the real container does - which is exactly the state we are
# trying to repair.
#
#   ejabberd_volume_maintenance purge   also delete compiled custom-module
#                                       beams (rebuilt from sources on start)
#   ejabberd_volume_maintenance keep    only the repairs below
#
# Repairs done on every call:
#   - conf/jwt.key as a DIRECTORY. compose binds docker/jwt.key (a file) to
#     /opt/ejabberd/conf/jwt.key; if the container was ever brought up before
#     setup-ejabberd-config.sh rendered that file, docker created the mount
#     point as an empty directory in the volume, and every later start fails
#     with "not a directory". Removing the (empty) directory lets the file
#     bind again.
ejabberd_volume_maintenance() {
  local mode="${1:-keep}"
  local compose_file="$RUNTIME_DEPLOY_DIR/docker-compose.enterprise.yml"
  local cid vol img
  cid="$(compose -f "$compose_file" ps -a -q xmpp 2>/dev/null | head -1)"
  [ -n "$cid" ] || return 0
  vol="$(docker inspect -f '{{range .Mounts}}{{if and (eq .Type "volume") (eq .Destination "/opt/ejabberd")}}{{.Name}}{{end}}{{end}}' "$cid" 2>/dev/null || echo '')"
  if [ -z "$vol" ]; then
    warn "ejabberd: no /opt/ejabberd volume on container ${cid:0:12}; skipping volume maintenance"
    return 0
  fi
  img="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || echo '')"
  [ -n "$img" ] || img="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || echo '')"
  [ -n "$img" ] || return 0
  if [ "$mode" = "purge" ]; then
    log "Purging compiled ejabberd custom modules in volume $vol (rebuilt from sources on next start)..."
  fi
  local out
  if ! out="$(docker run --rm -v "$vol:/v" --entrypoint sh "$img" -c '
      if [ -d /v/conf/jwt.key ]; then
        rmdir /v/conf/jwt.key 2>/dev/null && echo "removed stray conf/jwt.key directory" || echo "conf/jwt.key is a non-empty directory; leaving it"
      fi
      if [ "$1" = purge ] && [ -d /v/.ejabberd-modules/compiled ]; then
        n=$(find /v/.ejabberd-modules/compiled -name "*.beam" | wc -l)
        rm -rf /v/.ejabberd-modules/compiled/*
        echo "purged $n compiled beam(s)"
      fi
      exit 0' sh "$mode" 2>&1)"; then
    warn "ejabberd volume maintenance failed (mode=$mode): ${out:-no output}"
    [ "$mode" = "purge" ] && warn "A stale module may keep rejecting new options; see docs on setting the beams aside by hand"
    return 0
  fi
  [ -n "$out" ] && log "ejabberd volume: $out"
  return 0
}

# Catch the case where `docker compose up` is about to recreate a stateful
# container with a different bind-mount source than the one it's running
# with NOW - which would silently abandon its data and reinit from empty.
#
# Walks each stateful service, compares its currently-running mount source
# against what the resolved env vars would point to, and aborts if they
# disagree AND the running source has data while the new target doesn't.
#
# Why this exists: a customer's MUC database (1.1 GB of muc_room state)
# was lost when an update.sh run shifted MySQL's bind mount to a different
# path that happened to be empty. The compose fallback + re-source fixes
# eliminate the root cause; this is a guard so we never let it happen
# again, even if some future env change re-introduces a divergence.
abort_if_stateful_mounts_will_drift() {
  local compose_file="$1"
  local violations=()

  check_one() {
    local container="$1"
    local container_path="$2"
    local desired_host="$3"

    if [ -z "$desired_host" ]; then return 0; fi

    # Resolve desired_host to absolute (compose treats `./` as compose-file dir).
    if [ "${desired_host:0:1}" != "/" ]; then
      desired_host="$(cd "$(dirname "$compose_file")" 2>/dev/null && cd "$desired_host" 2>/dev/null && pwd)"
      [ -z "$desired_host" ] && return 0
    fi

    if ! docker inspect "$container" >/dev/null 2>&1; then return 0; fi

    local running_host
    running_host="$(docker inspect "$container" --format "{{range .Mounts}}{{if eq .Destination \"$container_path\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null)"
    [ -z "$running_host" ] && return 0
    [ "$running_host" = "$desired_host" ] && return 0

    local running_has_data="false"
    [ -d "$running_host" ] && [ -n "$(ls -A "$running_host" 2>/dev/null | head -1)" ] && running_has_data="true"

    local desired_has_data="false"
    [ -d "$desired_host" ] && [ -n "$(ls -A "$desired_host" 2>/dev/null | head -1)" ] && desired_has_data="true"

    if [ "$running_has_data" = "true" ] && [ "$desired_has_data" = "false" ]; then
      violations+=("$container: running=$running_host  desired=$desired_host (running has data, desired is empty)")
    fi
  }

  check_one deploy-mongo-1        /data/db        "${MONGO_DATA_DIR:-${BACKEND_DATA_DIR:-./ethora-backend/infra/docker/data}/mongo}"
  check_one deploy-minio-1        /data           "${MINIO_DATA_DIR:-${BACKEND_DATA_DIR:-./ethora-backend/infra/docker/data}/minio}"
  check_one deploy-redis-server-1 /data           "${REDIS_DATA_DIR:-${BACKEND_DATA_DIR:-./ethora-backend/infra/docker/data}/redis}"
  check_one deploy-mysql-1        /var/lib/mysql  "${MYSQL_DATA_DIR:-${EJABBERD_DIR:-./ejabberd-docker}/docker-data/my-sql}"

  if [ "${#violations[@]}" -gt 0 ]; then
    echo "" >&2
    echo "[ERROR] Aborting: a 'docker compose up' would recreate a stateful container" >&2
    echo "[ERROR] with a new bind-mount source that doesn't have data, while the running" >&2
    echo "[ERROR] container's current source DOES. This would reinitialize the service" >&2
    echo "[ERROR] from empty and lose live data." >&2
    for v in "${violations[@]}"; do
      echo "[ERROR]   $v" >&2
    done
    echo "" >&2
    echo "[ERROR] To resolve, either:" >&2
    echo "[ERROR]   (a) Move the data from the running path to the desired path, OR" >&2
    echo "[ERROR]   (b) Set the explicit per-service var (e.g. MYSQL_DATA_DIR) in" >&2
    echo "[ERROR]       deploy/.deploy.env to match where the data currently lives." >&2
    exit 1
  fi
}

# The source repo (typically /home/<user>/ethora-install-shared) is a
# read-only mirror tree - the sync-install-shared-* workflows overwrite it
# on every push to dappros/ethora-monoserver. Local edits there can come
# from an emergency live-patch or operator mistake; either way they get
# clobbered by the next sync, so stashing them here is safe and unblocks
# the checkout step below. Stash carries a timestamped label so an operator
# can still recover the edits via `git stash list` / `git stash show -p`.
# `sudo update.sh` runs git as root: root usually has neither the deploy key
# nor a known_hosts entry for GitHub, so the source fetch dies with
# "Host key verification failed" or "Permission denied (publickey)" unless
# the operator remembers to pass GIT_SSH_COMMAND. Derive a sane default from
# the invoking user's ~/.ssh instead, and only add what the operator did not
# set explicitly.
ensure_git_ssh_command() {
  local cmd="${GIT_SSH_COMMAND:-ssh}"
  local home=""
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  fi
  if [ -n "$home" ] && [ -f "$home/.ssh/known_hosts" ] && [[ "$cmd" != *UserKnownHostsFile* ]]; then
    cmd="$cmd -o UserKnownHostsFile=$home/.ssh/known_hosts"
  fi
  if [[ "$cmd" != *StrictHostKeyChecking* ]]; then
    cmd="$cmd -o StrictHostKeyChecking=accept-new"
  fi
  if [ -n "$home" ] && [[ "$cmd" != *" -i "* ]] && [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
    local key
    for key in "$home/.ssh/id_ed25519" "$home/.ssh/id_rsa"; do
      if [ -f "$key" ]; then
        cmd="$cmd -i $key -o IdentitiesOnly=yes"
        break
      fi
    done
  fi
  if [ "$cmd" != "${GIT_SSH_COMMAND:-ssh}" ]; then
    log "Git over SSH as $(id -un): using '$cmd'"
  fi
  export GIT_SSH_COMMAND="$cmd"
}

stash_local_mods_if_any() {
  local repo="$1"
  local label_prefix="${2:-ethora-update.sh}"

  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  if git -C "$repo" diff --quiet HEAD -- 2>/dev/null; then
    return 0
  fi

  local stash_label="$label_prefix auto-stash $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "Source repo has local modifications, stashing before checkout:"
  git -C "$repo" status --short 2>/dev/null | head -20 | sed 's/^/    /' >&2
  # IMPORTANT: do NOT pass --include-untracked. Stray multi-GB untracked
  # directories (e.g. an old docker volume mounted under deploy/ from a
  # misconfigured install) can hang `git update-index` for minutes while
  # it packs hundreds of thousands of files. Untracked files don't block
  # `git checkout` anyway - only modified-but-tracked files do.
  if git -C "$repo" stash push --message "$stash_label" >/dev/null 2>&1; then
    log "Stashed as: '$stash_label'"
    log "Recover with: git -C $repo stash list  (then 'git stash show -p stash@{0}')"
  else
    warn "git stash failed; resetting working tree to HEAD to unblock checkout"
    git -C "$repo" reset --hard HEAD >/dev/null 2>&1 || true
  fi
}

prepare_legacy_submodule_paths() {
  local repo_root="$1"
  local gitmodules_file="$repo_root/.gitmodules"
  local backup_root=""
  local moved_any="false"

  if [ ! -f "$gitmodules_file" ]; then
    return 0
  fi

  while read -r _key path; do
    local abs_path="$repo_root/$path"

    [ -n "${path:-}" ] || continue
    [ -e "$abs_path" ] || continue

    if is_active_submodule_checkout "$repo_root" "$path"; then
      continue
    fi

    if [ -d "$abs_path" ]; then
      if [ -z "$(ls -A "$abs_path" 2>/dev/null)" ]; then
        continue
      fi
    fi

    if [ -z "$backup_root" ]; then
      backup_root="$repo_root/.submodule-migration-backups/$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$backup_root"
    fi

    mkdir -p "$(dirname "$backup_root/$path")"
    warn "Detected legacy non-empty path at '$path' for a submodule. Moving it to '$backup_root/$path' before submodule init."
    mv "$abs_path" "$backup_root/$path"
    moved_any="true"
  done < <(git -C "$repo_root" config -f "$gitmodules_file" --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)

  if [ "$moved_any" = "true" ]; then
    warn "Legacy submodule paths were backed up under: $backup_root"
  fi
}

# Apply CLI overrides last (highest priority).
if [ -n "${CLI_REF:-}" ]; then
  REF="$CLI_REF"
fi
if [ -n "${CLI_ROLLBACK_SHA:-}" ]; then
  ROLLBACK_SHA="$CLI_ROLLBACK_SHA"
fi
if [ -n "${CLI_NO_QA:-}" ]; then
  NO_QA="$CLI_NO_QA"
fi
if [ -n "${CLI_SKIP_MIGRATIONS:-}" ]; then
  SKIP_MIGRATIONS="$CLI_SKIP_MIGRATIONS"
fi

# Ensure EJABBERD_CONFIG_NAME is set (older installs may not have it in .deploy.env).
# - localhost: use `ejabberd-local.yml` (does not enable unused custom modules like mod_get_user_rooms)
# - non-localhost: use `ejabberd-prod.yml`
if [ -z "${EJABBERD_CONFIG_NAME:-}" ] || [ "${EJABBERD_CONFIG_NAME:-}" == "null" ]; then
  if [ "${API_DOMAIN:-}" == "localhost" ]; then
    export EJABBERD_CONFIG_NAME="ejabberd-local.yml"
  else
    export EJABBERD_CONFIG_NAME="ejabberd-prod.yml"
  fi
fi

# Prefer Docker Compose v2 plugin (`docker compose`). Fallback to legacy `docker-compose` if needed.
# NOTE: `docker-compose` v1 can fail on modern Docker images with KeyError: 'ContainerConfig'.
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
    return $?
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
    return $?
  fi
  echo "[ERROR] Neither 'docker compose' nor 'docker-compose' is available" >&2
  exit 1
}

ensure_swapfile
ensure_ffmpeg
ensure_node_major
warn_if_data_paths_confusable

log "Canonical deploy config: ${CANONICAL_DEPLOY_CONFIG_FILE}"
if [ "$ROOT_DIR" != "$SOURCE_ROOT" ]; then
  log "Deploy scripts/config live only at: $SOURCE_DEPLOY_DIR"
fi

if command -v yq >/dev/null 2>&1 && [ -f "$CANONICAL_DEPLOY_CONFIG_FILE" ]; then
  WIDGET_ENABLED="$(yq eval '.services.widget.enabled // "false"' "$CANONICAL_DEPLOY_CONFIG_FILE" 2>/dev/null || echo "${WIDGET_ENABLED:-false}")"
fi

# Re-read integrations, feature flags and frontend config from deploy.yml on every update.
# .deploy.env is a snapshot from install time and may be stale when the user edits deploy.yml.
reload_config_from_deploy_yml() {
  local cfg="$1"
  command -v yq >/dev/null 2>&1 || return 0
  [ -f "$cfg" ] || return 0

  # Domains an operator may add AFTER install (absent from the .deploy.env
  # snapshot). secure_files gates the attachments vhost; re-read it here so
  # update.sh provisions the env/cert/vhost without a fresh install.
  export SECURE_FILES_DOMAIN=$(yq eval '.domains.secure_files // ""' "$cfg")

  # Frontend service flags
  export DISABLE_FIREBASE=$(yq eval '.frontend.disable_firebase // "false"' "$cfg")
  export DISABLE_GA=$(yq eval '.frontend.disable_ga // "false"' "$cfg")
  export DISABLE_CLARITY=$(yq eval '.frontend.disable_clarity // "false"' "$cfg")

  # Frontend tracking ids
  export GA_ID=$(yq eval '.frontend.ga_id // ""' "$cfg")
  export GTM_ID=$(yq eval '.frontend.gtm_id // ""' "$cfg")
  export CLARITY_ID=$(yq eval '.frontend.clarity_id // ""' "$cfg")

  # HubSpot
  export HUBSPOT_ENABLED=$(yq eval '.integrations.hubspot.enabled // "false"' "$cfg")
  export HUBSPOT_PORTAL_ID=$(yq eval '.integrations.hubspot.portal_id // ""' "$cfg")
  export HUBSPOT_FORM_ID_APP_CREATE=$(yq eval '.integrations.hubspot.form_id_app_create // ""' "$cfg")
  export HUBSPOT_FORM_ID_SIGNUP=$(yq eval '.integrations.hubspot.form_id_signup // ""' "$cfg")
  export HUBSPOT_FORM_ID_TUTORIAL=$(yq eval '.integrations.hubspot.form_id_tutorial // ""' "$cfg")
  export HUBSPOT_REGION=$(yq eval '.integrations.hubspot.region // "na1"' "$cfg")

  # AI providers
  export AI_API_URL=$(yq eval '.ai.ai_api_url // "https://api.openai.com/v1"' "$cfg")
  export AI_API_KEY=$(yq eval '.ai.ai_api_key // ""' "$cfg")
  export AI_CHAT_MODEL=$(yq eval '.ai.chat_model // "gpt-4.1-mini"' "$cfg")
  export AI_EMBEDDING_MODEL=$(yq eval '.ai.embedding_model // "text-embedding-3-small"' "$cfg")
  if [ -z "$AI_API_KEY" ] || [ "$AI_API_KEY" == "null" ]; then
    export AI_API_KEY=$(yq eval '.ai.openai_api_key // ""' "$cfg")
  fi
  export AI_POSTGRES_PORT=$(yq eval '.services.ai_service.postgres_port // 5434' "$cfg")
  export AI_POSTGRES_DB=$(yq eval '.services.ai_service.postgres_database // "ai_service_embeddings_db"' "$cfg")
  export AI_POSTGRES_USER=$(yq eval '.services.ai_service.postgres_user // "ai_embeddings"' "$cfg")
  export AI_POSTGRES_PASSWORD=$(yq eval '.services.ai_service.postgres_password // ""' "$cfg")
  export AI_PG_URL=$(yq eval '.services.ai_service.pg_url // ""' "$cfg")
  [ -z "$AI_PG_URL" ] || [ "$AI_PG_URL" == "null" ] && export AI_PG_URL=""

  # Email TLD validation policy. Re-read on every update so an operator
  # tweaking services.backend.email_tld_validation in deploy.yml takes effect
  # without a fresh install.
  export EMAIL_TLD_VALIDATION=$(yq eval '.services.backend.email_tld_validation // "off"' "$cfg")
  export EMAIL_TLD_ALLOWLIST=$(yq eval '.services.backend.email_tld_allowlist // ""' "$cfg")

  # AI feature flags must be re-read here too, otherwise update.sh's own
  # conditionals (compose profiles, setup-ai-postgres) will keep using the
  # values that were sourced from .deploy.env at the top of the script even
  # after the operator flips them off in deploy.yml. setup-env.sh enforces
  # the umbrella (features.ai_service) over individual sub-flags.
  export AI_FEATURE_ENABLED=$(yq eval '.features.ai_service // "false"' "$cfg")
  export AI_SERVICE_ENABLED=$(yq eval '.services.ai_service.enabled // "false"' "$cfg")
  export DOCS_PARSE_ENABLED=$(yq eval '.services.docs_parse_service.enabled // "false"' "$cfg")
  export CRAWLER_ENABLED=$(yq eval '.services.crawler.enabled // "false"' "$cfg")
  if [ "${AI_FEATURE_ENABLED:-false}" != "true" ]; then
    export AI_SERVICE_ENABLED="false"
    export DOCS_PARSE_ENABLED="false"
    export CRAWLER_ENABLED="false"
  fi
  export WIDGET_ENABLED=$(yq eval '.services.widget.enabled // "false"' "$cfg")

  # Stripe / Postmark
  export STRIPE_ENABLED=$(yq eval '.features.stripe // "false"' "$cfg")
  export POSTMARK_ENABLED=$(yq eval '.features.postmark // "false"' "$cfg")
  export STRIPE_SECRET=$(yq eval '.integrations.stripe.secret // ""' "$cfg")
  export STRIPE_PUBLIC=$(yq eval '.integrations.stripe.public // ""' "$cfg")
  export STRIPE_PLAN=$(yq eval '.integrations.stripe.plan // ""' "$cfg")
  export POSTMARK_TOKEN=$(yq eval '.integrations.postmark.token // ""' "$cfg")
  export POSTMARK_FROM_EMAIL=$(yq eval '.integrations.postmark.from_email // "noreply@ethoramail.com"' "$cfg")
  export POSTMARK_FROM_NAME=$(yq eval '.integrations.postmark.from_name // "Ethora Platform"' "$cfg")
  export POSTMARK_SUBJECT_PREFIX=$(yq eval '.integrations.postmark.subject_prefix // "Ethora"' "$cfg")

  # Analytics email reports
  export ANALYTICS_ENABLED=$(yq eval '.features.analytics // "false"' "$cfg")
  export DAILY_REPORT_RECEIVERS=$(yq eval '.integrations.analytics.daily_report_receivers // ""' "$cfg")
  export MONTHLY_REPORT_RECEIVERS=$(yq eval '.integrations.analytics.monthly_report_receivers // ""' "$cfg")
  export REPORT_DAILY_SCHEDULE=$(yq eval '.integrations.analytics.daily_schedule // "30 8 * * *"' "$cfg")
  export REPORT_WEEKLY_SCHEDULE=$(yq eval '.integrations.analytics.weekly_schedule // "30 8 * * 1"' "$cfg")
  export REPORT_MONTHLY_SCHEDULE=$(yq eval '.integrations.analytics.monthly_schedule // "30 8 1 * *"' "$cfg")
  export REPORT_TIMEZONE=$(yq eval '.integrations.analytics.timezone // ""' "$cfg")
  export LEGAL_CONTACT_EMAIL=$(yq eval '.integrations.analytics.legal_email // ""' "$cfg")
  export ALERT_RECIPIENTS=$(yq eval '.integrations.analytics.alert_email // ""' "$cfg")

  # In-app purchases / Firebase / Blockchain
  export IAP_ENABLED=$(yq eval '.features.iap // "false"' "$cfg")
  export FIREBASE_ENABLED=$(yq eval '.features.firebase // "false"' "$cfg")
  export FIREBASE_PROJECT_NAME=$(yq eval '.integrations.firebase.project_name // ""' "$cfg")
  export FIREBASE_SERVICE_ACCOUNT_PATH=$(yq eval '.integrations.firebase.service_account_path // ""' "$cfg")
  export FIREBASE_WEB_API_KEY=$(yq eval '.integrations.firebase.web.api_key // ""' "$cfg")
  export FIREBASE_WEB_AUTH_DOMAIN=$(yq eval '.integrations.firebase.web.auth_domain // ""' "$cfg")
  export FIREBASE_WEB_PROJECT_ID=$(yq eval '.integrations.firebase.web.project_id // ""' "$cfg")
  export FIREBASE_WEB_STORAGE_BUCKET=$(yq eval '.integrations.firebase.web.storage_bucket // ""' "$cfg")
  export FIREBASE_WEB_MESSAGING_SENDER_ID=$(yq eval '.integrations.firebase.web.messaging_sender_id // ""' "$cfg")
  export FIREBASE_WEB_APP_ID=$(yq eval '.integrations.firebase.web.app_id // ""' "$cfg")
  export FIREBASE_WEB_MEASUREMENT_ID=$(yq eval '.integrations.firebase.web.measurement_id // ""' "$cfg")
  export BLOCKCHAIN_ENABLED=$(yq eval '.features.blockchain // "false"' "$cfg")
  export COINBASE_PRIVATE=$(yq eval '.blockchain.coinbase_private // ""' "$cfg")
  export EXTERNAL_BC_NETWORKNAME=$(yq eval '.blockchain.external_bc_networkname // ""' "$cfg")
  export EXTERNAL_BC_WS=$(yq eval '.blockchain.external_bc_ws // ""' "$cfg")
  export ALCHEMY=$(yq eval '.blockchain.alchemy_url // ""' "$cfg")
  export USDC_CONTRACT_ADDRESS=$(yq eval '.blockchain.usdc_contract_address // ""' "$cfg")

  log "Re-loaded integrations/features config from deploy.yml"
}

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Git-based update when ROOT_DIR is itself a git checkout (developer/staging style)
  prev_sha="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo '')"
  # On a self re-exec HEAD is already the new ref; keep the pre-update SHA
  # the first pass recorded so --rollback hints stay correct.
  if [ -n "$prev_sha" ] && [ "${ETHORA_UPDATE_REEXECED:-}" != "1" ]; then
    echo "$prev_sha" > "$LAST_SHA_FILE"
  fi

  log "Starting update in $ROOT_DIR"
  log "Current SHA: ${prev_sha:-unknown}"

  log "Fetching origin..."
  ensure_git_ssh_command
  git -C "$ROOT_DIR" fetch --all --prune

  target="$REF"
  if [ -n "$ROLLBACK_SHA" ]; then
    target="$ROLLBACK_SHA"
    log "Rollback requested: $target"
  else
    log "Deploying ref: $target"
  fi

  log "Checking out: $target"
  stash_local_mods_if_any "$ROOT_DIR" "ethora-update.sh ($target)"
  # If `target` matches a remote branch (origin/<target>), create or reset a
  # local branch to it. This is necessary when:
  #   (a) the local repo doesn't have a tracking branch yet for `target`
  #       (e.g. first-ever deploy of a brand-new release branch like 2605); OR
  #   (b) the branch name happens to be valid hex (e.g. `2605`), in which
  #       case `git checkout -f 2605` ambiguates as a partial-SHA lookup
  #       and fails with "reference is not a tree".
  # Falls back to plain checkout for SHAs / tags / refs without a matching
  # origin/ ref.
  if [ -z "$ROLLBACK_SHA" ] && git -C "$ROOT_DIR" show-ref --verify --quiet "refs/remotes/origin/$target"; then
    git -C "$ROOT_DIR" checkout -B "$target" "origin/$target"
  else
    git -C "$ROOT_DIR" checkout -f "$target"
  fi

  log "Updating submodules..."
  prepare_legacy_submodule_paths "$ROOT_DIR"
  git -C "$ROOT_DIR" submodule sync --recursive
  git -C "$ROOT_DIR" submodule update --init --recursive

  new_sha="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo '')"
  log "Now at SHA: ${new_sha:-unknown}"
  maybe_reexec_updated_script "$ROOT_DIR/deploy/scripts/update.sh"
else
  # Rsync-based update for "installed" environments where ROOT_DIR (e.g. /home/<user>/deptest)
  # is a copy created by install.sh and does not contain .git.
  #
  # In this mode, we update by syncing from the monoserver working copy into the target ROOT_DIR.
  need_cmd rsync

  SRC_ROOT="$SOURCE_ROOT"

  log "Starting rsync-based update into $ROOT_DIR (no .git detected)"
  log "Source repo: $SRC_ROOT"

  # In rsync mode we still want to pull the requested ref from GitHub.
  # Update the source repo (and its submodules) first, then sync it into the target install.
  if git -C "$SRC_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    prev_src_sha="$(git -C "$SRC_ROOT" rev-parse HEAD 2>/dev/null || echo '')"
    if [ -n "$prev_src_sha" ]; then
      log "Source SHA before fetch: ${prev_src_sha}"
    fi

    log "Fetching origin in source repo..."
    ensure_git_ssh_command
    git -C "$SRC_ROOT" fetch --all --prune

    target="$REF"
    if [ -n "$ROLLBACK_SHA" ]; then
      target="$ROLLBACK_SHA"
      log "Rollback requested: $target"
    else
      log "Deploying ref: $target"
    fi

    log "Checking out source ref: $target"
    stash_local_mods_if_any "$SRC_ROOT" "ethora-update.sh ($target)"
    # See same-named block above (ROOT_DIR path) for the rationale - this
    # branch handles the rsync-from-source case where the source repo is
    # /home/<user>/ethora-install-shared. Same problem: a brand-new release
    # branch like `2605` has no local tracking branch on first deploy, AND
    # `2605` is valid hex so plain `git checkout -f 2605` ambiguates as a
    # partial-SHA lookup. Use `checkout -B <ref> origin/<ref>` when a
    # matching remote branch exists; that creates-or-resets the local
    # tracking branch in one step (and as a bonus replaces the previous
    # post-checkout `reset --hard` "fast-forward to origin" guard).
    if [ -z "$ROLLBACK_SHA" ] && git -C "$SRC_ROOT" show-ref --verify --quiet "refs/remotes/origin/$target"; then
      git -C "$SRC_ROOT" checkout -B "$target" "origin/$target"
    else
      git -C "$SRC_ROOT" checkout -f "$target"
    fi

    log "Updating source submodules..."
    prepare_legacy_submodule_paths "$SRC_ROOT"
    git -C "$SRC_ROOT" submodule sync --recursive
    git -C "$SRC_ROOT" submodule update --init --recursive

    new_src_sha="$(git -C "$SRC_ROOT" rev-parse HEAD 2>/dev/null || echo '')"
    if [ -n "$new_src_sha" ]; then
      log "Source SHA now: ${new_src_sha}"
    fi
    maybe_reexec_updated_script "$SRC_ROOT/deploy/scripts/update.sh"
  else
    warn "Source repo is not a git checkout ($SRC_ROOT/.git missing). Rsync update will not pull new code."
  fi

  # Guardrail: if the script is executed from inside the target install itself, SRC_ROOT will equal ROOT_DIR,
  # resulting in a no-op "sync target -> target" (confusing, because users expect it to pull newer code).
  if [ "$SRC_ROOT" = "$ROOT_DIR" ]; then
    echo "[ERROR] Rsync update is running from the target install directory ($ROOT_DIR)." >&2
    echo "[ERROR] This will sync $ROOT_DIR -> $ROOT_DIR and will NOT bring new code." >&2
    echo "[ERROR] Run update.sh from a git checkout of the monoserver repo (any folder name is fine) and set ROOT_DIR to the target install via deploy/.deploy.env." >&2
    exit 1
  fi

  # Run modes decide which component sources the checkout must carry. A
  # service that runs from an image needs none (that is what a Docker Hub
  # install is: ethora-install plus images); the sync loop below already
  # skips directories that are absent.
  _mode() { local v; v="$(yq eval "$1 // \"\"" "$CANONICAL_DEPLOY_CONFIG_FILE" 2>/dev/null || true)"; [ -z "$v" ] || [ "$v" = "null" ] && v="$2"; printf '%s' "${v:-source}"; }
  if command -v yq >/dev/null 2>&1 && [ -f "$CANONICAL_DEPLOY_CONFIG_FILE" ]; then
    UPD_BACKEND_MODE="$(_mode '.services.backend.mode' "${BACKEND_MODE:-source}")"
    UPD_FRONTEND_MODE="$(_mode '.services.frontend.mode' "${FRONTEND_MODE:-source}")"
  else
    UPD_BACKEND_MODE="${BACKEND_MODE:-source}"; UPD_FRONTEND_MODE="${FRONTEND_MODE:-source}"
  fi

  if { [ "$UPD_BACKEND_MODE" != "image" ] && [ ! -d "$SRC_ROOT/ethora-backend" ]; } || { [ "$UPD_FRONTEND_MODE" != "image" ] && [ ! -d "$SRC_ROOT/ethora-app-reactjs" ]; }; then
    echo "[ERROR] Source repo does not look like an Ethora monoserver checkout: $SRC_ROOT" >&2
    echo "[ERROR] Expected to find: $SRC_ROOT/ethora-backend and $SRC_ROOT/ethora-app-reactjs (or services.<x>.mode: image in deploy.yml)" >&2
    exit 1
  fi

  # Checking the manifest rather than the directory: an uninitialized submodule
  # leaves an empty directory that would otherwise pass this preflight and be
  # synced forward, failing much later inside npm with an ENOENT.
  if [ "$UPD_FRONTEND_MODE" != "image" ] && [ ! -f "$SRC_ROOT/ethora-chat-component/package.json" ]; then
    if [ -d "$SRC_ROOT/ethora-chat-component" ]; then
      echo "[ERROR] Source chat component at $SRC_ROOT/ethora-chat-component is an empty directory (submodule not initialized)." >&2
      echo "[ERROR] Run: git -C \"$SRC_ROOT\" submodule update --init ethora-chat-component" >&2
      exit 1
    fi
    echo "[ERROR] Source chat component directory is missing: $SRC_ROOT/ethora-chat-component" >&2
    exit 1
  fi

  if [ "${WIDGET_ENABLED:-false}" = "true" ] && [ ! -f "$SRC_ROOT/ethora-ai-chat-widget/package.json" ]; then
    if [ -d "$SRC_ROOT/ethora-ai-chat-widget" ]; then
      echo "[ERROR] Widget hosting is enabled, but $SRC_ROOT/ethora-ai-chat-widget is an empty directory (submodule not initialized)." >&2
      echo "[ERROR] Run: git -C \"$SRC_ROOT\" submodule update --init ethora-ai-chat-widget" >&2
      exit 1
    fi
    echo "[ERROR] Widget hosting is enabled, but source widget directory is missing: $SRC_ROOT/ethora-ai-chat-widget" >&2
    exit 1
  fi

  # Sync backend/frontend/ejabberd (and deploy scripts/templates) into the target.
  # Avoid copying docker data/volumes.
  mkdir -p "$ROOT_DIR"

  # Mirror each submodule source tree into the live tree. Optionally PRUNE
  # files the deployed branch no longer ships: a leftover source file from a
  # previous branch breaks `tsc --build`, which compiles every file in a
  # project regardless of imports (e.g. calls code left behind without its
  # deps). Pruning (rsync --delete) is gated for safety:
  #   - deploy.yml is never synced here (it lives in the canonical deploy dir);
  #     it is also excluded defensively below.
  #   - Databases / docker volumes (docker/data, docker-data, infra/docker/data),
  #     generated env (.env, .env.*), user uploads, node_modules and build
  #     output are excluded, so they are never read or deleted.
  #   - The operator is shown exactly what would be deleted, then it is gated on:
  #       ETHORA_UPDATE_PRUNE=true  -> prune without prompting (CI / cutover)
  #       ETHORA_UPDATE_PRUNE=false -> never prune (may leave build-breaking orphans)
  #       interactive TTY           -> y/N prompt (default N)
  #       non-interactive + unset   -> do NOT prune; print the orphan list + how to
  # Default to mtime/size checks because `--checksum` is expensive on large trees.
  # Operators can opt into checksum mode with ETHORA_UPDATE_RSYNC_CHECKSUM=true.
  RSYNC_COMMON=(--archive --human-readable --verbose --no-perms --no-owner --no-group)
  if [ "${ETHORA_UPDATE_RSYNC_CHECKSUM:-false}" = "true" ]; then
    RSYNC_COMMON+=(--checksum)
    log "Rsync checksum mode enabled (ETHORA_UPDATE_RSYNC_CHECKSUM=true)"
  fi
  RSYNC_EXCLUDES=(
    --exclude ".git"
    --exclude "node_modules"
    --exclude "dist"
    --exclude "bin"
    --exclude ".next"
    --exclude "coverage"
    --exclude ".turbo"
    --exclude "tmp"
    --exclude ".ethora_deploy"
    # Operator config: never sync or delete from these trees (defensive;
    # deploy.yml actually lives in the canonical deploy dir, not here).
    --exclude "deploy.yml"
    --exclude "config/deploy.yml"
    # Generated env files are rendered onto the target by setup-env.sh and
    # never exist in the source mirror; protect them from --delete. (".env.*"
    # covers .env.local / .env.production.local etc., but not .env-example,
    # which is committed and should sync.)
    --exclude ".env"
    --exclude ".env.*"
    # ejabberd's JWT key is rendered per install by setup-ejabberd-config.sh
    # and bind-mounted into the running container; the source never ships it,
    # so without this the prune preview offered it for deletion.
    --exclude "jwt.key"
    # Runtime user uploads are target-only state - must survive --delete.
    --exclude "uploads"
    # Databases / docker volume data: never read or delete these. They are
    # large, root-owned (unreadable -> rsync would abort all deletions), and
    # hold live state. Cover every layout seen in the field.
    --exclude "docker/data/**"
    --exclude "docker/data"
    --exclude "infra/docker/data/**"
    --exclude "infra/docker/data"
    --exclude "docker-data/**"
    --exclude "docker-data"
  )

  # Sync targets: "label|relative-path|comma-separated extra excludes"
  SYNC_TARGETS=(
    "backend|ethora-backend|"
    "frontend|ethora-app-reactjs|"
    "chat component|ethora-chat-component|"
    "widget|ethora-ai-chat-widget|.env.production.local"
    "SDK playground|ethora-sdk-playground|.env.local"
    "MCP server|ethora-mcp-server|.env"
    "uptime service|ethora-uptime|"
    "ejabberd|ejabberd-docker|docker/sitecert.pem"
  )

  # Pass 1: preview what pruning (--delete) would remove across all targets.
  PRUNE_LIST="$(mktemp)"
  for spec in "${SYNC_TARGETS[@]}"; do
    IFS='|' read -r _label rel extra <<<"$spec"
    [ -d "$SRC_ROOT/$rel" ] || continue
    excludes=("${RSYNC_EXCLUDES[@]}")
    if [ -n "$extra" ]; then
      IFS=',' read -ra _ex <<<"$extra"
      for e in "${_ex[@]}"; do excludes+=(--exclude "$e"); done
    fi
    rsync --archive --delete --dry-run --verbose "${excludes[@]}" \
      "$SRC_ROOT/$rel/" "$ROOT_DIR/$rel/" 2>/dev/null \
      | sed -n "s#^deleting #$rel/#p" >> "$PRUNE_LIST" || true
  done

  PRUNE_COUNT=$(wc -l < "$PRUNE_LIST" | tr -d ' ')
  DO_PRUNE=false
  if [ "${PRUNE_COUNT:-0}" -eq 0 ]; then
    log "No orphaned files to prune; live tree already matches the deployed branch."
  else
    prune_size="$( (cd "$ROOT_DIR" && tr '\n' '\0' < "$PRUNE_LIST" | du -sch --files0-from=- 2>/dev/null | tail -1 | awk '{print $1}') )"
    warn "Pruning preview: the deployed branch no longer ships these ${PRUNE_COUNT} path(s) (~${prune_size:-?}) that exist in the live tree:"
    sed 's/^/    /' "$PRUNE_LIST" >&2
    warn "(Protected, NOT shown and never deleted: deploy.yml, databases/docker volumes, .env, uploads, node_modules, build output.)"
    if [ "${ETHORA_UPDATE_PRUNE:-}" = "true" ]; then
      DO_PRUNE=true
      log "ETHORA_UPDATE_PRUNE=true -> pruning the paths above."
    elif [ "${ETHORA_UPDATE_PRUNE:-}" = "false" ]; then
      warn "ETHORA_UPDATE_PRUNE=false -> NOT pruning. Build may fail on leftover source."
    elif [ -t 0 ] && [ -t 1 ]; then
      printf '[update] Delete the %s orphaned path(s) listed above? [y/N] ' "$PRUNE_COUNT" >&2
      read -r _ans </dev/tty 2>/dev/null || _ans=""
      case "$_ans" in
        [yY]|[yY][eE][sS]) DO_PRUNE=true ;;
        *) warn "Not pruning (declined)." ;;
      esac
    else
      warn "Non-interactive run: NOT pruning. Re-run with ETHORA_UPDATE_PRUNE=true to remove the orphans above."
    fi
  fi
  rm -f "$PRUNE_LIST"
  PRUNE_FLAG=()
  [ "$DO_PRUNE" = true ] && PRUNE_FLAG=(--delete)

  # Pass 2: sync each target (pruning only if confirmed above).
  for spec in "${SYNC_TARGETS[@]}"; do
    IFS='|' read -r label rel extra <<<"$spec"
    [ -d "$SRC_ROOT/$rel" ] || continue
    excludes=("${RSYNC_EXCLUDES[@]}")
    if [ -n "$extra" ]; then
      IFS=',' read -ra _ex <<<"$extra"
      for e in "${_ex[@]}"; do excludes+=(--exclude "$e"); done
    fi
    log "Syncing ${label}..."
    mkdir -p "$ROOT_DIR/$rel"
    rsync "${RSYNC_COMMON[@]}" "${PRUNE_FLAG[@]}" "${excludes[@]}" \
      "$SRC_ROOT/$rel/" "$ROOT_DIR/$rel/"
  done

  if [ -d "$ROOT_DIR/deploy" ] && [ "$ROOT_DIR/deploy" != "$DEPLOY_DIR" ]; then
    log "Removing stale target-side deploy directory: $ROOT_DIR/deploy"
    rm -rf "$ROOT_DIR/deploy"
  fi
fi

ensure_runtime_tree_owned_by_deploy_user

reload_config_from_deploy_yml "$CANONICAL_DEPLOY_CONFIG_FILE"

log "Regenerating .env files from templates..."
bash "$RUNTIME_DEPLOY_DIR/scripts/setup-env.sh"

# CRITICAL: re-source .deploy.env after setup-env.sh runs.
#
# setup-env.sh executes in a child shell, so anything it `export`s does not
# propagate back to update.sh. It DOES persist values to .deploy.env, but
# without an explicit re-source here, update.sh's later `docker compose up`
# runs without the freshly-resolved per-service data-dir vars (MONGO_DATA_DIR,
# MYSQL_DATA_DIR, etc.) in its environment.
#
# Compose then falls back to its compose-file default - which may resolve to
# a DIFFERENT path than where data actually lives. We lost a customer's
# MUC state this way: setup-env.sh correctly set MYSQL_DATA_DIR to the
# EJABBERD_DIR-based path (where 1.1 GB of data lived), but compose without
# the env used its `./` default (compose-relative = different path) and
# silently recreated mysql with an empty mount.
#
# Re-source unconditionally; it's cheap and the file is regenerated by
# setup-env.sh on every run.
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE" || warn "Failed to re-source $ENV_FILE after setup-env.sh"
fi

if [ "${WIDGET_ENABLED:-false}" = "true" ] && [ ! -f "$ROOT_DIR/ethora-ai-chat-widget/package.json" ]; then
  echo "[ERROR] Widget hosting is enabled, but target widget sources are missing after sync: $ROOT_DIR/ethora-ai-chat-widget" >&2
  exit 1
fi

# Refresh SSL material before generating/reloading nginx configs.
# This is especially important when domains or ssl.method change on an existing install
# (for example switching hosted apps to ssl.method=provided with a wildcard cert).
if [ "${API_DOMAIN:-}" != "localhost" ]; then
  log "Refreshing SSL certificates/material..."
  bash "$RUNTIME_DEPLOY_DIR/scripts/setup-ssl.sh" || warn "SSL setup failed or skipped"
fi

# Regenerate Nginx configs (ensures XMPP /ws and /bosh are proxied; skips for localhost)
if [ "${API_DOMAIN:-}" != "localhost" ]; then
  log "Refreshing Nginx configuration..."
  bash "$RUNTIME_DEPLOY_DIR/scripts/setup-nginx.sh" || warn "Nginx setup failed or skipped"
fi

log "Refreshing ejabberd config (domain + sql password)..."
bash "$RUNTIME_DEPLOY_DIR/scripts/xmpp-from-image.sh" || { echo "[ERROR] ejabberd image mode setup failed" >&2; exit 1; }
bash "$RUNTIME_DEPLOY_DIR/scripts/setup-ejabberd-config.sh" || true

log "Starting/refreshing docker services..."
if [ -f "$RUNTIME_DEPLOY_DIR/docker-compose.enterprise.yml" ]; then
  # Safety: don't let `compose up` move stateful mounts to an empty path.
  abort_if_stateful_mounts_will_drift "$RUNTIME_DEPLOY_DIR/docker-compose.enterprise.yml"

  COMPOSE_PROFILES=()
  if [ "${CRAWLER_ENABLED:-false}" == "true" ]; then
    COMPOSE_PROFILES+=(--profile ai)
  fi

  # If the ejabberd Dockerfile/entrypoint changed, rebuild xmpp image.
  # Otherwise `up -d` will reuse an old image and new entrypoint logic won't take effect.
  #
  # The custom modules are bind-mounted from docker/custom_modules and compiled
  # by the entrypoint only when no .beam exists yet for a source. The compiled
  # beams land in $HOME/.ejabberd-modules/compiled, and $HOME (/opt/ejabberd,
  # /home/ejabberd is a symlink to it) is a persistent volume - so they survive
  # restarts AND container recreation. A module that gained new options
  # (mod_edit/mod_delete url+secret) therefore keeps rejecting them with
  # "Unknown option" until its stale beam is removed. So the module sources
  # are part of the stamp too, and a change purges the compiled beams (they
  # are rebuilt from the current sources on the next start) and recreates
  # the container (below).
  EJABBERD_RUNTIME_DIR="${EJABBERD_DIR:-$ROOT_DIR/ejabberd-docker}"
  xmpp_stamp="$STATE_DIR/xmpp-image.sha256"
  dockerfile_hash="$(hash_file_sha256 "$EJABBERD_RUNTIME_DIR/docker/Dockerfile")"
  entrypoint_hash="$(hash_file_sha256 "$EJABBERD_RUNTIME_DIR/docker/entrypoint.sh")"
  modules_hash="$(hash_ejabberd_modules_sha256 "$EJABBERD_RUNTIME_DIR/docker/custom_modules")"
  xmpp_hash="${dockerfile_hash}${entrypoint_hash}${modules_hash}"
  [ "${EJABBERD_MODE:-source}" = "image" ] && xmpp_hash="image:${ETHORA_XMPP_IMAGE:-}:${entrypoint_hash}"
  xmpp_recreate="false"
  if [ -n "$xmpp_hash" ] && [ "$(cat "$xmpp_stamp" 2>/dev/null || echo '')" != "$xmpp_hash" ]; then
    if [ "${EJABBERD_MODE:-source}" = "image" ]; then
      log "ejabberd files changed (image mode: already extracted from ${ETHORA_XMPP_IMAGE:-the image}; no build)"
    else
      log "Rebuilding xmpp image (ejabberd docker files or custom modules changed)..."
      compose -f "$RUNTIME_DEPLOY_DIR/docker-compose.enterprise.yml" build xmpp || true
    fi
    echo "$xmpp_hash" >"$xmpp_stamp" 2>/dev/null || true
    xmpp_recreate="true"

    # Purge the compiled beams so the entrypoint recompiles every module from
    # the current sources. See ejabberd_volume_maintenance for how the volume
    # is reached; only the compiled dir is touched, the ejabberd database in
    # the same volume is left alone.
    ejabberd_volume_maintenance purge
  fi

  # Always clear a stray conf/jwt.key directory before `up -d`: it makes the
  # xmpp container fail to start with "not a directory" and nothing else
  # repairs it (see ejabberd_volume_maintenance).
  ejabberd_volume_maintenance keep

  compose -f "$RUNTIME_DEPLOY_DIR/docker-compose.enterprise.yml" "${COMPOSE_PROFILES[@]}" up -d

  # Drop sentinel READMEs into stateful data dirs so operators see a clear
  # warning before any 'rm -rf' on these paths. Idempotent.
  if [ -x "$RUNTIME_DEPLOY_DIR/scripts/ensure-data-sentinels.sh" ]; then
    bash "$RUNTIME_DEPLOY_DIR/scripts/ensure-data-sentinels.sh" || true
  fi

  # Ensure xmpp picks up updated ejabberd.yml (domain/sql_password changes).
  # When the ejabberd docker files or custom module sources changed, recreate
  # the container instead: only a fresh container recompiles the modules from
  # the current sources (see the xmpp_stamp note above).
  if [ "$xmpp_recreate" == "true" ]; then
    log "Recreating xmpp container so custom modules are recompiled from current sources..."
    compose -f "$RUNTIME_DEPLOY_DIR/docker-compose.enterprise.yml" up -d --force-recreate --no-deps xmpp || true
  else
    compose -f "$RUNTIME_DEPLOY_DIR/docker-compose.enterprise.yml" restart xmpp || true
  fi

  # Restart centrifugo when its (bind-mounted) config has changed.
  # Bind-mount changes don't trigger Docker to recreate the container; without an explicit
  # restart, a freshly rotated HMAC secret in centrifugo-config.json would not be picked up
  # by the running container, breaking the wsToken signed by the (already-restarted) backend.
  CENTRIFUGO_RUNTIME_CONFIG="${BACKEND_DIR:-$ROOT_DIR/ethora-backend}/centrifugo-config.json"
  centrifugo_stamp="$STATE_DIR/centrifugo-config.sha256"
  centrifugo_hash="$(hash_file_sha256 "$CENTRIFUGO_RUNTIME_CONFIG")"
  if [ -n "$centrifugo_hash" ] && [ "$(cat "$centrifugo_stamp" 2>/dev/null || echo '')" != "$centrifugo_hash" ]; then
    log "Restarting centrifugo (config.json changed)..."
    compose -f "$RUNTIME_DEPLOY_DIR/docker-compose.enterprise.yml" restart centrifugo || true
    echo "$centrifugo_hash" >"$centrifugo_stamp" 2>/dev/null || true
  fi
fi

# ejabberd keeps its MUC rooms in MySQL; make sure the index prefixes are wide
# enough for Ethora's 1:1 room names (scripts/ensure-ejabberd-sql-schema.sh,
# idempotent, online). Runs before the data migrations below, which recreate
# the rooms that were lost while the prefix was too short.
if [ -f "$RUNTIME_DEPLOY_DIR/scripts/ensure-ejabberd-sql-schema.sh" ]; then
  bash "$RUNTIME_DEPLOY_DIR/scripts/ensure-ejabberd-sql-schema.sh" \
    || warn "ejabberd MySQL schema check failed (non-fatal); re-run: sudo bash $RUNTIME_DEPLOY_DIR/scripts/ensure-ejabberd-sql-schema.sh"
fi

if [ "${AI_SERVICE_ENABLED:-false}" == "true" ] && [ -f "$RUNTIME_DEPLOY_DIR/scripts/setup-ai-postgres.sh" ]; then
  log "Starting/refreshing AI embeddings Postgres..."
  bash "$RUNTIME_DEPLOY_DIR/scripts/setup-ai-postgres.sh"
fi

if [ "${UPTIME_ENABLED:-false}" == "true" ] && [ -f "$RUNTIME_DEPLOY_DIR/docker-compose.uptime.yml" ]; then
  log "Starting/refreshing uptime docker services..."
  # Uptime serves static UI assets from the container image (dist/public).
  # When uptime code changes, we must rebuild the image for fixes to take effect.
  UPTIME_RUNTIME_DIR="${UPTIME_DIR:-$ROOT_DIR/ethora-uptime}"
  uptime_stamp="$STATE_DIR/uptime-image.sha256"
  uptime_hash="$(hash_tree_sha256 "$UPTIME_RUNTIME_DIR")"
  uptime_needs_build="true"
  if [ -n "$uptime_hash" ] && [ -f "$uptime_stamp" ] && [ "$(cat "$uptime_stamp" 2>/dev/null || echo '')" = "$uptime_hash" ]; then
    uptime_needs_build="false"
  fi

  if [ "$uptime_needs_build" = "true" ]; then
    log "Rebuilding uptime image (source changed or no prior build stamp)..."
    compose -f "$RUNTIME_DEPLOY_DIR/docker-compose.uptime.yml" up -d --build
    if [ -n "$uptime_hash" ]; then
      echo "$uptime_hash" >"$uptime_stamp" 2>/dev/null || true
    fi
  else
    log "Uptime source unchanged; skipping image rebuild"
    compose -f "$RUNTIME_DEPLOY_DIR/docker-compose.uptime.yml" up -d
  fi
fi

# Monitoring stack (Prometheus + Grafana + cAdvisor + node-exporter).
# Monitoring (deploy/monitoring), driven by services.monitoring.mode in
# deploy.yml: off (the default, so it never starts on prod by accident),
# local (Prometheus + Grafana on this host) or remote (agents pushing to the
# central monitoring server). setup-nginx.sh resolves the mode, renders the
# per-mode configs into generated/monitoring and writes monitoring/.env, which
# compose auto-loads from the monitoring dir; MONITORING_MODE is read from
# there. Non-fatal: a monitoring failure must not abort the app deploy.
MONITORING_ENV="$RUNTIME_DEPLOY_DIR/monitoring/.env"
MONITORING_MODE="$(sed -n 's/^MONITORING_MODE=//p' "$MONITORING_ENV" 2>/dev/null | head -n1)"
MONITORING_MODE="${MONITORING_MODE:-off}"
monitoring_compose() { ( cd "$RUNTIME_DEPLOY_DIR/monitoring" && compose -f docker-compose.monitoring.yml "$@" ); }
monitoring_profile_on() { # NAME -> 0 when COMPOSE_PROFILES in monitoring/.env lists it
  grep -q "^COMPOSE_PROFILES=\([^ ]*,\)\?$1\(,.*\)\?$" "$MONITORING_ENV" 2>/dev/null
}
monitoring_env_value() { # KEY -> its value in monitoring/.env, quotes stripped
  sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$MONITORING_ENV" 2>/dev/null | head -n1
}
monitoring_remove() { # CONTAINER... -> remove those that exist
  local c
  for c in "$@"; do
    if [ -n "$(docker ps -aq --filter "name=^${c}$" 2>/dev/null)" ]; then
      log "Monitoring: removing $c (not used in mode '$MONITORING_MODE')..."
      docker rm -f "$c" >/dev/null 2>&1 || log "[WARN] could not remove $c (non-fatal)"
    fi
  done
}
monitoring_restart_if_changed() { # STAMP SERVICE FILE... -> restart SERVICE when the files' joint hash changed since the last deploy
  local stamp="$STATE_DIR/$1.sha256" svc="$2" f hash files=()
  shift 2
  for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  hash="$(cat "${files[@]}" | sha256sum 2>/dev/null | awk '{print $1}')"
  if [ -n "$hash" ] && [ "$(cat "$stamp" 2>/dev/null || echo '')" != "$hash" ]; then
    log "Monitoring: $svc config changed; restarting $svc..."
    monitoring_compose restart "$svc" || log "[WARN] $svc restart failed (non-fatal)"
    echo "$hash" >"$stamp" 2>/dev/null || true
  fi
}
monitoring_mode_stamp="$STATE_DIR/monitoring-mode"
monitoring_prev_mode="$(cat "$monitoring_mode_stamp" 2>/dev/null || echo '')"
if [ "$MONITORING_MODE" == "off" ]; then
  # Switched off: stop what an earlier mode started. A stack that was never
  # started through deploy.yml (no stamp; e.g. brought up by hand for a load
  # test) is left alone.
  if [ -n "$monitoring_prev_mode" ] && [ "$monitoring_prev_mode" != "off" ]; then
    log "Monitoring switched off; removing the monitoring containers..."
    monitoring_remove ethora-prometheus ethora-grafana ethora-grafana-renderer ethora-prometheus-agent \
      ethora-vector ethora-victorialogs ethora-cadvisor ethora-node-exporter
  fi
elif [ -f "$RUNTIME_DEPLOY_DIR/monitoring/docker-compose.monitoring.yml" ]; then
  log "Starting/refreshing monitoring stack (mode: $MONITORING_MODE)..."
  # `up -d` only manages the services of the active profiles, so containers
  # of the other mode or of a switched-off option are removed by hand, and
  # before `up`: the local Prometheus and the agent share port 9090.
  case "$MONITORING_MODE" in
    local)  monitoring_remove ethora-prometheus-agent ;;
    remote) monitoring_remove ethora-prometheus ethora-grafana ethora-grafana-renderer ethora-victorialogs ;;
  esac
  monitoring_profile_on renderer || monitoring_remove ethora-grafana-renderer
  monitoring_profile_on victorialogs || monitoring_remove ethora-victorialogs
  monitoring_profile_on logs || monitoring_remove ethora-vector
  monitoring_compose up -d \
    || log "[WARN] monitoring stack failed to start (non-fatal); check: (cd deploy/monitoring && docker compose -f docker-compose.monitoring.yml ps)"

  # The config files are bind-mounted and read at start-up only, so `up -d`
  # does not notice edits to them: restart the service whose files changed
  # since the last deploy. Grafana re-reads dashboard JSON on its own, but its
  # alerting provisioning (rules, contact points, templates) is start-up only;
  # the rendered directory (setup-nginx.sh) is hashed so that a change in
  # alerts.emails restarts it too.
  mon_dir="$RUNTIME_DEPLOY_DIR/monitoring"
  if [ "$MONITORING_MODE" == "local" ]; then
    monitoring_restart_if_changed prometheus-config prometheus "$mon_dir/prometheus/prometheus.yml" "$mon_dir/prometheus/scrape.yml"
    alerting_dir="$RUNTIME_DEPLOY_DIR/generated/monitoring/alerting"
    [ -d "$alerting_dir" ] || alerting_dir="$mon_dir/grafana/provisioning/alerting"
    monitoring_restart_if_changed grafana-alerting grafana "$alerting_dir"/*.yml
  else
    monitoring_restart_if_changed prometheus-agent-config prometheus-agent "$(monitoring_env_value PROMETHEUS_AGENT_CONFIG)" "$mon_dir/prometheus/scrape.yml"
  fi
  if monitoring_profile_on logs; then
    vector_sink="$(monitoring_env_value VECTOR_SINK_CONFIG)"
    monitoring_restart_if_changed vector-config vector "$mon_dir/vector/vector.yaml" "${vector_sink:-$mon_dir/vector/sink-local.yaml}"
  fi
fi
echo "$MONITORING_MODE" >"$monitoring_mode_stamp" 2>/dev/null || true

log "Restarting Node.js services (PM2)..."
bash "$RUNTIME_DEPLOY_DIR/scripts/setup-node-services.sh"

log "Running init-services (idempotent)..."
bash "$RUNTIME_DEPLOY_DIR/scripts/init-services.sh" || true

log "Regenerating .env files after init-services..."
bash "$RUNTIME_DEPLOY_DIR/scripts/setup-env.sh"

# Re-source again (see rationale above the first setup-env.sh call).
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE" || warn "Failed to re-source $ENV_FILE after setup-env.sh"
fi

if [ "${UPTIME_ENABLED:-false}" == "true" ] && [ -f "$RUNTIME_DEPLOY_DIR/docker-compose.uptime.yml" ]; then
  log "Refreshing uptime docker services after env regeneration..."
  # Changes inside generated uptime env/config files do not reliably trigger recreation,
  # so force-recreate the uptime service after setup-env.sh refreshes them.
  compose -f "$RUNTIME_DEPLOY_DIR/docker-compose.uptime.yml" up -d --force-recreate uptime
fi

# Data migrations. Deliberately after the restart, not before: every migration in
# the registry is required to leave the database in a state the new code already
# handles, so the app is correct while one is still in flight. Running them first
# would instead block the deploy behind a long backfill.
#
# Not fatal on the spot - QA and health checks still run, so an operator sees the
# whole picture rather than just the first failure - but the exit status is kept
# and the run does not get to claim success.
MIGRATIONS_FAILED="false"
if [ "${SKIP_MIGRATIONS:-false}" == "true" ]; then
  log "Skipping data migrations (--skip-migrations)"
elif [ -f "$RUNTIME_DEPLOY_DIR/scripts/run-migrations.sh" ]; then
  log "Running data migrations (idempotent)..."
  if ! bash "$RUNTIME_DEPLOY_DIR/scripts/run-migrations.sh"; then
    MIGRATIONS_FAILED="true"
    warn "Data migrations reported a failure - see the output above."
    warn "The stack is running; un-migrated rows are a state the app tolerates."
    warn "Re-run with: sudo bash $RUNTIME_DEPLOY_DIR/scripts/run-migrations.sh"
  fi
else
  log "No run-migrations.sh in this deploy tree; skipping data migrations"
fi

if [ "$NO_QA" != "true" ]; then
  log "Running quick QA checks..."
  bash "$RUNTIME_DEPLOY_DIR/scripts/qa-check.sh" --config "$CANONICAL_DEPLOY_CONFIG_FILE"
  log "Running full health checks..."
  bash "$RUNTIME_DEPLOY_DIR/scripts/health-check.sh"
else
  log "Skipping QA checks (--no-qa)"
fi

# Advisory config-gap report (never fails the update).
if [ -f "$RUNTIME_DEPLOY_DIR/scripts/report-config-gaps.sh" ]; then
  ROOT_DIR="$ROOT_DIR" DEPLOY_DIR="$RUNTIME_DEPLOY_DIR" \
    bash "$RUNTIME_DEPLOY_DIR/scripts/report-config-gaps.sh" || true
fi

if [ "$MIGRATIONS_FAILED" == "true" ]; then
  warn "Update finished, but data migrations did not - see 'Data migrations' above."
  exit 1
fi

log "Update completed successfully"


