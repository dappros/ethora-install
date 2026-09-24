#!/usr/bin/env bash
# preflight-paths.sh - the deploy's path safety guard.
#
# Runs at the very start of install.sh / update.sh, BEFORE anything touches
# services or data. It enforces a few hard rules that make the "wrong data
# directory" class of incident impossible, prints the plan, and stops the run
# the instant reality does not match the plan.
#
# Three directories, each with one job:
#   SRC_DIR    - the git distribution this runs from. Disposable, overwritten.
#   TARGET_DIR - the live install (code + rendered config). Default $HOME/ethora.
#   DATA_DIR   - ALL persistent data (mongo/minio/mysql/redis), independent of
#                both trees. Default $HOME/ethora-data.
#
# Hard rules (each is a refuse-and-exit, no guessing):
#   1. SRC_DIR == TARGET_DIR              -> in-place installs are not allowed.
#   2. A data dir resolves inside SRC_DIR -> data must never live in the git tree.
#   3. The configured data dir is empty but a copy exists at a legacy path
#      -> stop; the operator migrates explicitly (never silently adopt a copy).
#
# Inputs (env or .deploy.env): SRC_DIR/SOURCE_ROOT, TARGET_DIR/ROOT_DIR, DATA_DIR,
# and any explicit {MONGO,MINIO,MYSQL,REDIS}_DATA_DIR overrides.
# Flags: --yes (skip the confirm on a non-recommended-but-safe layout).
#
# Can also be SOURCED (PREFLIGHT_LIB_ONLY=1) to reuse resolve_service_data_dir.

set -uo pipefail

ASSUME_YES=0
for a in "$@"; do case "$a" in --yes|-y) ASSUME_YES=1 ;; esac; done

_c() { if [ -t 1 ]; then printf '%b' "$1"; else printf ''; fi; }
RED=$(_c '\033[0;31m'); YEL=$(_c '\033[1;33m'); GRN=$(_c '\033[0;32m'); CYN=$(_c '\033[0;36m'); BLD=$(_c '\033[1m'); NC=$(_c '\033[0m')
die()  { echo; echo "${RED}${BLD}REFUSING TO PROCEED:${NC} $1" >&2; echo; exit 1; }
note() { echo "${YEL}[preflight]${NC} $1" >&2; }

# The invoking user's home, even under sudo (sudo may set HOME=/root).
_home() {
  local u="${SUDO_USER:-$USER}"
  getent passwd "$u" 2>/dev/null | cut -d: -f6 | grep . || echo "${HOME:-/root}"
}

# Absolute, symlink-resolved path (empty if it doesn't exist yet is fine).
_abs() { readlink -f "$1" 2>/dev/null || ( cd "$(dirname "$1")" 2>/dev/null && echo "$(pwd)/$(basename "$1")" ) || echo "$1"; }

# Is $1 the same dir as, or nested under, $2 ?
_under() {
  local child parent; child="$(_abs "$1")"; parent="$(_abs "$2")"
  [ -n "$child" ] && [ -n "$parent" ] || return 1
  case "$child/" in "$parent/"*) return 0 ;; *) return 1 ;; esac
}

# A data dir "has data" if it exists and is non-empty.
_has_data() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null | head -1)" ]; }
_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# --- resolve the three roots -------------------------------------------------
HOME_DIR="$(_home)"
SRC_DIR="$(_abs "${SRC_DIR:-${SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}")"
TARGET_DIR="$(_abs "${TARGET_DIR:-${ROOT_DIR:-$HOME_DIR/ethora}}")"
DATA_DIR_RESOLVED="$(_abs "${DATA_DIR:-$HOME_DIR/ethora-data}")"

# --- per-service data dir: explicit override, else DATA_DIR/<svc> -------------
# NO silent legacy adoption - if legacy data exists it is surfaced as a
# collision below and the operator migrates on purpose.
resolve_service_data_dir() {
  local svc="$1" var; var="$(echo "$svc" | tr a-z A-Z)_DATA_DIR"
  local explicit; eval "explicit=\${$var:-}"
  if [ -n "$explicit" ]; then echo "$(_abs "$explicit")"; else echo "$DATA_DIR_RESOLVED/$svc"; fi
}

# Known historical locations to scan for an existing copy (the collision check).
legacy_candidates() {
  local svc="$1" subs sub
  case "$svc" in
    mysql) subs="ejabberd-docker/docker-data/my-sql" ;;
    # Two backend layouts have been in the wild: the current
    # ethora-backend/infra/docker/data/<svc> and an older
    # ethora-backend/docker/data/<svc> (no `infra`). A QA box was still carrying
    # a 307M Mongo copy at the older one, invisible to this check until it was
    # found by hand - so scan both.
    *)     subs="ethora-backend/infra/docker/data/$svc ethora-backend/docker/data/$svc" ;;
  esac
  for sub in $subs; do
    echo "$SRC_DIR/deploy/$sub"
    echo "$SRC_DIR/$sub"
    echo "$TARGET_DIR/deploy/$sub"
    echo "$TARGET_DIR/$sub"
  done
  echo "$TARGET_DIR/data/$svc"
  echo "$SRC_DIR/data/$svc"
}

