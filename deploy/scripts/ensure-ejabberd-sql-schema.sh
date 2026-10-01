#!/usr/bin/env bash
# Ethora.com platform, copyright: Dappros Ltd (c) 2026, all rights reserved
#
# ensure-ejabberd-sql-schema.sh - widen the MUC index prefixes in ejabberd's
# MySQL schema on an existing install.
#
# The stock ejabberd schema keys muc_room (and the other MUC tables) on the
# first 75 characters of the room name / JID. An Ethora 1:1 room is named
# app_user1-app_user2, 99 characters, and the id of the second user starts at
# character 76: to MySQL every 1:1 room of the same first member was the same
# room, ejabberd could persist only one of them and the rest vanished at the
# next restart. ejabberd-docker/docker/mysql2.sql carries the wider prefixes for
# new installs; this script brings an existing database to the same state.
#
# Idempotent: reads information_schema and alters only an index that is still
# at the old width. The ALTER runs online (InnoDB, MySQL 8), ejabberd keeps
# running. Called by update.sh and install.sh after the docker services are
# up; safe to run by hand:
#
#   sudo bash deploy/scripts/ensure-ejabberd-sql-schema.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.enterprise.yml"
DB="${EJABBERD_SQL_DATABASE:-ejabberd_db}"
WIDTH=191
DRY_RUN="false"
[ "${1:-}" = "--dry-run" ] && DRY_RUN="true"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ejabberd-schema] $*"; }
warn() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ejabberd-schema] [WARN] $*" >&2; }

compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

# Run SQL (stdin) against the ejabberd database inside the mysql container.
sql() {
  compose -f "$COMPOSE_FILE" exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B "$0"' "$DB" 2>/dev/null
}

[ -f "$COMPOSE_FILE" ] || { warn "no $COMPOSE_FILE; nothing to do"; exit 0; }
if ! compose -f "$COMPOSE_FILE" ps --status running mysql 2>/dev/null | grep -q mysql; then
  warn "mysql container is not running; skipping (the next update retries)"
  exit 0
fi

# Fresh installs initialise the schema from mysql2.sql on first start; give
# that a moment rather than failing the install on a race.
for _ in $(seq 1 30); do
  if printf 'SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA=%s AND TABLE_NAME=%s;\n' "'$DB'" "'muc_room'" | sql | grep -q 1; then
    break
  fi
  sleep 2
done
if ! printf 'SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA=%s AND TABLE_NAME=%s;\n' "'$DB'" "'muc_room'" | sql | grep -q 1; then
  warn "table $DB.muc_room not found; ejabberd schema not initialised yet, skipping"
  exit 0
fi

# table|index|column checked|index definition with the wider prefix
INDEXES=(
  "muc_room|i_muc_room_name_host|name|UNIQUE INDEX i_muc_room_name_host (name($WIDTH), host(75))"
  "muc_online_room|i_muc_online_room_name_host|name|UNIQUE INDEX i_muc_online_room_name_host (name($WIDTH), host(75))"
  "muc_online_users|i_muc_online_users|name|UNIQUE INDEX i_muc_online_users (username(75), server(75), resource(75), name($WIDTH), host(75))"
  "muc_registered|i_muc_registered_jid_host|jid|UNIQUE INDEX i_muc_registered_jid_host (jid($WIDTH), host(75))"
)

changed=0
failed=0
for entry in "${INDEXES[@]}"; do
  IFS='|' read -r table index column definition <<<"$entry"
  current="$(printf "SELECT SUB_PART FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='%s' AND TABLE_NAME='%s' AND INDEX_NAME='%s' AND COLUMN_NAME='%s';\n" "$DB" "$table" "$index" "$column" | sql | head -n1 | tr -d '[:space:]')"
  if [ -z "$current" ]; then
    warn "$table.$index not found; leaving the table as it is"
    continue
  fi
  if [ "$current" = "NULL" ] || [ "$current" -ge "$WIDTH" ] 2>/dev/null; then
    continue
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "would widen $table.$index ($column prefix $current -> $WIDTH)"
    changed=$((changed + 1))
    continue
  fi
  log "widening $table.$index ($column prefix $current -> $WIDTH)..."
  stmt="ALTER TABLE $table DROP INDEX $index, ADD $definition"
  if printf '%s, ALGORITHM=INPLACE, LOCK=NONE;\n' "$stmt" | sql; then
    changed=$((changed + 1))
  elif printf '%s;\n' "$stmt" | sql; then
    log "$table.$index widened (the online variant was refused; a short table lock was taken instead)"
    changed=$((changed + 1))
  else
    warn "ALTER TABLE $table failed"
    failed=$((failed + 1))
  fi
done

if [ "$DRY_RUN" = "true" ]; then
  log "dry run: $changed index(es) would change"
else
  log "$changed index(es) changed, $failed failed"
fi
[ "$failed" -eq 0 ]
