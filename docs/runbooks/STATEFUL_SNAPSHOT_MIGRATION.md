# Stateful Snapshot Migration

Restoring a MongoDB archive plus an ejabberd MySQL dump into a newer deploy target (QA rehearsals, staging clones).

For QA/staging rehearsals where you restore an existing MongoDB archive plus an Ejabberd MySQL dump into a newer deploy target, use the helper below to prepare a migration pack before import:

```bash
cd deploy
./scripts/prepare-stateful-migration.sh \
  --mongo-archive /path/to/dev_YYYYMMDDTHHMMSSZ.archive \
  --ejabberd-sql /path/to/ejabberd_db.sql
```

Prerequisites and input expectations:

- `binutils` must be installed because the helper uses `strings` to inspect MongoDB archives.
- The Ejabberd dump must be a plain text `.sql` file, not a compressed `.sql.gz`. Decompress first if needed.
- The helper reads target domains from `deploy/config/deploy.yml`, but you can override them per run when rehearsing a different target.

This generates a timestamped directory under `deploy/generated/stateful-migration/` containing:

- `migration-plan.md` - what should be rewritten vs left historical
- `migration-map.env` - target domain map derived from `deploy.yml`
- `mongo-post-restore.js` - run after `mongorestore`
- `ejabberd-post-import.sql` - run after importing `ejabberd_db.sql`
- `ejabberd-cleanup.sql` - optional cleanup helpers for QA clones
- optional AI Postgres restore guidance when you pass `--ai-postgres-dump`

If the source environment is already a monoserver-managed install, export all stateful snapshots first:

```bash
cd deploy
./scripts/export-stateful-snapshots.sh
```

That creates a timestamped directory under `deploy/generated/stateful-exports/` containing:

- `mongo.archive`
- `ejabberd_db.sql`
- `ai_service_embeddings.dump` when AI Postgres is enabled
- `export-manifest.env`

If you want an already-rewritten SQL dump copy for Ejabberd as part of the same step:

```bash
./scripts/prepare-stateful-migration.sh \
  --mongo-archive /path/to/dev_YYYYMMDDTHHMMSSZ.archive \
  --ejabberd-sql /path/to/ejabberd_db.sql \
  --rewrite-ejabberd-dump
```

Important behavior:

- The helper does not modify the source snapshots.
- MongoDB archives are treated as restore-first, rewrite-second; the generated `mongosh` script updates restored documents in place.
- Historical marketing/RAG URLs are not rewritten by default; only clear-cut runtime endpoints are targeted automatically.
- The generated Mongo rewrite covers common runtime fields, including app logos/backgrounds, Firebase config blobs, assistant prompts, default room JIDs, chat pictures, user profile images, file/chat media locations, selected token NFT URLs, and document locations.
- If your local `deploy.yml` does not yet match the target environment, pass explicit overrides such as `--api-domain`, `--web-domain`, `--xmpp-domain`, `--files-domain`, and `--hosted-apps-root`.
- Admin and chat-state repair is opt-in. Use explicit flags when you want to retain a legacy super-admin, promote a new admin user, or backfill default room memberships after restore.

Useful optional flags:

- `--retain-legacy-super-admin <email>` keeps a known restored user as `isSuperAdmin` and repairs that user's app ACL/default-room memberships. Repeatable.
- `--promote-super-admin <email>` promotes an existing restored user into a super-admin and repairs that user's app ACL/default-room memberships. Repeatable.
- `--backfill-default-room-memberships` re-applies app `defaultRooms` membership links into `user_to_chats` for restored users.
- `--widget-domain <host>` overrides the widget host used when rewriting stored assistant embed URLs.
- `--ai-postgres-dump <path>` records the AI pgvector dump path in the generated migration plan and pack metadata.

## Reusable QA Restore Runbook

Use this runbook when you want to restore production-like MongoDB and Ejabberd snapshots into a QA environment running the current deploy stack.

Example target domains:

- `app.chat.example.com`
- `api.chat.example.com`
- `xmpp.chat.example.com`
- `files.chat.example.com`
- `chat.example.com`

This flow has two phases:

