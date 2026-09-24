#!/bin/bash
#
# run-migrations.sh - run the one-shot data migrations an install needs.
#
# Called by update.sh on every run, so an existing install picks up a new
# migration on its next update with no operator step. Also runnable by hand.
#
# Usage:
#   sudo bash deploy/scripts/run-migrations.sh              # run what is pending
#   sudo bash deploy/scripts/run-migrations.sh --dry-run    # report, write nothing
#   sudo bash deploy/scripts/run-migrations.sh --force      # re-run even if stamped
#   sudo bash deploy/scripts/run-migrations.sh --only <name>
#   sudo bash deploy/scripts/run-migrations.sh --list
#
# Contract for anything added to the registry below - all three matter, because
# this runs unattended on every update:
#
#   1. **Idempotent.** It will be run again. Re-running must be a no-op, not a
#      double-apply. Prefer `$set` to a recomputed value over `$inc`; match only
#      the rows that still need changing.
#   2. **Plain node, no ts-node.** Live in `services/api/scripts/`, not
#      `src/utils/` - those reach Mongo through `models/db/dbConnect`, which
#      requires the TS config and cannot load on a deployed host. Use the dotenv
#      + explicit `mongoose.connect(MONGO_URI)` bootstrap that
#      `migrateAppsToAgents.js` established.
#   3. **Forward-compatible with the code already running.** Services are
#      restarted before this point, so the new code is live while the migration
#      is still in flight. It must be correct both before and after - which in
#      practice means the app treats un-migrated rows as a valid state.
#
# A stamp under .deploy-state/migrations/ records what has run, so a normal
# update skips completed work. The stamps are an optimisation and an audit
# trail, not a correctness mechanism: every migration here is safe to re-run
# with --force, and safe to run against a database that has never seen it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$DEPLOY_DIR/.deploy.env"
STAMP_DIR="$DEPLOY_DIR/.deploy-state/migrations"

# ---------------------------------------------------------------------------
# Registry. One entry per migration, oldest first; they are run in this order.
# Format: <name>|<path relative to services/api>|<extra args>
#
# `name` is the stamp filename and what --only matches. Do not rename a shipped
# entry casually - the stamp is keyed on it, so a rename makes every existing
# install run the migration again.
#
# That is also the *mechanism* for re-running one deliberately. When a shipped
# migration turns out to have been wrong, bump a revision suffix (`-v2`, `-v3`)
# rather than asking operators to remember `--force`: the old stamp stops
# matching, every install re-runs it exactly once, and hosts that never saw the
# broken version are unaffected because the migration is idempotent either way.
# ---------------------------------------------------------------------------
MIGRATIONS=(
  # Per-Agent source ownership. Attributes site_sources / documentsources rows
  # that predate SiteSource.agentId to each App's default agent, then recomputes
  # Agent.totalSiteSourceSize from the rows. Also self-heals a counter that
  # drifted from a half-failed ingest or delete, which is why it stays in the
  # registry rather than being retired after one run.
  #
  # -v2: the first version resolved an App's agent only through
  # App.defaultBotInstanceId -> BotInstance.agentId. An install whose agents were
  # all created through the Agents UI has no BotInstances, so it attributed
  # nothing, reported 0 and stamped itself done - leaving the whole historical
  # Web Index unreachable. The resolver now falls back to Agent.ownerAppId; the
  # suffix is what makes already-stamped hosts pick that up.
  "source-agent-id-v2|scripts/migrateSourceAgentId.js|"
)

DRY_RUN=""
FORCE="false"
ONLY=""
LIST_ONLY="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    --force)   FORCE="true"; shift ;;
    --only)    ONLY="${2:-}"; shift 2 ;;
    --list)    LIST_ONLY="true"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "[ERROR] Unknown option: $1" >&2; exit 2 ;;
  esac
done

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
  echo "[ERROR] $1" >&2
  exit 1
}

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  error "Environment file not found: $ENV_FILE. Run install.sh first."
fi

[ -n "${ROOT_DIR:-}" ] || error "ROOT_DIR is not set in $ENV_FILE"
API_DIR="$ROOT_DIR/ethora-backend/services/api"
[ -d "$API_DIR" ] || error "API directory not found: $API_DIR"

if [ "$LIST_ONLY" = "true" ]; then
  log "Registered migrations (stamps in $STAMP_DIR):"
  for entry in "${MIGRATIONS[@]}"; do
    name="${entry%%|*}"
    if [ -f "$STAMP_DIR/$name" ]; then
      echo "  [done]    $name  ($(cat "$STAMP_DIR/$name" 2>/dev/null || echo 'no timestamp'))"
    else
      echo "  [pending] $name"
    fi
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# Mongo connection string. Same resolution order as migrate-ai-agents.sh:
#   1. MONGO_URI already exported by the operator.
#   2. MONGO_URI from the api package's own .env / .dev-env.
#   3. Assembled from .deploy.env, matching how backend.env.template builds it.
# ---------------------------------------------------------------------------
cd "$API_DIR"

if [ -z "${MONGO_URI:-}" ] && [ -f .env ]; then
  env_uri=$(grep -E '^MONGO_URI=' .env | head -n1 | cut -d= -f2- | tr -d '"' || true)
  [ -n "$env_uri" ] && export MONGO_URI="$env_uri"
fi
if [ -z "${MONGO_URI:-}" ] && [ -f .dev-env ]; then
  env_uri=$(grep -E '^MONGO_URI=' .dev-env | head -n1 | cut -d= -f2- | tr -d '"' || true)
  [ -n "$env_uri" ] && export MONGO_URI="$env_uri"
