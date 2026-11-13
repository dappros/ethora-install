#!/usr/bin/env bash
# update.sh - update this Ethora install to a newer build, or roll back.
#
#   sudo ./update.sh                    the newest build of this release line
#   sudo ./update.sh --to 2610.80       a given build
#   sudo ./update.sh --rollback         back to the build that ran before the last update
#
# The admin panel's "Update now" runs this same script through the updater
# service (updater/README.md), which follows it in .update/state.json.
#
# Steps:
#   bundle     git pull of the install files (skipped when this is not a git checkout)
#   configure  ETHORA_TAG=<build> in .env, then ./configure.sh --yes (keeps every
#              answer and secret, refreshes the registry login)
#   pull       docker compose pull; everything keeps running meanwhile
#   waiting    until --at, when given (cancel: touch .update/cancel)
#   restart    docker compose up -d: changed services are recreated (about a minute)
#   check      api, xmpp and frontend healthy and the API on the new build
# A failure before `restart` puts ETHORA_TAG back and changes nothing that runs.
# A rollback skips bundle and configure, and pulls only images that are missing.
# Database migrations run forward on start: a rollback after one is not
# guaranteed to work, which is why the admin panel asks for a backup first.
#
# Options:
#   --to BUILD      target build (<line>.<n>); default: the newest on Docker Hub
#   --rollback      target = the build in .update/previous
#   --at TIME       restart not before TIME (ISO 8601 or epoch seconds)
#   --no-bundle     leave the install files as they are
#   --job-id ID     set by the updater service
#   --yes           no confirmation question
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run from a copy: `git pull` may replace this file while bash reads it.
if [ -z "${ETHORA_UPDATE_COPY:-}" ]; then
  copy="$(mktemp /tmp/ethora-update.XXXXXX)"
  cp "${BASH_SOURCE[0]}" "$copy"
  ETHORA_UPDATE_COPY="$copy" ETHORA_UPDATE_HERE="$HERE" exec bash "$copy" "$@"
fi
HERE="${ETHORA_UPDATE_HERE:-$HERE}"
trap 'rm -f "$ETHORA_UPDATE_COPY"' EXIT

ENV_FILE="$HERE/.env"
STATE_DIR="$HERE/.update"
STATE="$STATE_DIR/state.json"
LOG="$STATE_DIR/job.log"
PREV_FILE="$STATE_DIR/previous"
CANCEL="$STATE_DIR/cancel"
HUB="${ETHORA_HUB_TAGS_URL:-https://hub.docker.com/v2/namespaces/dappros/repositories/ethora-api/tags?page_size=100&ordering=last_updated}"
CHECK_TIMEOUT="${ETHORA_UPDATE_CHECK_TIMEOUT:-300}"

ACTION=update; TARGET=""; AT=""; NO_BUNDLE=false; JOB_ID=""; YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --to) TARGET="$2"; shift 2 ;;
    --rollback) ACTION=rollback; shift ;;
    --at) AT="$2"; shift 2 ;;
    --no-bundle) NO_BUNDLE=true; shift ;;
    --job-id) JOB_ID="$2"; shift 2 ;;
    --yes|-y) YES=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[update] unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
if ! flock -n 9; then echo "[update] another update is running (lock $STATE_DIR/lock)" >&2; exit 4; fi
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[update] $(date -u +%H:%M:%S) $*"; }
[ -n "$JOB_ID" ] || JOB_ID="u-$(date -u +%Y%m%d-%H%M%S)"
STARTED="$(now_iso)"