1. Generate a migration pack from a source checkout of `ethora-monoserver`.
2. Restore and apply it on the QA server from the install checkout that runs the stack.

## Phase 1: Generate and Upload the Migration Pack

Run this on the operator workstation where the source snapshots are available:

```bash
set -euo pipefail

QA_SSH_HOST="ubuntu@qa-server.example.com"
SSH_KEY="$HOME/.ssh/id_rsa"

MONO_REPO="$HOME/ethora-monoserver"
EXPORT_DIR="/path/to/stateful-export"
MONGO_ARCHIVE="$EXPORT_DIR/mongo.archive"
EJABBERD_SQL="$EXPORT_DIR/ejabberd_db.sql"
AI_POSTGRES_DUMP="$EXPORT_DIR/ai_service_embeddings.dump"

cd "$MONO_REPO"
git checkout main
git pull --ff-only origin main
git submodule update --init --recursive

cd deploy
PACK_DIR="$PWD/generated/stateful-migration/chat-example-$(date -u +%Y%m%dT%H%M%SZ)"

PREPARE_ARGS=(
  --mongo-archive "$MONGO_ARCHIVE"
  --ejabberd-sql "$EJABBERD_SQL"
  --output-dir "$PACK_DIR"
  --api-domain api.chat.example.com
  --web-domain app.chat.example.com
  --xmpp-domain xmpp.chat.example.com
  --files-domain files.chat.example.com
  --hosted-apps-root chat.example.com
  --base-app-domain-name app
  --retain-legacy-super-admin legacy-admin@example.com
  --promote-super-admin admin@example.com
  --backfill-default-room-memberships
  --rewrite-ejabberd-dump
)

if [ -f "$AI_POSTGRES_DUMP" ]; then
  PREPARE_ARGS+=(--ai-postgres-dump "$AI_POSTGRES_DUMP")
fi

./scripts/prepare-stateful-migration.sh "${PREPARE_ARGS[@]}"

tar -C "$(dirname "$PACK_DIR")" -czf "${PACK_DIR}.tar.gz" "$(basename "$PACK_DIR")"

ssh -i "$SSH_KEY" "$QA_SSH_HOST" 'mkdir -p ~/stateful-migration'
TRANSFER_FILES=(
  "$MONGO_ARCHIVE"
  "$EJABBERD_SQL"
  "${PACK_DIR}.tar.gz"
)

if [ -f "$AI_POSTGRES_DUMP" ]; then
  TRANSFER_FILES+=("$AI_POSTGRES_DUMP")
fi

scp -i "$SSH_KEY" "${TRANSFER_FILES[@]}" "$QA_SSH_HOST:~/stateful-migration/"
```

If the source stack is already running the monoserver deploy flow, you can generate `EXPORT_DIR` first with:

```bash
cd /path/to/source-install/deploy
./scripts/export-stateful-snapshots.sh --output-dir "$PWD/generated/stateful-exports/prod-$(date -u +%Y%m%dT%H%M%SZ)"
```

## Phase 2: Restore on the QA Server

Run this on the QA server:

