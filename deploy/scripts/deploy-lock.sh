#!/usr/bin/env bash
# deploy-lock.sh - one install.sh / update.sh at a time per install.
#
# Sourced by install.sh and update.sh. Two runs at once race on everything
# they touch: both recreate the same containers (compose then fails with
# "container name ... is already in use"), and both rewrite deploy/.deploy.env
# key by key, so one can read the file while the other has it truncated and
# write back a copy that has lost secrets, data paths and ROOT_DIR.
#
# The lock is a directory (mkdir is atomic) holding the owner's PID, not a
# flock'ed fd: the runs start long-lived children (the pm2 daemon, nohup'ed
# services) that would inherit the fd and keep the lock after the run ends.
# A lock whose PID no longer runs install.sh / update.sh (killed run, reboot)
# is taken over with a warning.
#
# update.sh re-executes itself (maybe_reexec_updated_script), possibly from
# another tree: ETHORA_DEPLOY_LOCK carries the lock across the exec, and the
# same PID re-acquiring it is a no-op apart from re-arming the release trap
# (exec drops traps).
#
#   source "$SCRIPT_DIR/deploy-lock.sh"
#   acquire_deploy_lock "$STATE_DIR" update.sh

_deploy_lock_runs_deploy() {
  # True when PID $1 is alive and runs install.sh or update.sh.
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  [ -r "/proc/$pid/cmdline" ] || return 0
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE '(install|update)\.sh'
}

_deploy_lock_release() {
  local lock="${ETHORA_DEPLOY_LOCK:-}"
  [ -n "$lock" ] && [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$lock"
  return 0
}

acquire_deploy_lock() {
  local state_dir="$1" who="${2:-deploy}"
  local lock="${ETHORA_DEPLOY_LOCK:-$state_dir/deploy.lock}"

  if [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ]; then
    export ETHORA_DEPLOY_LOCK="$lock"
    trap _deploy_lock_release EXIT
    return 0
  fi

  mkdir -p "$(dirname "$lock")"
  if ! mkdir "$lock" 2>/dev/null; then
    local pid owner
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    if _deploy_lock_runs_deploy "$pid"; then
      echo "[ERROR] Another install.sh or update.sh is already running on this install." >&2
      echo "[ERROR]   ${owner:-pid $pid}" >&2
      echo "[ERROR] Two runs at once race on the containers and on deploy/.deploy.env." >&2
      echo "[ERROR] Wait for it to finish (lock: $lock)." >&2
      exit 1
    fi
    echo "[WARN] Taking over a deploy lock left by a run that is gone: ${owner:-pid ${pid:-?}}" >&2
    rm -rf "$lock"
    if ! mkdir "$lock" 2>/dev/null; then
      echo "[ERROR] Another run took the deploy lock first (lock: $lock)." >&2
      exit 1
    fi
  fi

  printf '%s\n' "$$" > "$lock/pid"
  printf '%s pid %s, started %s by %s\n' "$who" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-$(id -un 2>/dev/null)}" > "$lock/owner"
  export ETHORA_DEPLOY_LOCK="$lock"
  trap _deploy_lock_release EXIT
}