# -------------------------------------------------------------- state.json --
json_str() { # JSON string or null
  [ -n "${1:-}" ] || { printf 'null'; return; }
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
  printf '"%s"' "$s"
}
if [ "$ACTION" = rollback ]; then STEPS="pull waiting restart check"; else STEPS="bundle configure pull waiting restart check"; fi
declare -A STEP_STATE=()
for s in $STEPS; do STEP_STATE[$s]=pending; done
STATE_NAME=running; STEP=""; ERROR=""; FINISHED=""; FROM=""; NOT_BEFORE=""
write_state() {
  local steps="" s
  for s in $STEPS; do steps="$steps${steps:+,}{\"name\":\"$s\",\"state\":\"${STEP_STATE[$s]}\"}"; done
  printf '{"id":%s,"action":"%s","target":%s,"from":%s,"state":"%s","step":%s,"steps":[%s],"notBefore":%s,"startedAt":"%s","finishedAt":%s,"error":%s,"runner":"%s"}\n' \
    "$(json_str "$JOB_ID")" "$ACTION" "$(json_str "$TARGET")" "$(json_str "$FROM")" "$STATE_NAME" "$(json_str "$STEP")" \
    "$steps" "$(json_str "$NOT_BEFORE")" "$STARTED" "$(json_str "$FINISHED")" "$(json_str "$ERROR")" "${ETHORA_UPDATE_RUNNER:-cli}" \
    > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
step() { [ -z "$STEP" ] || [ "${STEP_STATE[$STEP]}" != running ] || STEP_STATE[$STEP]=done; STEP="$1"; STEP_STATE[$1]=running; write_state; log "== $1"; }
skip() { STEP_STATE[$1]=skipped; write_state; }

# .env helpers: read a value, set one in place (appended when absent).
env_get() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | sed "s/^'\(.*\)'$/\1/" || true; }
env_set() {
  local tmp; tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  if grep -q "^$1=" "$ENV_FILE"; then sed "s|^$1=.*|$1=$2|" "$ENV_FILE" > "$tmp"; else { cat "$ENV_FILE"; echo "$1=$2"; } > "$tmp"; fi
  chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"
}
ORIG_TAG="$(env_get ETHORA_TAG)"
# Stock images written out in .env (older bundles did) would not follow
# ETHORA_TAG: empty them; an image of your own (a mirror, a build) stays.
clear_stock_images() {
  local k v
  for k in ETHORA_API_IMAGE ETHORA_FRONTEND_IMAGE ETHORA_XMPP_IMAGE ETHORA_AI_IMAGE ETHORA_PUSH_IMAGE \
           ETHORA_PLAYGROUND_IMAGE ETHORA_MCP_IMAGE ETHORA_UPTIME_IMAGE ETHORA_COMPOSE_INIT_IMAGE ETHORA_UPDATER_IMAGE; do
    v="$(env_get "$k")"
    if [[ "$v" =~ ^docker\.io/dappros/ethora-[a-z-]+:[0-9]{4}(\.[0-9]+)?$ ]]; then env_set "$k" ""; log "$k=$v emptied: it follows ETHORA_TAG now"; fi
  done
}
TAG_CHANGED=false
restore_tag() {
  [ "$TAG_CHANGED" = true ] || return 0
  env_set ETHORA_TAG "$ORIG_TAG"; TAG_CHANGED=false
  log "ETHORA_TAG put back to ${ORIG_TAG:-<line tag>}"
}
fail() { # fail <message>: nothing is restarted when this happens before `restart`
  ERROR="$1"; log "FAILED: $1"
  [ -z "$STEP" ] || STEP_STATE[$STEP]=failed
  if [ "$STEP" != restart ] && [ "$STEP" != check ]; then restore_tag; fi
  STATE_NAME=failed; FINISHED="$(now_iso)"; write_state; exit 1
}
cancelled() {
  [ -f "$CANCEL" ] || return 1
  rm -f "$CANCEL"; log "cancelled"
  [ -z "$STEP" ] || STEP_STATE[$STEP]=skipped
  restore_tag
  STATE_NAME=cancelled; FINISHED="$(now_iso)"; write_state; exit 0
}
rm -f "$CANCEL"
trap 'rc=$?; rm -f "$ETHORA_UPDATE_COPY"; if [ "$STATE_NAME" = running ]; then ERROR="${ERROR:-stopped unexpectedly (exit $rc)}"; STATE_NAME=failed; FINISHED="$(now_iso)"; write_state; restore_tag; fi' EXIT