[ "${PREFLIGHT_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ============================ RULE 1: no in-place =============================
if [ "$SRC_DIR" = "$TARGET_DIR" ]; then
  die "SRC_DIR and TARGET_DIR are the same directory:
    $SRC_DIR
  In-place installs are not allowed (the git tree gets overwritten on update,
  taking any data with it). Set a separate target, e.g.:
    - paths.base in deploy.yml, or
    - TARGET_DIR=$HOME_DIR/ethora
  and re-run."
fi

# ================= resolve + validate every stateful service =================
SERVICES="mongo minio mysql redis"
PLAN=""; DANGER=0
for svc in $SERVICES; do
  cfg="$(resolve_service_data_dir "$svc")"

  # RULE 2: never under the disposable source tree.
  if _under "$cfg" "$SRC_DIR"; then
    die "$svc data dir is inside the source tree (SRC_DIR):
    $cfg
  Data must live under DATA_DIR ($DATA_DIR_RESOLVED), which is separate from the
  git distribution. Unset ${svc^^}_DATA_DIR (to use the default) or point it under DATA_DIR."
  fi

  # RULE 3: configured dir empty but a copy exists elsewhere -> stop.
  status="new"
  if _has_data "$cfg"; then
    status="existing ($(_size "$cfg"))"
    # extra copies elsewhere are just noise to clean up later - note, don't block
    while read -r cand; do
      [ -z "$cand" ] && continue
      [ "$(_abs "$cand")" = "$cfg" ] && continue
      _has_data "$cand" && note "$svc: another copy exists at $cand ($(_size "$cand")) - not used; clean up when convenient."
    done < <(legacy_candidates "$svc")
  else
    found=""
    while read -r cand; do
      [ -z "$cand" ] && continue
      [ "$(_abs "$cand")" = "$cfg" ] && continue
      if _has_data "$cand"; then found="$cand"; break; fi
    done < <(legacy_candidates "$svc")
    if [ -n "$found" ]; then
      DANGER=1
      die "$svc data is NOT at the configured path but a copy exists elsewhere:
    configured (empty/absent): $cfg
    existing data:             $found ($(_size "$found"))
  Coming up on the configured path would serve an empty/stale database while the
  real data sits untouched at the other path. Resolve it explicitly:
    sudo $(dirname "${BASH_SOURCE[0]}")/migrate-data-paths.sh    # move it under DATA_DIR
  or set ${svc^^}_DATA_DIR to the copy you want in deploy/.deploy.env, then re-run."
    fi
  fi
  PLAN="$PLAN  $svc -> $cfg  [$status]\n"
done

# ============ RULE 4: component dirs must follow TARGET_DIR ==================
# BACKEND_DIR / FRONTEND_DIR / ... are what actually gets built, PM2'd and served.
# If they still point into SRC_DIR (typical when an in-place install grows a
# separate TARGET_DIR), the deploy builds and serves the live site from the
# disposable git tree while nginx points at the target - the app breaks, and the
# running code is one sync away from being overwritten.
COMPONENT_DIRS="BACKEND_DIR:ethora-backend FRONTEND_DIR:ethora-app-reactjs EJABBERD_DIR:ejabberd-docker PLAYGROUND_DIR:ethora-sdk-playground UPTIME_DIR:ethora-uptime WIDGET_DIR:ethora-ai-chat-widget MCP_DIR:ethora-mcp-server"
STRAY=""
for entry in $COMPONENT_DIRS; do
  var="${entry%%:*}"; sub="${entry##*:}"
  eval "val=\${$var:-}"
  [ -n "$val" ] || continue
  if _under "$val" "$SRC_DIR"; then
    STRAY="${STRAY}    $var=$val
      should be: $TARGET_DIR/$sub
"
  fi
done
if [ -n "$STRAY" ]; then
  die "component directories still point inside the source tree (SRC_DIR):
$STRAY  These decide what gets built, run under PM2 and served by nginx, so the live
  site would run from the disposable git distribution instead of TARGET_DIR.
  Fix them in deploy/.deploy.env (they follow TARGET_DIR), then re-run."
fi

# ================================ the plan ===================================
echo
echo "${BLD}Deploy path plan${NC}"
echo "  Source (distribution): $SRC_DIR   ${CYN}[git, disposable]${NC}"
echo "  Target (live install): $TARGET_DIR"
echo "  Data (persistent):     $DATA_DIR_RESOLVED"
echo -e "$PLAN"

# ==================== confirm only on a non-recommended layout ================
DEVIATION=""
[ "$TARGET_DIR" = "$HOME_DIR/ethora" ] || DEVIATION="${DEVIATION}  - TARGET_DIR is not the recommended $HOME_DIR/ethora\n"
[ "$DATA_DIR_RESOLVED" = "$HOME_DIR/ethora-data" ] || DEVIATION="${DEVIATION}  - DATA_DIR is not the recommended $HOME_DIR/ethora-data\n"
if [ -n "$DEVIATION" ]; then
  echo "${YEL}This is a non-recommended (but allowed) layout:${NC}"
  echo -e "$DEVIATION"
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
    note "proceeding (--yes / non-interactive)."
  else
    printf "Proceed? [y/N] " >&2; read -r ans </dev/tty 2>/dev/null || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) die "aborted by operator." ;; esac
  fi
fi

echo "${GRN}[preflight] path checks passed.${NC}"
exit 0