```bash
set -euo pipefail

cd ~/ethora-install-shared
git checkout main
git pull --ff-only origin main
git submodule update --init --recursive

cd ~/stateful-migration
MONGO_FILE="$(ls -1 *.archive | head -n 1)"
MYSQL_FILE="$(ls -1 *.sql | rg 'ejabberd' | head -n 1)"
AI_PG_DUMP_FILE="$(ls -1 *.dump 2>/dev/null | head -n 1 || true)"
PACK_TGZ="$(ls -1t chat-example-*.tar.gz | head -n 1)"
tar -xzf "$PACK_TGZ"
PACK_DIR="$HOME/stateful-migration/${PACK_TGZ%.tar.gz}"
RESTORE_SQL="$HOME/stateful-migration/$MYSQL_FILE"
if [ -f "$PACK_DIR/ejabberd_db.rewritten.sql" ]; then
  RESTORE_SQL="$PACK_DIR/ejabberd_db.rewritten.sql"
fi

cd ~/ethora-install-shared/deploy
sudo ./scripts/install.sh --reset

source .deploy.env

cat "$HOME/stateful-migration/$MONGO_FILE" | \
  docker-compose -f docker-compose.enterprise.yml exec -T mongo \
  mongorestore --archive --drop

docker-compose -f docker-compose.enterprise.yml exec -T mongo \
  mongosh --quiet "$MONGO_DB" < "$PACK_DIR/mongo-post-restore.js"

docker-compose -f docker-compose.enterprise.yml exec -T mysql \
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" ejabberd_db < "$RESTORE_SQL"

docker-compose -f docker-compose.enterprise.yml exec -T mysql \
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" ejabberd_db < "$PACK_DIR/ejabberd-post-import.sql"

if [ -n "$AI_PG_DUMP_FILE" ]; then
  [ -n "${AI_PG_URL:-}" ] || { echo "AI_PG_URL is not set in .deploy.env"; exit 1; }
  pg_restore -d "$AI_PG_URL" --clean --if-exists --no-owner --no-acl \
    "$HOME/stateful-migration/$AI_PG_DUMP_FILE"
fi

docker-compose -f docker-compose.enterprise.yml exec -T mysql \
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" ejabberd_db <<'SQL'
SET @needs_type := (
  SELECT COUNT(*)
  FROM information_schema.columns
  WHERE table_schema = 'ejabberd_db'
    AND table_name = 'users'
    AND column_name = 'type'
);
SET @sql := IF(
  @needs_type = 0,
  "ALTER TABLE users ADD COLUMN type VARCHAR(16) NOT NULL DEFAULT 'scram' AFTER password",
  "SELECT 1"
);
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
SQL

./scripts/setup-ejabberd-config.sh
docker-compose -f docker-compose.enterprise.yml restart xmpp
sleep 10

./scripts/setup-env.sh
./scripts/setup-node-services.sh
./scripts/init-services.sh
./scripts/qa-check.sh
./scripts/health-check.sh
```

## Validation

After the restore completes:

1. Log into `https://app.chat.example.com`.
2. Verify the intended super-admin can see the expected app list.
3. Verify default chats appear in the chat sidebar, not only in admin settings.
4. Verify chat login and sending a message work.
5. Verify assets resolve from `files.chat.example.com`.
6. Verify the AI bot answers a smoke prompt, including one prompt that should hit indexed RAG content.
7. Verify `./scripts/qa-check.sh` reports the backend and widget bundle healthy.
8. Run sanity scans to confirm old runtime domains are no longer present in restored live config/state:

```bash
docker-compose -f docker-compose.enterprise.yml exec -T mysql \
  mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" ejabberd_db <<'SQL'
SELECT 'muc_room.host', COUNT(*) FROM muc_room WHERE host REGEXP 'ethoradev\\.com|xmpp\\.ethora\\.com'
UNION ALL
SELECT 'users.username', COUNT(*) FROM users WHERE username REGEXP 'ethoradev\\.com|xmpp\\.ethora\\.com';
SQL

docker-compose -f docker-compose.enterprise.yml exec -T mongo \
  mongosh --quiet "$MONGO_DB" --eval '
const needles = [/ethoradev\.com/i, /xmpp\.ethora\.com/i];
for (const name of ["apps", "chats"]) {
  const docs = db.getCollection(name).find().toArray();
  let hits = 0;
  const scan = (value) => {
    if (typeof value === "string") {
      if (needles.some((needle) => needle.test(value))) hits += 1;
      return;
    }
    if (Array.isArray(value)) return value.forEach(scan);
    if (value && typeof value === "object") Object.values(value).forEach(scan);
  };
  docs.forEach(scan);
  print(`${name}: ${hits}`);
}'
```

## Super-admin guidance

Retaining the restored legacy super-admin is usually the safest option because app visibility and chat memberships are linked to the actual restored Mongo user documents.

If you also want a new deploy-time admin account to behave like a platform owner, add `--promote-super-admin <email>` when generating the migration pack.

## Optional Cleanup

The generated `ejabberd-cleanup.sql` file contains optional cleanup statements for stale chat data in QA clones.

Review it first:

```bash
less "$PACK_DIR/ejabberd-cleanup.sql"
```

Apply only the statements you explicitly want.
