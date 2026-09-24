#!/bin/bash

# Export the stateful databases needed for a full Ethora migration pack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_ENV_FILE="$DEPLOY_DIR/.deploy.env"
ENTERPRISE_COMPOSE_FILE="$DEPLOY_DIR/docker-compose.enterprise.yml"
AI_COMPOSE_FILE="$DEPLOY_DIR/docker-compose.ai.yml"

OUTPUT_DIR=""
EXPORT_LABEL="stateful-export"
SKIP_AI_POSTGRES=false

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./scripts/export-stateful-snapshots.sh \
    [--output-dir /custom/output/dir] \
    [--label export-name] \
    [--skip-ai-postgres]

What it does:
  - loads deploy/.deploy.env from a running install checkout
  - exports MongoDB as a .archive snapshot
  - exports Ejabberd MySQL as ejabberd_db.sql
  - exports AI Postgres / pgvector as a custom-format .dump when enabled
  - writes export-manifest.env with the generated file paths

Notes:
  - this helper is intended for a live monoserver-managed install checkout
  - use prepare-stateful-migration.sh afterwards to generate the rewrite pack
EOF
}

require_cmd() {
    local name="$1"
    command -v "$name" >/dev/null 2>&1 || error "Required command not found: $name"
}

timestamp_utc() {
    date -u +'%Y%m%dT%H%M%SZ'
}

resolve_docker_compose() {
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD=(docker-compose)
        return
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD=(docker compose)
        return
    fi

    error "docker-compose or 'docker compose' is required"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --label)
            EXPORT_LABEL="${2:-}"
            shift 2
            ;;
        --skip-ai-postgres)
            SKIP_AI_POSTGRES=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done

require_cmd docker
resolve_docker_compose

[ -f "$DEPLOY_ENV_FILE" ] || error "Missing deploy env: $DEPLOY_ENV_FILE. Run install/update first."
[ -f "$ENTERPRISE_COMPOSE_FILE" ] || error "Missing compose file: $ENTERPRISE_COMPOSE_FILE"

set -a
# shellcheck disable=SC1090
source "$DEPLOY_ENV_FILE"
set +a

[ -n "${MONGO_DB:-}" ] || error "MONGO_DB is missing in $DEPLOY_ENV_FILE"
[ -n "${MYSQL_ROOT_PASSWORD:-}" ] || error "MYSQL_ROOT_PASSWORD is missing in $DEPLOY_ENV_FILE"

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$DEPLOY_DIR/generated/stateful-exports/${EXPORT_LABEL}-$(timestamp_utc)"
fi

mkdir -p "$OUTPUT_DIR"

MONGO_ARCHIVE_FILE="$OUTPUT_DIR/mongo.archive"
EJABBERD_SQL_FILE="$OUTPUT_DIR/ejabberd_db.sql"
AI_POSTGRES_DUMP_FILE="$OUTPUT_DIR/ai_service_embeddings.dump"
MANIFEST_FILE="$OUTPUT_DIR/export-manifest.env"

log "Exporting MongoDB archive to $MONGO_ARCHIVE_FILE"
"${DOCKER_COMPOSE_CMD[@]}" -f "$ENTERPRISE_COMPOSE_FILE" exec -T mongo \
    mongodump --db "${MONGO_DB}" --archive > "$MONGO_ARCHIVE_FILE"

log "Exporting Ejabberd MySQL dump to $EJABBERD_SQL_FILE"
"${DOCKER_COMPOSE_CMD[@]}" -f "$ENTERPRISE_COMPOSE_FILE" exec -T mysql \
    mysqldump -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    --single-transaction --quick --skip-lock-tables \
    ejabberd_db > "$EJABBERD_SQL_FILE"

AI_EXPORT_MODE="skipped"
AI_POSTGRES_INCLUDED="false"
AI_POSTGRES_DUMP_PATH=""

if [ "$SKIP_AI_POSTGRES" = true ]; then
    log "Skipping AI Postgres export because --skip-ai-postgres was requested."
elif [ "${AI_SERVICE_ENABLED:-false}" != "true" ]; then
    log "AI service is disabled in .deploy.env; skipping AI Postgres export."
elif [ "${AI_POSTGRES_MANAGED:-false}" = "true" ] && [ -f "$AI_COMPOSE_FILE" ]; then
    [ -n "${AI_POSTGRES_USER:-}" ] || error "AI_POSTGRES_USER is missing in $DEPLOY_ENV_FILE"
    [ -n "${AI_POSTGRES_DB:-}" ] || error "AI_POSTGRES_DB is missing in $DEPLOY_ENV_FILE"
    log "Exporting managed AI Postgres dump to $AI_POSTGRES_DUMP_FILE"
    "${DOCKER_COMPOSE_CMD[@]}" -f "$AI_COMPOSE_FILE" exec -T ai-postgres \
        pg_dump -U "${AI_POSTGRES_USER}" -d "${AI_POSTGRES_DB}" -Fc > "$AI_POSTGRES_DUMP_FILE"
    AI_EXPORT_MODE="managed"
    AI_POSTGRES_INCLUDED="true"
    AI_POSTGRES_DUMP_PATH="$AI_POSTGRES_DUMP_FILE"
elif [ -n "${AI_PG_URL:-}" ]; then
    require_cmd pg_dump
    log "Exporting external AI Postgres dump to $AI_POSTGRES_DUMP_FILE"
    pg_dump "${AI_PG_URL}" -Fc -f "$AI_POSTGRES_DUMP_FILE"
    AI_EXPORT_MODE="external"
    AI_POSTGRES_INCLUDED="true"
    AI_POSTGRES_DUMP_PATH="$AI_POSTGRES_DUMP_FILE"
else
    log "AI Postgres is not configured; skipping AI Postgres export."
fi

cat > "$MANIFEST_FILE" <<EOF
GENERATED_AT="$(date -u +'%Y-%m-%d %H:%M:%SZ')"
MONGO_ARCHIVE="$MONGO_ARCHIVE_FILE"
EJABBERD_SQL="$EJABBERD_SQL_FILE"
AI_POSTGRES_INCLUDED="$AI_POSTGRES_INCLUDED"
AI_POSTGRES_EXPORT_MODE="$AI_EXPORT_MODE"
AI_POSTGRES_DUMP="$AI_POSTGRES_DUMP_PATH"
EOF

log "Export complete:"
log "  $MONGO_ARCHIVE_FILE"
log "  $EJABBERD_SQL_FILE"
if [ "$AI_POSTGRES_INCLUDED" = "true" ]; then
    log "  $AI_POSTGRES_DUMP_FILE"
fi
log "  $MANIFEST_FILE"