cd "$HERE"
[ -f "$ENV_FILE" ] || fail "no .env in $HERE: run ./configure.sh first"
command -v docker >/dev/null 2>&1 || fail "docker not found"
dc() { docker compose --progress plain "$@"; }

running_build() { # the build the API container runs, from its image label
  local id; id="$(dc ps -q api 2>/dev/null | head -1)"
  [ -n "$id" ] || return 0
  docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$id" 2>/dev/null | grep -E '^[0-9]{4}\.[0-9]+$' || true
}
FROM="$(running_build)"
line_of() { printf '%s' "${1%%.*}"; }
LINE=""
for v in "$ORIG_TAG" "$FROM"; do [ -n "$v" ] && { LINE="$(line_of "$v")"; break; }; done
[ -n "$LINE" ] || LINE="$(sed -n 's#.*dappros/ethora-api:\${ETHORA_TAG:-\([0-9]\{4\}\)}.*#\1#p' docker-compose.yml | head -1)"

# ------------------------------------------------------------------ target --
if [ "$ACTION" = rollback ]; then
  TARGET="$(cat "$PREV_FILE" 2>/dev/null || true)"
  [ -n "$TARGET" ] || fail "nothing to roll back to: no update was made from the admin panel or update.sh yet"
elif [ -z "$TARGET" ]; then
  TARGET="$(curl -fsS -m 20 "$HUB" 2>/dev/null | grep -oE "\"name\" *: *\"$LINE\.[0-9]+\"" | grep -oE "$LINE\.[0-9]+" | sort -V | tail -1 || true)"
  [ -n "$TARGET" ] || fail "cannot find the newest $LINE build on Docker Hub; give one with --to"
fi
[[ "$TARGET" =~ ^[0-9]{4}\.[0-9]+$ ]] || fail "not a build number: $TARGET (expected <line>.<n>, e.g. 2610.80)"
[ -z "$LINE" ] || [ "$(line_of "$TARGET")" = "$LINE" ] || fail "$TARGET is not on this install's release line $LINE; moving to another line is a manual upgrade (see the release notes)"

if [ -n "$AT" ]; then
  if [[ "$AT" =~ ^[0-9]+$ ]]; then AT_EPOCH="$AT"; else AT_EPOCH="$(date -u -d "$AT" +%s 2>/dev/null)" || fail "cannot read --at $AT"; fi
  NOT_BEFORE="$(date -u -d "@$AT_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
else
  AT_EPOCH=0
fi
write_state
log "$ACTION: ${FROM:-unknown build} -> $TARGET${NOT_BEFORE:+, restart at $NOT_BEFORE} (job $JOB_ID)"
if [ "$YES" != true ] && [ -r /dev/tty ] && [ -t 0 ]; then
  read -r -p "Continue? [Y/n]: " go </dev/tty
  case "$go" in n|N|no) STATE_NAME=cancelled; FINISHED="$(now_iso)"; write_state; exit 0 ;; esac
fi

# ------------------------------------------------------------------ bundle --
if [ "$ACTION" = update ]; then
  root="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ "$NO_BUNDLE" = true ] || [ -z "$root" ]; then
    skip bundle
    [ -n "$root" ] || log "bundle: not a git checkout, install files left as they are"
  else
    step bundle
    before="$(git -C "$root" rev-parse --short HEAD)"
    if git -C "$root" pull -q --ff-only 2>&1; then
      log "bundle: $before -> $(git -C "$root" rev-parse --short HEAD)"
    else
      log "bundle: could not update $root (local changes?); continuing with the files as they are"
    fi
  fi
  cancelled || true

  step configure
  clear_stock_images
  env_set ETHORA_TAG "$TARGET"; TAG_CHANGED=true
  set +e
  ./configure.sh --yes 2>&1 | grep -v -E '^\s*(Admin password|[A-Za-z0-9]{20,}$)'
  rc="${PIPESTATUS[0]}"
  set -e
  [ "$rc" = 0 ] || fail "configure.sh failed (exit $rc); see the log above"
  cancelled || true
