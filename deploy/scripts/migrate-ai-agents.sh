#!/bin/bash
#
# migrate-ai-agents.sh - Phase 1 (Agents) one-shot migration helper.
#
# What it does:
#   1. Applies the Postgres `documents.agentId` column + index (idempotent).
#   2. Runs the Mongo migration (`scripts/migrateAppsToAgents.js`) which:
#        - For every existing App.aiBot.userId, creates an Agent + BotInstance
#          and sets App.defaultBotInstanceId.
#        - Backfills `documents.agentId` for legacy rows by joining xmppUsername.
#   3. Restarts the api + ai-service so the new schema, routes, multi-bot
#      manager and response gate are picked up.
#
# Usage (from QA server):
#   sudo bash deploy/scripts/migrate-ai-agents.sh           # run for real
#   sudo bash deploy/scripts/migrate-ai-agents.sh --dry-run # show what would change
#
# Requirements:
#   - Repo already installed via deploy/scripts/install.sh and update.sh.
#   - .deploy.env present (sourced for AI_PG_URL / paths / ROOT_DIR).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$DEPLOY_DIR/.deploy.env"
AI_COMPOSE_FILE="$DEPLOY_DIR/docker-compose.ai.yml"

DRY_RUN=""
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN="--dry-run"
fi

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
    error "Environment file not found: $ENV_FILE. Please run install.sh first."
fi

[ -n "${ROOT_DIR:-}" ] || error "ROOT_DIR is not set in $ENV_FILE"

API_DIR="$ROOT_DIR/ethora-backend/services/api"
AI_DIR="$ROOT_DIR/ethora-backend/services/ai/ai-service"

[ -d "$API_DIR" ] || error "API directory not found: $API_DIR"
[ -d "$AI_DIR" ] || error "ai-service directory not found: $AI_DIR"

# ----------------------------------------------------------------------------
# 1) Postgres: add documents.agentId column + index (idempotent).
# ----------------------------------------------------------------------------
log "Step 1/3: applying Postgres schema change (documents.agentId)..."

if [ "${AI_SERVICE_ENABLED:-false}" != "true" ]; then
    log "  AI service is disabled; skipping Postgres step."
else
    SQL_STMTS='ALTER TABLE "documents" ADD COLUMN IF NOT EXISTS "agentId" text;
CREATE INDEX IF NOT EXISTS "documents_agent_id_idx" ON "documents" ("agentId");'

    if [ -n "$DRY_RUN" ]; then
        log "  [DRY] Would execute against AI Postgres:"
        echo "$SQL_STMTS" | sed 's/^/         /'
    else
        # Pick the best available execution path:
        #   1. Managed AI Postgres in docker -> docker-compose exec into the service.
        #      This always works regardless of project-prefixed container name.
        #   2. Externally-managed AI Postgres -> host `psql` against AI_PG_URL.
        AI_PG_USER="${AI_POSTGRES_USER:-ai_embeddings}"
        AI_PG_DB="${AI_POSTGRES_DB:-ai_service_embeddings_db}"

        ran_via=""
        if [ "${AI_POSTGRES_MANAGED:-false}" = "true" ] && [ -f "$AI_COMPOSE_FILE" ]; then
            # Pick docker-compose v1 binary or v2 plugin, matching setup-ai-postgres.sh's convention.
            if command -v docker-compose >/dev/null 2>&1; then
                DC="docker-compose"
            elif docker compose version >/dev/null 2>&1; then
                DC="docker compose"
            else
                DC=""
            fi

            if [ -n "$DC" ]; then
                log "  Using $DC exec into managed ai-postgres service (user=$AI_PG_USER db=$AI_PG_DB)..."
                # -T: disable TTY so heredoc input piped in correctly through compose exec.
                printf '%s\n' "$SQL_STMTS" | $DC -f "$AI_COMPOSE_FILE" exec -T ai-postgres \
                    psql -U "$AI_PG_USER" -d "$AI_PG_DB" -v ON_ERROR_STOP=1
                ran_via="compose-exec"
            fi
        fi

        if [ -z "$ran_via" ]; then
            PG_TARGET_URL="${AI_PG_URL:-${PG_URL:-}}"
            if [ -z "$PG_TARGET_URL" ]; then
                error "AI Postgres is not in managed-docker mode and AI_PG_URL is empty. Set AI_PG_URL in $ENV_FILE."
            fi
            if ! command -v psql >/dev/null 2>&1; then
                error "Need 'psql' on the host to talk to externally-managed AI Postgres. Install postgresql-client and re-run."
            fi
            log "  Using host psql against externally-managed AI Postgres..."
            printf '%s\n' "$SQL_STMTS" | psql "$PG_TARGET_URL" -v ON_ERROR_STOP=1
            ran_via="host-psql"
        fi
        log "  Postgres schema change applied via $ran_via."
    fi
