#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$DEPLOY_DIR/.deploy.env"
AI_COMPOSE_FILE="$DEPLOY_DIR/docker-compose.ai.yml"

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

if [ "${AI_SERVICE_ENABLED:-false}" != "true" ]; then
    log "AI service is disabled; skipping AI Postgres provisioning."
    exit 0
fi

if [ "${AI_POSTGRES_MANAGED:-false}" != "true" ]; then
    if [ -z "${AI_PG_URL:-}" ]; then
        error "AI_PG_URL is empty. Set services.ai_service.pg_url in deploy.yml or use the managed AI Postgres defaults."
    fi
    log "Using externally managed AI Postgres; skipping local Docker provisioning."
    exit 0
fi

[ -f "$AI_COMPOSE_FILE" ] || error "Missing AI compose file: $AI_COMPOSE_FILE"
[ -n "${ROOT_DIR:-}" ] || error "ROOT_DIR is not set in $ENV_FILE"

cd "$ROOT_DIR"

log "Starting managed AI Postgres..."
docker-compose -f "$AI_COMPOSE_FILE" up -d || error "Failed to start managed AI Postgres"

# Readiness gate.
#
# pg_isready on its own is not a sufficient signal, for two reasons:
#
#  1. It answers "is the postmaster accepting connections", not "can this
#     deploy run the statements it is about to run". On first boot the
#     postgres entrypoint starts a TEMPORARY server to create the database
#     before restarting into the real one, and pg_isready reports that
#     temporary server as ready. The restart that follows is the window the
#     schema step used to fail in.
#  2. It says nothing about the `vector` extension, which the very first
#     statement of the schema file needs.
#
# So probe with a real query, over the same psql path the schema uses, and
# ask the one question that actually matters: can we connect, authenticate,
# reach the target database, and is pgvector available to CREATE EXTENSION.
#
# Two consecutive successes are required. A single probe can land inside the
# temporary-server window and pass; a second probe a couple of seconds later
# will not, because the restart breaks the streak.
pg_can_serve_schema() {
    local out
    out="$(docker-compose -f "$AI_COMPOSE_FILE" exec -T ai-postgres \
        psql -v ON_ERROR_STOP=1 \
            -U "${AI_POSTGRES_USER}" \
            -d "${AI_POSTGRES_DB}" \
            -tAc "SELECT count(*) FROM pg_available_extensions WHERE name = 'vector'" \
        2>/dev/null)" || return 1
    # docker-compose exec can append CR; strip all whitespace before comparing.
    out="$(printf '%s' "$out" | tr -d '[:space:]')"
    [ "$out" = "1" ]
}

retries=30
delay=2
attempt=1
ready=false
streak=0
required_streak=2
while [ "$attempt" -le "$retries" ]; do
    if pg_can_serve_schema; then
        streak=$((streak + 1))
        if [ "$streak" -ge "$required_streak" ]; then
            log "Managed AI Postgres is ready (attempt $attempt/$retries)"
            ready=true
            break
        fi
    else
        # Reset rather than decrement: we want two clean probes in a row, not
        # two successes with a failure between them.
        streak=0
    fi
    sleep "$delay"
    attempt=$((attempt + 1))
done

if [ "$ready" != "true" ]; then
    docker-compose -f "$AI_COMPOSE_FILE" ps || true
    docker-compose -f "$AI_COMPOSE_FILE" logs --tail 200 ai-postgres || true
    error "Managed AI Postgres failed to become ready"
fi

# Apply (idempotent) schema baseline + any new columns / indexes from
# deploy/sql/ai-postgres-schema.sql. This closes the loop on "code-side
# schema.ts changed but production Postgres never picked up the new
# column" - the column adds live in the SQL file, are applied on every
# update.sh run, and use ADD COLUMN / CREATE INDEX IF NOT EXISTS so prior
# runs don't fight new ones.
#
# Failures here are fatal: if we can't apply the schema, ai-service will
# crash on first query with "column does not exist" anyway, so better
# to fail the deploy now with a clean error than to have ai-service
# flap in production.
SCHEMA_SQL="$DEPLOY_DIR/sql/ai-postgres-schema.sql"
if [ -f "$SCHEMA_SQL" ]; then
    log "Applying AI Postgres schema baseline ($SCHEMA_SQL)..."
    if ! docker-compose -f "$AI_COMPOSE_FILE" exec -T ai-postgres \
            psql -v ON_ERROR_STOP=1 \
                -U "${AI_POSTGRES_USER}" \
                -d "${AI_POSTGRES_DB}" \
            <"$SCHEMA_SQL" >/dev/null 2>&1; then
        # The first attempt can fail transiently: pg_isready above reports the
        # container ready slightly before Postgres can actually serve queries
        # (loading the `vector` extension takes a moment longer). Give it a
        # beat, then re-run with output visible so the operator sees the
        # failing statement instead of a bare exit code.
        #
        # Only the SECOND attempt decides the outcome. This used to call
        # error() unconditionally, so a transient first failure aborted the
        # whole install even when the retry printed a fully successful run.
        sleep 3
        if ! docker-compose -f "$AI_COMPOSE_FILE" exec -T ai-postgres \
                psql -v ON_ERROR_STOP=1 \
                    -U "${AI_POSTGRES_USER}" \
                    -d "${AI_POSTGRES_DB}" \
                <"$SCHEMA_SQL"; then
            error "Failed to apply AI Postgres schema from $SCHEMA_SQL"
        fi
        log "AI Postgres schema applied (first attempt failed transiently, retry succeeded)."
    else
        log "AI Postgres schema applied."
    fi
else
    log "WARNING: schema SQL not found at $SCHEMA_SQL; skipping (ai-service may crash on first query if columns are missing)."
fi

exit 0