else
  clear_stock_images
  env_set ETHORA_TAG "$TARGET"; TAG_CHANGED=true
fi

# -------------------------------------------------------------------- pull --
step pull
if [ "$ACTION" = rollback ]; then
  missing=""
  for img in $(dc config --images 2>/dev/null | sort -u); do docker image inspect "$img" >/dev/null 2>&1 || missing="$missing $img"; done
  if [ -n "$missing" ]; then
    log "pulling missing images:$missing"
    for img in $missing; do docker pull "$img" 2>&1 || fail "cannot pull $img; see the log above"; done
  else log "every image is already on this server"; fi
else
  # The updater follows the release line, not ETHORA_TAG; a failure to pull it
  # keeps the one on this server and does not stop the update.
  services="$(dc config --services 2>/dev/null | grep -vx updater | tr '\n' ' ')"
  # shellcheck disable=SC2086
  dc pull $services 2>&1 || fail "docker compose pull failed (registry login? disk space?); see the log above"
  if dc config --services 2>/dev/null | grep -qx updater; then
    dc pull updater 2>&1 || log "warning: could not pull the updater image; keeping the one on this server"
  fi
fi
cancelled || true

# ----------------------------------------------------------------- waiting --
if [ "$AT_EPOCH" -gt "$(date +%s)" ]; then
  step waiting
  log "waiting until $NOT_BEFORE"
  while [ "$(date +%s)" -lt "$AT_EPOCH" ]; do cancelled || true; sleep 2; done
else
  skip waiting
fi
cancelled || true

# ----------------------------------------------------------------- restart --
step restart
# The images running now get their build number as a local tag (an install
# on the line tag has them only as :2610), so a rollback needs no download.
if [ -n "$FROM" ]; then
  for id in $(dc ps -q 2>/dev/null); do
    ref="$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null || true)"
    case "$ref" in
      docker.io/dappros/ethora-updater:*) ;;
      docker.io/dappros/ethora-*:*)
        repo="${ref%:*}"
        docker image inspect "$repo:$FROM" >/dev/null 2>&1 \
          || docker tag "$(docker inspect --format '{{.Image}}' "$id")" "$repo:$FROM" 2>/dev/null || true ;;
    esac
  done
fi
[ -z "$FROM" ] || [ "$FROM" = "$TARGET" ] || { echo "$FROM" > "$PREV_FILE"; }
TAG_CHANGED=false   # from here on the new tag stays: roll back instead
dc up -d 2>&1 || fail "docker compose up -d failed; see the log above (roll back from the admin panel or with ./update.sh --rollback)"

# ------------------------------------------------------------------- check --
step check
health() { local id; id="$(dc ps -q "$1" 2>/dev/null | head -1)"; [ -n "$id" ] && docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null; }
deadline=$(( $(date +%s) + CHECK_TIMEOUT ))
while :; do
  bad=""
  for s in api xmpp frontend; do h="$(health "$s" || true)"; case "$h" in healthy|running) ;; *) bad="$bad $s=${h:-missing}" ;; esac; done
  [ -n "$bad" ] || break
  [ "$(date +%s)" -lt "$deadline" ] || fail "not healthy after ${CHECK_TIMEOUT}s:$bad (docker compose ps, docker compose logs api)"
  sleep 5
done
now="$(running_build)"
[ -z "$now" ] || [ "$now" = "$TARGET" ] || fail "the API runs $now, expected $TARGET"
STEP_STATE[check]=done
STEP=done; STATE_NAME=succeeded; FINISHED="$(now_iso)"; write_state
log "done: $ACTION to $TARGET$([ -s "$PREV_FILE" ] && [ "$(cat "$PREV_FILE")" != "$TARGET" ] && echo " (roll back to $(cat "$PREV_FILE") with ./update.sh --rollback)")"