fi

# ----------------------------------------------------------------------------
# 2) Mongo: seed Agents + BotInstances for existing apps; backfill documents.agentId.
# ----------------------------------------------------------------------------
log "Step 2/3: running Mongo migration (Agents + BotInstances seeding + documents.agentId backfill)..."

cd "$API_DIR"

# Resolve a MONGO_URI for the migration script.
# Priority:
#   1. MONGO_URI already in env (e.g. exported by the operator).
#   2. MONGO_URI loaded from the api package's own .env / .dev-env (if present).
#   3. Construct one from .deploy.env (MONGO_PORT + MONGO_DB), matching how
#      backend.env.template assembles it.
if [ -z "${MONGO_URI:-}" ]; then
    if [ -f .env ]; then
        env_uri=$(grep -E '^MONGO_URI=' .env | head -n1 | cut -d= -f2- | tr -d '"' || true)
        [ -n "$env_uri" ] && export MONGO_URI="$env_uri"
    fi
fi
if [ -z "${MONGO_URI:-}" ] && [ -f .dev-env ]; then
    env_uri=$(grep -E '^MONGO_URI=' .dev-env | head -n1 | cut -d= -f2- | tr -d '"' || true)
    [ -n "$env_uri" ] && export MONGO_URI="$env_uri"
fi
if [ -z "${MONGO_URI:-}" ] && [ -n "${MONGO_PORT:-}" ] && [ -n "${MONGO_DB:-}" ]; then
    log "  Constructing MONGO_URI from .deploy.env: localhost:${MONGO_PORT}/${MONGO_DB}"
    export MONGO_URI="mongodb://localhost:${MONGO_PORT}/${MONGO_DB}?directConnection=true"
fi
if [ -z "${MONGO_URI:-}" ]; then
    error "Could not resolve MONGO_URI. Set it in $API_DIR/.env or set MONGO_PORT + MONGO_DB in $ENV_FILE."
fi

# Resolve a PG_URL for the documents.agentId backfill in the same script. AI_PG_URL is
# what .deploy.env carries, but it points to the docker network alias 'ai-postgres' which
# is not reachable from the host. Rewrite to localhost + the published AI_POSTGRES_PORT
# (default 5434, see docker-compose.ai.yml). If the operator set AI_PG_URL to an
# externally-managed instance, leave it alone.
if [ -z "${PG_URL:-}" ]; then
    if [ "${AI_POSTGRES_MANAGED:-false}" = "true" ]; then
        AI_PG_USER="${AI_POSTGRES_USER:-ai_embeddings}"
        AI_PG_DB="${AI_POSTGRES_DB:-ai_service_embeddings_db}"
        AI_PG_HOST_PORT="${AI_POSTGRES_PORT:-5434}"
        if [ -n "${AI_POSTGRES_PASSWORD:-}" ]; then
            export PG_URL="postgres://${AI_PG_USER}:${AI_POSTGRES_PASSWORD}@127.0.0.1:${AI_PG_HOST_PORT}/${AI_PG_DB}"
        fi
    elif [ -n "${AI_PG_URL:-}" ]; then
        export PG_URL="$AI_PG_URL"
    fi
fi
# If we still don't have a usable PG_URL, hint the user but don't fail - the backfill
# step in migrateAppsToAgents.js handles the missing-pg case gracefully (--skip-pg).
if [ -z "${PG_URL:-}" ]; then
    log "  PG_URL not resolved; the script will skip Postgres backfill of documents.agentId."
fi

if ! command -v node >/dev/null 2>&1; then
    error "node not found on PATH. Cannot run migrateAppsToAgents.js."
fi