fi
if [ -z "${MONGO_URI:-}" ] && [ -n "${MONGO_PORT:-}" ] && [ -n "${MONGO_DB:-}" ]; then
  log "Constructing MONGO_URI from .deploy.env: localhost:${MONGO_PORT}/${MONGO_DB}"
  export MONGO_URI="mongodb://localhost:${MONGO_PORT}/${MONGO_DB}?directConnection=true"
fi
if [ -z "${MONGO_URI:-}" ]; then
  error "Could not resolve MONGO_URI. Set it in $API_DIR/.env, or set MONGO_PORT + MONGO_DB in $ENV_FILE."
fi

# Backend run mode: in image mode the migration scripts ship inside the API
# image (dist/scripts) and run there with the rendered .env; the host has no
# node, node_modules or source for the API.
BACKEND_MODE="${BACKEND_MODE:-source}"
if command -v yq >/dev/null 2>&1 && [ -f "${CANONICAL_DEPLOY_CONFIG_FILE:-$DEPLOY_DIR/config/deploy.yml}" ]; then
  _m="$(yq eval '.services.backend.mode // ""' "${CANONICAL_DEPLOY_CONFIG_FILE:-$DEPLOY_DIR/config/deploy.yml}" 2>/dev/null || true)"
  [ -n "$_m" ] && [ "$_m" != "null" ] && BACKEND_MODE="$_m"
  _i="$(yq eval '.services.backend.image // ""' "${CANONICAL_DEPLOY_CONFIG_FILE:-$DEPLOY_DIR/config/deploy.yml}" 2>/dev/null || true)"
  [ -n "$_i" ] && [ "$_i" != "null" ] && ETHORA_API_IMAGE="$_i"
fi

run_migration_script() { # <path relative to api dir> [args...]
  if [ "$BACKEND_MODE" = "image" ]; then
    [ -n "${ETHORA_API_IMAGE:-}" ] || error "services.backend.mode is image but services.backend.image is empty"
    local env_args=()
    [ -f "$API_DIR/.env" ] && env_args=(--env-file "$API_DIR/.env")
    docker run --rm --network host "${env_args[@]}" -e MONGO_URI="$MONGO_URI" \
      -e NODE_NO_WARNINGS=1 "$ETHORA_API_IMAGE" script "$@"
  else
    node "$@"
  fi
}

if [ "$BACKEND_MODE" != "image" ]; then
  command -v node >/dev/null 2>&1 || error "node not found on PATH."

  # The migrations import the api's mongoose models, so its node_modules has to be
  # there. update.sh has already built the backend by this point; this only fires
  # on a hand-run against a tree that was never built.
  if [ ! -d node_modules ]; then
    log "api node_modules missing; running npm install (this may take a minute)..."
    npm install --omit=dev || error "npm install failed in $API_DIR"
  fi
fi

mkdir -p "$STAMP_DIR"

# A --only that matches nothing would otherwise loop over every entry, skip them
# all and report "0 ran, 0 skipped" - indistinguishable from "already done".
# That bites exactly when it matters: a runbook naming a migration whose registry
# entry has since been revised (see the -v2 note above) reads as a clean run
# while doing nothing at all.
if [ -n "$ONLY" ]; then
  known="false"
  for entry in "${MIGRATIONS[@]}"; do
    [ "${entry%%|*}" = "$ONLY" ] && known="true"
  done
  if [ "$known" != "true" ]; then
    echo "[ERROR] --only '$ONLY' matches no registered migration. Registered:" >&2
    for entry in "${MIGRATIONS[@]}"; do echo "          ${entry%%|*}" >&2; done
    exit 2
  fi
fi

ran=0
skipped=0
failed=0

for entry in "${MIGRATIONS[@]}"; do
  IFS='|' read -r name rel_path extra_args <<<"$entry"

  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then
    continue
  fi

  if [ "$BACKEND_MODE" != "image" ] && [ ! -f "$API_DIR/$rel_path" ]; then
    # A migration registered by a newer deploy tree than the checked-out
    # backend. Not an error: the pointer bump that brings the script in will
    # bring the run with it.
    log "  [skip] $name - $rel_path not present in this backend checkout"
    skipped=$((skipped + 1))
    continue
  fi

  if [ -f "$STAMP_DIR/$name" ] && [ "$FORCE" != "true" ] && [ -z "$DRY_RUN" ]; then
    log "  [skip] $name - already applied ($(cat "$STAMP_DIR/$name" 2>/dev/null || echo '?'))"
    skipped=$((skipped + 1))
    continue
  fi

  log "  [run]  $name ($rel_path${DRY_RUN:+ $DRY_RUN})"
  # shellcheck disable=SC2086
  if run_migration_script "$rel_path" $extra_args $DRY_RUN 2>&1 | sed 's/^/         /'; then
    ran=$((ran + 1))
    if [ -z "$DRY_RUN" ]; then
      date -u +'%Y-%m-%dT%H:%M:%SZ' >"$STAMP_DIR/$name"
    fi
  else
    # Report every migration rather than stopping at the first failure: they are
    # independent, and an operator fixing one wants to know whether the rest are
    # also broken. No stamp is written, so a later run retries this one.
    echo "[ERROR] migration '$name' failed" >&2
    failed=$((failed + 1))
  fi
done

if [ -n "$DRY_RUN" ]; then
  log "Migrations (dry run): $ran would run, $skipped skipped, $failed failed"
else
  log "Migrations: $ran ran, $skipped skipped, $failed failed"
fi

[ "$failed" -eq 0 ] || exit 1