# We need the api package's node_modules for ethers, mongoose, etc. Skip install if already present.
if [ ! -d node_modules ]; then
    log "  api node_modules missing; running npm install (this may take a minute)..."
    npm install --omit=dev || error "npm install failed in $API_DIR"
fi

# Tell the JS migration script where to drop its (appId, agentId) pairs so we can
# apply them via docker-compose exec psql in step 2b below.
PAIRS_FILE="$(mktemp /tmp/ethora-agents-pg-backfill.XXXXXX.tsv)"
export PG_BACKFILL_PAIRS_FILE="$PAIRS_FILE"

if [ -n "$DRY_RUN" ]; then
    node scripts/migrateAppsToAgents.js --dry-run
else
    node scripts/migrateAppsToAgents.js
fi

# Step 2b: apply the (appId, agentId) pairs to documents via docker-compose exec psql.
# The api package doesn't ship `pg`, so the JS script writes the pairs to PAIRS_FILE
# instead of running the UPDATEs directly. We loop here using the exact same
# docker-compose path that step 1 used (so it works whether pg is installed or not).
if [ -z "$DRY_RUN" ] && [ -s "$PAIRS_FILE" ] && [ "${AI_POSTGRES_MANAGED:-false}" = "true" ]; then
    log "  Step 2b/3: backfilling documents.agentId from $PAIRS_FILE..."
    AI_PG_USER="${AI_POSTGRES_USER:-ai_embeddings}"
    AI_PG_DB="${AI_POSTGRES_DB:-ai_service_embeddings_db}"
    if command -v docker-compose >/dev/null 2>&1; then
        DC="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        DC="docker compose"
    else
        DC=""
    fi
    if [ -n "$DC" ]; then
        total_updated=0
        # The pairs file has one "appId<TAB>agentId" per line.
        while IFS=$'\t' read -r appId agentId; do
            [ -z "$appId" ] && continue
            updated=$($DC -f "$AI_COMPOSE_FILE" exec -T ai-postgres \
                psql -U "$AI_PG_USER" -d "$AI_PG_DB" -At -v ON_ERROR_STOP=1 \
                -c "UPDATE \"documents\" SET \"agentId\"='$agentId' WHERE \"appId\"='$appId' AND (\"agentId\" IS NULL OR \"agentId\" = '') RETURNING 1;" \
                2>/dev/null | wc -l || true)
            if [ "${updated:-0}" -gt 0 ]; then
                log "    appId=$appId -> agentId=$agentId : updated $updated row(s)"
                total_updated=$((total_updated + updated))
            fi
        done < "$PAIRS_FILE"
        log "  Backfill done. Total rows updated: $total_updated"
    else
        log "  Neither docker-compose nor 'docker compose' available; pairs left in $PAIRS_FILE for manual application."
    fi
fi
rm -f "$PAIRS_FILE" 2>/dev/null || true

# ----------------------------------------------------------------------------
# 3) Restart services (skipped on --dry-run).
# ----------------------------------------------------------------------------
if [ -n "$DRY_RUN" ]; then
    log "Step 3/3: --dry-run; not restarting services."
    log "Done (dry run). Re-run without --dry-run to apply."
    exit 0
fi

log "Step 3/3: restarting api + ai-service so the new code path picks up..."

if command -v pm2 >/dev/null 2>&1; then
    pm2 restart api 2>/dev/null || log "  pm2 'api' not running; skipping."
    pm2 restart ai-service 2>/dev/null || log "  pm2 'ai-service' not running; skipping."
elif [ -x "$SCRIPT_DIR/setup-node-services.sh" ]; then
    log "  pm2 not on PATH; falling back to setup-node-services.sh restart."
    bash "$SCRIPT_DIR/setup-node-services.sh" restart || log "  Restart fallback returned non-zero; review output above."
else
    log "  No pm2 or known service manager found; restart api + ai-service manually."
fi

log "Done. Phase 1 (Agents) migration complete."
log ""
log "Verify with:"
log "  - GET /v2/agents                  (should return [] for fresh installs)"
log "  - GET /v2/bot-instances           (should list one per existing app.aiBot)"
log "  - psql ... 'SELECT COUNT(*) FROM documents WHERE \"agentId\" IS NULL'"
log "      should be 0 if backfill completed for every legacy row whose app had a default bot."
