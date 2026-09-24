#!/bin/bash

# Prepare a migration pack for restoring stateful Ethora snapshots
# into a new deploy environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"

MONGO_ARCHIVE=""
EJABBERD_SQL=""
AI_POSTGRES_DUMP=""
OUTPUT_DIR=""
REWRITE_EJABBERD_DUMP=false
API_DOMAIN_OVERRIDE=""
WEB_DOMAIN_OVERRIDE=""
XMPP_DOMAIN_OVERRIDE=""
FILES_DOMAIN_OVERRIDE=""
WIDGET_DOMAIN_OVERRIDE=""
HOSTED_APPS_ROOT_OVERRIDE=""
BASE_APP_DOMAIN_NAME_OVERRIDE=""
BACKFILL_DEFAULT_ROOM_MEMBERSHIPS=false
declare -a RETAIN_LEGACY_SUPER_ADMINS=()
declare -a PROMOTE_SUPER_ADMINS=()

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

warn() {
    echo "[WARN] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./scripts/prepare-stateful-migration.sh \
    --mongo-archive /path/to/dump.archive \
    --ejabberd-sql /path/to/ejabberd_db.sql \
    [--ai-postgres-dump /path/to/ai-service.dump] \
    [--output-dir /custom/output/dir] \
    [--api-domain api.example.com] \
    [--web-domain app.example.com] \
    [--xmpp-domain xmpp.example.com] \
    [--files-domain files.example.com] \
    [--widget-domain widget.example.com] \
    [--hosted-apps-root chat.example.com] \
    [--base-app-domain-name ethora] \
    [--retain-legacy-super-admin legacy-admin@example.com] \
    [--promote-super-admin admin@example.com] \
    [--backfill-default-room-memberships] \
    [--rewrite-ejabberd-dump]

What it does:
  - consumes snapshots created manually or by export-stateful-snapshots.sh
  - reads target domains from deploy/config/deploy.yml
  - inspects the supplied MongoDB archive and Ejabberd SQL dump
  - generates a migration pack with:
      * migration-plan.md
      * migration-map.env
      * mongo-post-restore.js
      * ejabberd-post-import.sql
      * ejabberd-cleanup.sql
      * AI Postgres restore notes in migration-plan.md
  - optionally creates a rewritten Ejabberd SQL dump copy
  - can repair explicit super-admin users after restore
  - can backfill default-room chat memberships after restore

Notes:
  - this script does not modify the source snapshots
  - MongoDB binary archives are not rewritten in-place; use the generated
    mongosh script after restore
EOF
}

require_cmd() {
    local name="$1"
    command -v "$name" >/dev/null 2>&1 || error "Required command not found: $name"
}

read_config() {
    local key="$1"
    local value
    value="$(yq eval "$key" "$CONFIG_FILE" 2>/dev/null || echo "")"
    if [ "$value" = "null" ]; then
        value=""
    fi
    echo "$value"
}

count_text_occurrences() {
    local file="$1"
    local needle="$2"
    local count
    if [ ! -f "$file" ]; then
        echo 0
        return
    fi
    count="$(rg -F -o --no-filename -- "$needle" "$file" 2>/dev/null | wc -l | tr -d ' ' || true)"
    echo "${count:-0}"
}

count_binary_strings() {
    local file="$1"
    local needle="$2"
    local count
    if [ ! -f "$file" ]; then
        echo 0
        return
    fi
    count="$(strings "$file" 2>/dev/null | rg -F -o --no-filename -- "$needle" 2>/dev/null | wc -l | tr -d ' ' || true)"
    echo "${count:-0}"
}

escape_sql() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    echo "$value"
}

mysql_replace_chain() {
    local expr="$1"
    shift
    while [ "$#" -gt 0 ]; do
        local from="$1"
        local to="$2"
        expr="REPLACE(${expr}, '$(escape_sql "$from")', '$(escape_sql "$to")')"
        shift 2
    done
    echo "$expr"
}

timestamp_utc() {
    date -u +'%Y%m%dT%H%M%SZ'
}

json_array_literal() {
    python3 - "$@" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1:]))
PY
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mongo-archive)
            MONGO_ARCHIVE="${2:-}"
            shift 2
            ;;
        --ejabberd-sql)
            EJABBERD_SQL="${2:-}"
            shift 2
            ;;
        --ai-postgres-dump)
            AI_POSTGRES_DUMP="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --rewrite-ejabberd-dump)
            REWRITE_EJABBERD_DUMP=true
            shift
            ;;
        --api-domain)
            API_DOMAIN_OVERRIDE="${2:-}"
            shift 2
            ;;
        --web-domain)
            WEB_DOMAIN_OVERRIDE="${2:-}"
            shift 2
            ;;
        --xmpp-domain)
            XMPP_DOMAIN_OVERRIDE="${2:-}"
            shift 2
            ;;
        --files-domain)
            FILES_DOMAIN_OVERRIDE="${2:-}"
            shift 2
            ;;
        --widget-domain)
            WIDGET_DOMAIN_OVERRIDE="${2:-}"
            shift 2
            ;;
        --hosted-apps-root)
            HOSTED_APPS_ROOT_OVERRIDE="${2:-}"
            shift 2
            ;;
        --base-app-domain-name)
            BASE_APP_DOMAIN_NAME_OVERRIDE="${2:-}"
            shift 2
            ;;
        --retain-legacy-super-admin)
            RETAIN_LEGACY_SUPER_ADMINS+=("${2:-}")
            shift 2
            ;;
        --promote-super-admin)
            PROMOTE_SUPER_ADMINS+=("${2:-}")
            shift 2
            ;;
        --backfill-default-room-memberships)
            BACKFILL_DEFAULT_ROOM_MEMBERSHIPS=true
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

require_cmd yq
require_cmd rg
require_cmd strings
require_cmd python3

[ -f "$CONFIG_FILE" ] || error "Missing deploy config: $CONFIG_FILE"
[ -n "$MONGO_ARCHIVE" ] || error "--mongo-archive is required"
[ -n "$EJABBERD_SQL" ] || error "--ejabberd-sql is required"
[ -f "$MONGO_ARCHIVE" ] || error "Mongo archive not found: $MONGO_ARCHIVE"
[ -f "$EJABBERD_SQL" ] || error "Ejabberd SQL dump not found: $EJABBERD_SQL"
if [ -n "$AI_POSTGRES_DUMP" ] && [ ! -f "$AI_POSTGRES_DUMP" ]; then
    error "AI Postgres dump not found: $AI_POSTGRES_DUMP"
fi

API_DOMAIN="$(read_config '.domains.api')"
WEB_DOMAIN="$(read_config '.domains.web')"
XMPP_DOMAIN="$(read_config '.domains.xmpp')"
FILES_DOMAIN="$(read_config '.domains.files')"
WIDGET_DOMAIN="$(read_config '.domains.widget // ""')"
HOSTED_APPS_ROOT_DOMAIN="$(read_config '.domains.hosted_apps_root // ""')"
BASE_APP_DOMAIN_NAME="$(read_config '.base_app.domain_name // ""')"

if [ -n "$API_DOMAIN_OVERRIDE" ]; then
    API_DOMAIN="$API_DOMAIN_OVERRIDE"
fi
if [ -n "$WEB_DOMAIN_OVERRIDE" ]; then
    WEB_DOMAIN="$WEB_DOMAIN_OVERRIDE"
fi
if [ -n "$XMPP_DOMAIN_OVERRIDE" ]; then
    XMPP_DOMAIN="$XMPP_DOMAIN_OVERRIDE"
fi
if [ -n "$FILES_DOMAIN_OVERRIDE" ]; then
    FILES_DOMAIN="$FILES_DOMAIN_OVERRIDE"
fi
if [ -n "$WIDGET_DOMAIN_OVERRIDE" ]; then
    WIDGET_DOMAIN="$WIDGET_DOMAIN_OVERRIDE"
fi
if [ -n "$HOSTED_APPS_ROOT_OVERRIDE" ]; then
    HOSTED_APPS_ROOT_DOMAIN="$HOSTED_APPS_ROOT_OVERRIDE"
fi
if [ -n "$BASE_APP_DOMAIN_NAME_OVERRIDE" ]; then
    BASE_APP_DOMAIN_NAME="$BASE_APP_DOMAIN_NAME_OVERRIDE"
fi

[ -n "$API_DOMAIN" ] || error "deploy.yml: domains.api is required"
[ -n "$WEB_DOMAIN" ] || error "deploy.yml: domains.web is required"
[ -n "$XMPP_DOMAIN" ] || error "deploy.yml: domains.xmpp is required"
[ -n "$FILES_DOMAIN" ] || error "deploy.yml: domains.files is required"

if [ -z "$HOSTED_APPS_ROOT_DOMAIN" ]; then
    HOSTED_APPS_ROOT_DOMAIN="${WEB_DOMAIN#*.}"
fi

if [ -z "$BASE_APP_DOMAIN_NAME" ]; then
    if [ "$WEB_DOMAIN" = "localhost" ]; then
        BASE_APP_DOMAIN_NAME="ethora"
    else
        BASE_APP_DOMAIN_NAME="$(echo "$WEB_DOMAIN" | cut -d'.' -f1)"
    fi
fi

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$DEPLOY_DIR/generated/stateful-migration/$(timestamp_utc)"
fi

mkdir -p "$OUTPUT_DIR"

RETAIN_LEGACY_SUPER_ADMINS_JSON="$(json_array_literal "${RETAIN_LEGACY_SUPER_ADMINS[@]}")"
PROMOTE_SUPER_ADMINS_JSON="$(json_array_literal "${PROMOTE_SUPER_ADMINS[@]}")"
RETAIN_LEGACY_SUPER_ADMINS_CSV="$(IFS=,; echo "${RETAIN_LEGACY_SUPER_ADMINS[*]}")"
PROMOTE_SUPER_ADMINS_CSV="$(IFS=,; echo "${PROMOTE_SUPER_ADMINS[*]}")"

TARGET_CONFERENCE_DOMAIN="conference.${XMPP_DOMAIN}"
TARGET_WEB_URL="https://${WEB_DOMAIN}"
TARGET_API_URL="https://${API_DOMAIN}"
TARGET_FILES_URL="https://${FILES_DOMAIN}"
TARGET_XMPP_WS_URL="wss://${XMPP_DOMAIN}/ws"
TARGET_REGISTER_URL="${TARGET_WEB_URL}/register"
TARGET_WIDGET_URL=""
if [ -n "$WIDGET_DOMAIN" ]; then
    TARGET_WIDGET_URL="https://${WIDGET_DOMAIN}/assistant.js"
fi

declare -a DOMAIN_REPLACEMENTS=(
    "conference.xmpp.ethoradev.com" "${TARGET_CONFERENCE_DOMAIN}"
    "xmpp.ethoradev.com" "${XMPP_DOMAIN}"
    "conference.xmpp.ethora.com" "${TARGET_CONFERENCE_DOMAIN}"
    "xmpp.ethora.com" "${XMPP_DOMAIN}"
    "conference.dev.dxmpp.com" "${TARGET_CONFERENCE_DOMAIN}"
    "dev.dxmpp.com" "${XMPP_DOMAIN}"
    "wss://xmpp.ethoradev.com:5443/ws" "${TARGET_XMPP_WS_URL}"
    "https://xmpp.ethoradev.com:5443/ws" "${TARGET_XMPP_WS_URL}"
    "http://xmpp.ethoradev.com:5443/ws" "${TARGET_XMPP_WS_URL}"
    "wss://xmpp.ethora.com:5443/ws" "${TARGET_XMPP_WS_URL}"
    "https://xmpp.ethora.com:5443/ws" "${TARGET_XMPP_WS_URL}"
    "http://xmpp.ethora.com:5443/ws" "${TARGET_XMPP_WS_URL}"
    "http://dev.dxmpp.com" "https://${XMPP_DOMAIN}"
    "https://dev.dxmpp.com" "https://${XMPP_DOMAIN}"
    "files.ethoradev.com" "${FILES_DOMAIN}"
    "files.ethora.com" "${FILES_DOMAIN}"
    "app.ethora.com" "${WEB_DOMAIN}"
    "beta.ethora.com" "${WEB_DOMAIN}"
    "api.ethora.com" "${API_DOMAIN}"
    "api.ethoradev.com" "${API_DOMAIN}"
)

mongo_files_ethoradev_count="$(count_binary_strings "$MONGO_ARCHIVE" "files.ethoradev.com")"
mongo_app_ethora_count="$(count_binary_strings "$MONGO_ARCHIVE" "app.ethora.com")"
mongo_beta_ethora_count="$(count_binary_strings "$MONGO_ARCHIVE" "beta.ethora.com")"
mongo_ethora_root_count="$(count_binary_strings "$MONGO_ARCHIVE" "https://ethora.com")"

sql_conference_ethoradev_count="$(count_text_occurrences "$EJABBERD_SQL" "conference.xmpp.ethoradev.com")"
sql_xmpp_ethoradev_count="$(count_text_occurrences "$EJABBERD_SQL" "xmpp.ethoradev.com")"
sql_conference_dxmpp_count="$(count_text_occurrences "$EJABBERD_SQL" "conference.dev.dxmpp.com")"
sql_dxmpp_count="$(count_text_occurrences "$EJABBERD_SQL" "dev.dxmpp.com")"
sql_ws_ethoradev_count="$(count_text_occurrences "$EJABBERD_SQL" "wss://xmpp.ethoradev.com:5443/ws")"

MIGRATION_MAP_FILE="$OUTPUT_DIR/migration-map.env"
MONGO_SCRIPT_FILE="$OUTPUT_DIR/mongo-post-restore.js"
EJABBERD_SQL_FILE="$OUTPUT_DIR/ejabberd-post-import.sql"
CLEANUP_SQL_FILE="$OUTPUT_DIR/ejabberd-cleanup.sql"
PLAN_FILE="$OUTPUT_DIR/migration-plan.md"
REWRITTEN_EJABBERD_SQL_FILE="$OUTPUT_DIR/ejabberd_db.rewritten.sql"

cat > "$MIGRATION_MAP_FILE" <<EOF
SOURCE_MONGO_ARCHIVE="$MONGO_ARCHIVE"
SOURCE_EJABBERD_SQL="$EJABBERD_SQL"
SOURCE_AI_POSTGRES_DUMP="$AI_POSTGRES_DUMP"
TARGET_API_DOMAIN="$API_DOMAIN"
TARGET_WEB_DOMAIN="$WEB_DOMAIN"
TARGET_XMPP_DOMAIN="$XMPP_DOMAIN"
TARGET_CONFERENCE_DOMAIN="$TARGET_CONFERENCE_DOMAIN"
TARGET_FILES_DOMAIN="$FILES_DOMAIN"
TARGET_WIDGET_DOMAIN="$WIDGET_DOMAIN"
TARGET_HOSTED_APPS_ROOT_DOMAIN="$HOSTED_APPS_ROOT_DOMAIN"
TARGET_BASE_APP_DOMAIN_NAME="$BASE_APP_DOMAIN_NAME"
TARGET_API_URL="$TARGET_API_URL"
TARGET_WEB_URL="$TARGET_WEB_URL"
TARGET_XMPP_WS_URL="$TARGET_XMPP_WS_URL"
TARGET_FILES_URL="$TARGET_FILES_URL"
TARGET_WIDGET_URL="$TARGET_WIDGET_URL"
RETAIN_LEGACY_SUPER_ADMINS="$RETAIN_LEGACY_SUPER_ADMINS_CSV"
PROMOTE_SUPER_ADMINS="$PROMOTE_SUPER_ADMINS_CSV"
BACKFILL_DEFAULT_ROOM_MEMBERSHIPS="$BACKFILL_DEFAULT_ROOM_MEMBERSHIPS"
EOF

cat > "$MONGO_SCRIPT_FILE" <<EOF
// Post-restore MongoDB rewrite script generated by prepare-stateful-migration.sh
// Usage:
//   mongosh --quiet <db_name> "${MONGO_SCRIPT_FILE}"
// Or:
//   docker exec -i <mongo-container> mongosh --quiet <db_name> < "${MONGO_SCRIPT_FILE}"

const dbName = db.getName()
const database = db.getSiblingDB(dbName)
const retainLegacySuperAdmins = ${RETAIN_LEGACY_SUPER_ADMINS_JSON}
const promoteSuperAdmins = ${PROMOTE_SUPER_ADMINS_JSON}
const backfillDefaultRoomMembershipsEnabled = ${BACKFILL_DEFAULT_ROOM_MEMBERSHIPS}

const assetReplacements = [
  { from: 'https://files.ethoradev.com', to: '${TARGET_FILES_URL}' },
  { from: 'http://files.ethoradev.com', to: '${TARGET_FILES_URL}' },
  { from: 'https://files.ethora.com', to: '${TARGET_FILES_URL}' },
  { from: 'http://files.ethora.com', to: '${TARGET_FILES_URL}' },
]

const xmppRuntimeReplacements = [
  { from: 'conference.xmpp.ethoradev.com', to: '${TARGET_CONFERENCE_DOMAIN}' },
  { from: 'xmpp.ethoradev.com', to: '${XMPP_DOMAIN}' },
  { from: 'conference.xmpp.ethora.com', to: '${TARGET_CONFERENCE_DOMAIN}' },
  { from: 'xmpp.ethora.com', to: '${XMPP_DOMAIN}' },
  { from: 'conference.dev.dxmpp.com', to: '${TARGET_CONFERENCE_DOMAIN}' },
  { from: 'dev.dxmpp.com', to: '${XMPP_DOMAIN}' },
  { from: 'wss://xmpp.ethoradev.com:5443/ws', to: '${TARGET_XMPP_WS_URL}' },
  { from: 'https://xmpp.ethoradev.com:5443/ws', to: '${TARGET_XMPP_WS_URL}' },
  { from: 'http://xmpp.ethoradev.com:5443/ws', to: '${TARGET_XMPP_WS_URL}' },
  { from: 'wss://xmpp.ethora.com:5443/ws', to: '${TARGET_XMPP_WS_URL}' },
  { from: 'https://xmpp.ethora.com:5443/ws', to: '${TARGET_XMPP_WS_URL}' },
  { from: 'http://xmpp.ethora.com:5443/ws', to: '${TARGET_XMPP_WS_URL}' },
]

const widgetRuntimeReplacements = [
  { from: 'https://dappros-wp-scripts.s3.us-east-2.amazonaws.com/ethora_assistant.js', to: '${TARGET_WIDGET_URL}' },
  { from: 'http://dappros-wp-scripts.s3.us-east-2.amazonaws.com/ethora_assistant.js', to: '${TARGET_WIDGET_URL}' },
]

const historicalWebReplacements = [
  { from: 'https://app.ethora.com', to: '${TARGET_WEB_URL}' },
  { from: 'http://app.ethora.com', to: '${TARGET_WEB_URL}' },
  { from: 'https://beta.ethora.com', to: '${TARGET_WEB_URL}' },
  { from: 'http://beta.ethora.com', to: '${TARGET_WEB_URL}' },
  { from: 'https://api.ethora.com', to: '${TARGET_API_URL}' },
  { from: 'http://api.ethora.com', to: '${TARGET_API_URL}' },
  { from: 'https://api.ethoradev.com', to: '${TARGET_API_URL}' },
  { from: 'http://api.ethoradev.com', to: '${TARGET_API_URL}' },
]

const runtimeReplacements = [
  ...assetReplacements,
  ...xmppRuntimeReplacements,
  ...historicalWebReplacements,
  ...('${TARGET_WIDGET_URL}' ? widgetRuntimeReplacements : []),
]

// Keep historical/marketing provenance disabled by default.
// Enable only if you explicitly want the restored QA clone to stop referencing
// production marketing/app URLs in stored metadata and indexed content.
const rewriteHistoricalWebContent = false

function applyReplacements(value, replacements) {
  if (typeof value !== 'string') return value
  let next = value
  for (const replacement of replacements) {
    next = next.split(replacement.from).join(replacement.to)
  }
  return next
}

function getPath(obj, path) {
  return path.split('.').reduce((acc, key) => (acc == null ? undefined : acc[key]), obj)
}

function setPath(obj, path, value) {
  const parts = path.split('.')
  let ref = obj
  for (let i = 0; i < parts.length - 1; i++) {
    const key = parts[i]
    if (ref[key] == null || typeof ref[key] !== 'object') ref[key] = {}
    ref = ref[key]
  }
  ref[parts[parts.length - 1]] = value
}

function rewriteField(collectionName, fieldPath, replacements) {
  const collection = database.getCollection(collectionName)
  let scanned = 0
  let changed = 0

  collection.find({}, { [fieldPath]: 1 }).forEach((doc) => {
    scanned += 1
    const current = getPath(doc, fieldPath)
    if (typeof current !== 'string' || current.length === 0) return

    const next = applyReplacements(current, replacements)
    if (next === current) return

    const payload = {}
    payload[fieldPath] = next
    collection.updateOne({ _id: doc._id }, { \$set: payload })
    changed += 1
  })

  print(\`\${collectionName}.\${fieldPath}: scanned=\${scanned} changed=\${changed}\`)
}

function rewriteArrayField(collectionName, fieldPath, replacements) {
  const collection = database.getCollection(collectionName)
  let scanned = 0
  let changed = 0

  collection.find({}, { [fieldPath]: 1 }).forEach((doc) => {
    scanned += 1
    const current = getPath(doc, fieldPath)
    if (!Array.isArray(current) || current.length === 0) return

    let didChange = false
    const next = current.map((value) => {
      if (typeof value !== 'string' || value.length === 0) return value
      const rewritten = applyReplacements(value, replacements)
      if (rewritten !== value) didChange = true
      return rewritten
    })

    if (!didChange) return

    const payload = {}
    payload[fieldPath] = next
    collection.updateOne({ _id: doc._id }, { \$set: payload })
    changed += 1
  })

  print(\`\${collectionName}.\${fieldPath}: scanned=\${scanned} changed=\${changed}\`)
}

function rewriteArrayObjectField(collectionName, fieldPath, propertyName, replacements) {
  const collection = database.getCollection(collectionName)
  let scanned = 0
  let changed = 0

  collection.find({}, { [fieldPath]: 1 }).forEach((doc) => {
    scanned += 1
    const current = getPath(doc, fieldPath)
    if (!Array.isArray(current) || current.length === 0) return

    let didChange = false
    const next = current.map((item) => {
      if (!item || typeof item !== 'object' || Array.isArray(item)) return item
      if (typeof item[propertyName] !== 'string' || item[propertyName].length === 0) {
        return item
      }

      const rewritten = applyReplacements(item[propertyName], replacements)
      if (rewritten === item[propertyName]) return item
      didChange = true
      return { ...item, [propertyName]: rewritten }
    })

    if (!didChange) return

    const payload = {}
    payload[fieldPath] = next
    collection.updateOne({ _id: doc._id }, { \$set: payload })
    changed += 1
  })

  print(\`\${collectionName}.\${fieldPath}[].\${propertyName}: scanned=\${scanned} changed=\${changed}\`)
}

function toObjectId(value) {
  if (value == null) return null
  try {
    return ObjectId(String(value))
  } catch (error) {
    return null
  }
}

function appAclDocument(userId, appId) {
  return {
    userId,
    appId,
    network: {
      netStats: {
        read: true,
        disabled: ['create', 'update', 'delete', 'admin'],
      },
    },
    application: {
      appCreate: {
        create: true,
        disabled: ['read', 'update', 'delete', 'admin'],
      },
      appSettings: {
        read: true,
        update: true,
        admin: true,
        disabled: ['create', 'delete'],
      },
      appUsers: {
        create: true,
        read: true,
        update: true,
        delete: true,
        admin: true,
      },
      appTokens: {
        create: true,
        read: true,
        update: true,
        admin: true,
      },
      appPush: {
        create: true,
        read: true,
        update: true,
        admin: true,
      },
      appStats: {
        read: true,
        admin: true,
      },
    },
  }
}

function ensureAppAcl(userId, appId) {
  if (!userId || !appId) return false
  const payload = appAclDocument(String(userId), String(appId))
  database.getCollection('appacls').updateOne(
    { userId: String(userId), appId: String(appId) },
    { \$set: payload },
    { upsert: true }
  )
  return true
}

function bulkEnsureMemberships(userIds, roomNames) {
  const memberships = database.getCollection('user_to_chats')
  const now = new Date()
  let ops = []
  let writes = 0

  function flush() {
    if (ops.length === 0) return
    memberships.bulkWrite(ops, { ordered: false })
    writes += ops.length
    ops = []
  }

  for (const userId of userIds) {
    for (const roomName of roomNames) {
      ops.push({
        updateOne: {
          filter: { userId, chatName: roomName },
          update: { \$set: { userId, chatName: roomName, updated: now } },
          upsert: true,
        },
      })
      if (ops.length >= 500) flush()
    }
  }

  flush()
  return writes
}

function ensureUserDefaultRooms(userDoc) {
  if (!userDoc || !userDoc._id || !userDoc.appId) return 0
  const appObjectId = toObjectId(userDoc.appId)
  if (!appObjectId) return 0

  const app = database.getCollection('apps').findOne(
    { _id: appObjectId },
    { projection: { defaultRooms: 1 } }
  )
  if (!app || !Array.isArray(app.defaultRooms) || app.defaultRooms.length === 0) return 0

  const roomNames = app.defaultRooms
    .map((room) => room && room.jid)
    .filter((roomName) => typeof roomName === 'string' && roomName.length > 0)

  if (roomNames.length === 0) return 0
  return bulkEnsureMemberships([userDoc._id], roomNames)
}

function ensureConfiguredSuperAdmins(emails, label) {
  if (!Array.isArray(emails) || emails.length === 0) return

  const usersCollection = database.getCollection('users')
  const baseApp = database.getCollection('apps').findOne(
    { isBaseApp: true },
    { projection: { _id: 1 } }
  )
  const baseAppId = baseApp ? String(baseApp._id) : ''
  let matched = 0
  let membershipsEnsured = 0

  usersCollection.find({ email: { \$in: emails } }).forEach((userDoc) => {
    matched += 1
    let userAppId = userDoc.appId ? String(userDoc.appId) : ''

    if (!userAppId && baseAppId) {
      usersCollection.updateOne(
        { _id: userDoc._id },
        { \$set: { appId: baseAppId } }
      )
      userAppId = baseAppId
      userDoc.appId = baseAppId
    }

    usersCollection.updateOne(
      { _id: userDoc._id },
      { \$set: { isSuperAdmin: { read: true, write: true } } }
    )

    if (userAppId) {
      ensureAppAcl(userDoc._id, userAppId)
      membershipsEnsured += ensureUserDefaultRooms({ _id: userDoc._id, appId: userAppId })
    }
  })

  print(\`superadmin.\${label}: matched=\${matched} membershipsEnsured=\${membershipsEnsured}\`)
}

function backfillDefaultRoomMemberships() {
  const apps = database.getCollection('apps')
    .find(
      { 'defaultRooms.0': { \$exists: true } },
      { projection: { _id: 1, defaultRooms: 1 } }
    )
    .toArray()

  const usersCollection = database.getCollection('users')
  let appsScanned = 0
  let usersScanned = 0
  let membershipsEnsured = 0

  for (const app of apps) {
    appsScanned += 1
    const appId = String(app._id)
    const roomNames = (app.defaultRooms || [])
      .map((room) => room && room.jid)
      .filter((roomName) => typeof roomName === 'string' && roomName.length > 0)

    if (roomNames.length === 0) continue

    const userIds = usersCollection
      .find({ appId }, { projection: { _id: 1 } })
      .toArray()
      .map((userDoc) => userDoc._id)

    usersScanned += userIds.length
    membershipsEnsured += bulkEnsureMemberships(userIds, roomNames)
  }

  print(\`defaultRoomMemberships: apps=\${appsScanned} users=\${usersScanned} membershipsEnsured=\${membershipsEnsured}\`)
}

print(\`Using database: \${dbName}\`)
rewriteField('apps', 'logoImage', assetReplacements)
rewriteField('apps', 'sublogoImage', assetReplacements)
rewriteField('apps', 'loginScreenBackgroundImage', assetReplacements)
rewriteField('apps', 'googleServicesJson', assetReplacements)
rewriteField('apps', 'googleServiceInfoPlist', assetReplacements)
rewriteField('apps', 'firebaseWebConfigString', runtimeReplacements)
rewriteField('apps', 'aiBot.prompt', runtimeReplacements)
rewriteField('users', 'profileImage', assetReplacements)
rewriteField('chats', 'picture', assetReplacements)
rewriteField('files', 'location', assetReplacements)
rewriteField('files', 'locationPreview', assetReplacements)
rewriteField('chatmedias', 'location', assetReplacements)
rewriteField('chatmedias', 'locationPreview', assetReplacements)
rewriteField('tokens', 'nftPreview', assetReplacements)
rewriteField('tokens', 'nftFileUrl', assetReplacements)
rewriteField('tokens', 'nftMetaUrl', assetReplacements)
rewriteArrayField('tokens', 'metadataUrls', assetReplacements)
rewriteArrayField('docs', 'locations', assetReplacements)
rewriteArrayObjectField('apps', 'defaultRooms', 'jid', xmppRuntimeReplacements)

ensureConfiguredSuperAdmins(retainLegacySuperAdmins, 'retain')
ensureConfiguredSuperAdmins(promoteSuperAdmins, 'promote')

if (backfillDefaultRoomMembershipsEnabled) {
  backfillDefaultRoomMemberships()
}

if (rewriteHistoricalWebContent) {
  rewriteField('site_sources', 'originUrl', historicalWebReplacements)
  rewriteField('site_sources', 'url', historicalWebReplacements)
  rewriteField('site_sources', 'md', historicalWebReplacements)
  rewriteField('registration_logs', 'metadata', historicalWebReplacements)
}

print('MongoDB post-restore rewrite complete.')
EOF

sql_chain_username="$(mysql_replace_chain "username" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_peer="$(mysql_replace_chain "peer" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_bare_peer="$(mysql_replace_chain "bare_peer" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_xml="$(mysql_replace_chain "xml" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_opts="$(mysql_replace_chain "opts" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_host="$(mysql_replace_chain "host" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_jid="$(mysql_replace_chain "jid" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_user="$(mysql_replace_chain "\`user\`" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_data="$(mysql_replace_chain "data" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_publisher="$(mysql_replace_chain "publisher" "${DOMAIN_REPLACEMENTS[@]}")"
sql_chain_payload="$(mysql_replace_chain "payload" "${DOMAIN_REPLACEMENTS[@]}")"

cat > "$EJABBERD_SQL_FILE" <<EOF
-- Post-import Ejabberd rewrite generated by prepare-stateful-migration.sh
-- Run after restoring ejabberd_db.sql into the QA MySQL instance.
--
-- Example:
--   docker exec -i <mysql-container> mysql -uroot -p"\$MYSQL_ROOT_PASSWORD" ejabberd_db < "${EJABBERD_SQL_FILE}"

USE ejabberd_db;
SET sql_safe_updates = 0;
START TRANSACTION;

UPDATE archive
SET
  username = ${sql_chain_username},
  peer = ${sql_chain_peer},
  bare_peer = ${sql_chain_bare_peer},
  xml = ${sql_chain_xml}
WHERE
  username <> ${sql_chain_username}
  OR peer <> ${sql_chain_peer}
  OR bare_peer <> ${sql_chain_bare_peer}
  OR xml <> ${sql_chain_xml};

UPDATE spool
SET
  username = ${sql_chain_username},
  xml = ${sql_chain_xml}
WHERE
  username <> ${sql_chain_username}
  OR xml <> ${sql_chain_xml};

UPDATE muc_room
SET
  host = ${sql_chain_host},
  opts = ${sql_chain_opts}
WHERE
  host <> ${sql_chain_host}
  OR opts <> ${sql_chain_opts};

UPDATE muc_room_subscribers
SET
  host = ${sql_chain_host},
  jid = ${sql_chain_jid}
WHERE
  host <> ${sql_chain_host}
  OR jid <> ${sql_chain_jid};

UPDATE user_rooms
SET
  \`user\` = ${sql_chain_user},
  host = ${sql_chain_host}
WHERE
  \`user\` <> ${sql_chain_user}
  OR host <> ${sql_chain_host};

UPDATE private_storage
SET
  data = ${sql_chain_data}
WHERE data <> ${sql_chain_data};

UPDATE pubsub_item
SET
  publisher = ${sql_chain_publisher},
  payload = ${sql_chain_payload}
WHERE
  publisher <> ${sql_chain_publisher}
  OR payload <> ${sql_chain_payload};

COMMIT;
EOF

cat > "$CLEANUP_SQL_FILE" <<'EOF'
-- Optional Ejabberd cleanup helpers for QA/staging clones.
-- Review every statement before running.
USE ejabberd_db;

-- 1) Purge offline backlog older than 30 days.
-- DELETE FROM spool
-- WHERE created_at < (UTC_TIMESTAMP() - INTERVAL 30 DAY);

-- 2) Remove room subscribers pointing at rooms that no longer exist.
-- DELETE s
-- FROM muc_room_subscribers s
-- LEFT JOIN muc_room r
--   ON r.name = s.room
--  AND r.host = s.host
-- WHERE r.name IS NULL;

-- 3) Remove user->room rows pointing at rooms that no longer exist.
-- DELETE ur
-- FROM user_rooms ur
-- LEFT JOIN muc_room r
--   ON r.name = ur.name
--  AND r.host = ur.host
-- WHERE r.name IS NULL;

-- 4) Candidate cleanup for empty and inactive rooms.
--    Review carefully before use on any shared dataset.
-- DELETE mr
-- FROM muc_room mr
-- LEFT JOIN user_rooms ur
--   ON ur.name = mr.name
--  AND ur.host = mr.host
-- LEFT JOIN archive a
--   ON a.bare_peer = CONCAT(mr.name, '@', mr.host)
--  AND a.created_at >= (UTC_TIMESTAMP() - INTERVAL 90 DAY)
-- WHERE ur.name IS NULL
--   AND a.id IS NULL;

-- 5) Orphaned XMPP user cleanup should be done only after cross-checking
--    against restored MongoDB users/user2apps. This helper intentionally does
--    not auto-delete those rows because a bad join would be destructive.
EOF

if [ "$REWRITE_EJABBERD_DUMP" = true ]; then
    TARGET_CONFERENCE_DOMAIN="$TARGET_CONFERENCE_DOMAIN" \
    XMPP_DOMAIN="$XMPP_DOMAIN" \
    FILES_DOMAIN="$FILES_DOMAIN" \
    WEB_DOMAIN="$WEB_DOMAIN" \
    API_DOMAIN="$API_DOMAIN" \
    TARGET_XMPP_WS_URL="$TARGET_XMPP_WS_URL" \
    REWRITTEN_EJABBERD_SQL_FILE="$REWRITTEN_EJABBERD_SQL_FILE" \
    EJABBERD_SQL="$EJABBERD_SQL" \
    python3 - <<'PY'
import os

source_path = os.environ["EJABBERD_SQL"]
target_path = os.environ["REWRITTEN_EJABBERD_SQL_FILE"]
replacements = [
    ("conference.xmpp.ethoradev.com", os.environ["TARGET_CONFERENCE_DOMAIN"]),
    ("xmpp.ethoradev.com", os.environ["XMPP_DOMAIN"]),
    ("conference.dev.dxmpp.com", os.environ["TARGET_CONFERENCE_DOMAIN"]),
    ("dev.dxmpp.com", os.environ["XMPP_DOMAIN"]),
    ("wss://xmpp.ethoradev.com:5443/ws", os.environ["TARGET_XMPP_WS_URL"]),
    ("https://xmpp.ethoradev.com:5443/ws", os.environ["TARGET_XMPP_WS_URL"]),
    ("http://xmpp.ethoradev.com:5443/ws", os.environ["TARGET_XMPP_WS_URL"]),
    ("http://dev.dxmpp.com", f"https://{os.environ['XMPP_DOMAIN']}"),
    ("https://dev.dxmpp.com", f"https://{os.environ['XMPP_DOMAIN']}"),
    ("files.ethoradev.com", os.environ["FILES_DOMAIN"]),
    ("files.ethora.com", os.environ["FILES_DOMAIN"]),
    ("app.ethora.com", os.environ["WEB_DOMAIN"]),
    ("beta.ethora.com", os.environ["WEB_DOMAIN"]),
    ("api.ethora.com", os.environ["API_DOMAIN"]),
    ("api.ethoradev.com", os.environ["API_DOMAIN"]),
]

with open(source_path, "r", encoding="utf-8", errors="replace") as source, open(target_path, "w", encoding="utf-8") as target:
    for line in source:
        for old, new in replacements:
            line = line.replace(old, new)
        target.write(line)
PY
fi

cat > "$PLAN_FILE" <<EOF
# Stateful Migration Plan

Generated: $(date -u +'%Y-%m-%d %H:%M:%SZ')

## Target Domains

- API: \`${API_DOMAIN}\`
- Web: \`${WEB_DOMAIN}\`
- XMPP: \`${XMPP_DOMAIN}\`
- Files: \`${FILES_DOMAIN}\`
- Widget: \`${WIDGET_DOMAIN:-disabled}\`
- Hosted apps root: \`${HOSTED_APPS_ROOT_DOMAIN}\`
- Base app slug: \`${BASE_APP_DOMAIN_NAME}\`

## Snapshot Inputs

- MongoDB archive: \`${MONGO_ARCHIVE}\`
- Ejabberd SQL: \`${EJABBERD_SQL}\`
- AI Postgres dump: \`${AI_POSTGRES_DUMP:-inspect old ai-service PG_URL and export separately}\`

## What Must Be Rewritten

### Ejabberd MySQL

The local SQL dump contains old XMPP hostnames embedded in live chat state, not just in historical text:

- \`conference.xmpp.ethoradev.com\`: ${sql_conference_ethoradev_count}
- \`xmpp.ethoradev.com\`: ${sql_xmpp_ethoradev_count}
- \`conference.dev.dxmpp.com\`: ${sql_conference_dxmpp_count}
- \`dev.dxmpp.com\`: ${sql_dxmpp_count}
- \`wss://xmpp.ethoradev.com:5443/ws\`: ${sql_ws_ethoradev_count}

These references occur in at least:

- \`archive\`
- \`spool\`
- \`muc_room\`
- \`muc_room_subscribers\`
- \`user_rooms\`
- \`private_storage\`
- \`pubsub_item\`

Use \`ejabberd-post-import.sql\` after restoring the dump, or use the optional rewritten dump copy if you generated one.

### MongoDB

Clear-cut functional asset URLs were found in the MongoDB archive strings:

- \`files.ethoradev.com\`: ${mongo_files_ethoradev_count}

The generated Mongo rewrite now targets common runtime fields such as:

- \`apps.logoImage\`
- \`apps.sublogoImage\`
- \`apps.loginScreenBackgroundImage\`
- \`apps.googleServicesJson\`
- \`apps.googleServiceInfoPlist\`
- \`apps.firebaseWebConfigString\`
- \`apps.aiBot.prompt\`
- \`apps.defaultRooms[].jid\`
- \`users.profileImage\`
- \`chats.picture\`
- \`files.location\`
- \`files.locationPreview\`
- \`chatmedias.location\`
- \`chatmedias.locationPreview\`
- \`tokens.nftPreview\`
- \`tokens.nftFileUrl\`
- \`tokens.nftMetaUrl\`
- \`tokens.metadataUrls[]\`
- \`docs.locations[]\`

Use \`mongo-post-restore.js\` after restoring the archive.

### AI embeddings Postgres

The AI service RAG data is stored separately from MongoDB/Ejabberd in Postgres/pgvector.

- Old prod source dump: \`${AI_POSTGRES_DUMP:-not supplied to this script}\`
- Do **not** assume it shares the Uptime Postgres service or schema.
- If the source environment is a monoserver-managed install, you can create this dump with \`./scripts/export-stateful-snapshots.sh\`.
- Read the old prod \`PG_URL\` from the running \`ai-service\` environment or its deployed \`.env\`.
- Preferred export command:
  - \`pg_dump "\$OLD_AI_PG_URL" -Fc -f ai_service_embeddings_<timestamp>.dump\`
- Preferred restore command on the new host:
  - \`pg_restore -d "\$NEW_AI_PG_URL" --clean --if-exists --no-owner --no-acl ai_service_embeddings_<timestamp>.dump\`
- Validation after restore:
  - \`psql "\$NEW_AI_PG_URL" -c '\dx'\`
  - \`psql "\$NEW_AI_PG_URL" -c '\dt'\`
  - confirm \`vector\` extension and \`documents\` table exist before starting \`ai-service\`

## Optional User/ACL Repair

- Retain legacy super-admin emails: \`${RETAIN_LEGACY_SUPER_ADMINS_CSV:-none}\`
- Promote additional super-admin emails: \`${PROMOTE_SUPER_ADMINS_CSV:-none}\`
- Backfill default room memberships: \`${BACKFILL_DEFAULT_ROOM_MEMBERSHIPS}\`

When configured, the generated Mongo script can:

- force \`isSuperAdmin.read/write\` for those explicit users
- ensure a full \`appacls\` row for the user’s current app
- ensure those users are linked to their app’s \`defaultRooms\`
- optionally backfill \`user_to_chats\` for all restored app users

## What Is Probably Historical And Should Stay By Default

These were also found in the MongoDB archive strings, but they are likely analytics provenance, indexed site content, or historical marketing data rather than runtime config:

- \`app.ethora.com\`: ${mongo_app_ethora_count}
- \`beta.ethora.com\`: ${mongo_beta_ethora_count}
- \`https://ethora.com\`: ${mongo_ethora_root_count}

By default, the generated Mongo script does **not** rewrite:

- \`registration_logs.metadata\`
- \`site_sources.originUrl\`
- \`site_sources.url\`
- \`site_sources.md\`

That avoids corrupting attribution history or rewriting customer RAG corpora blindly.

## Cleanup Candidates

Optional cleanup SQL is in \`ejabberd-cleanup.sql\`.

The safe defaults included there are:

- purge old \`spool\` rows
- remove \`muc_room_subscribers\` rows pointing at missing rooms
- remove \`user_rooms\` rows pointing at missing rooms
- review-only candidate query for empty inactive rooms

Not automated by default:

- orphaned XMPP users that no longer exist in MongoDB
- aggressive room pruning
- deleting indexed website/document content from MongoDB

Those are intentionally left manual because they need business rules and cross-DB validation.

## Suggested Restore Order

1. Restore MongoDB archive.
2. Import Ejabberd SQL dump.
3. Restore the AI embeddings Postgres dump (or create an export from the old \`ai-service\` \`PG_URL\` if you did not provide one here).
4. Run \`mongo-post-restore.js\` against the restored MongoDB.
5. Run \`ejabberd-post-import.sql\` against \`ejabberd_db\`.
6. If desired, review and apply selected statements from \`ejabberd-cleanup.sql\`.
7. Run app/chat smoke tests on the QA stack, including an AI/RAG query.
8. If you used admin repair options, verify the promoted/retained users can see expected apps and chats.
EOF

log "Generated migration pack:"
log "  $PLAN_FILE"
log "  $MIGRATION_MAP_FILE"
log "  $MONGO_SCRIPT_FILE"
log "  $EJABBERD_SQL_FILE"
log "  $CLEANUP_SQL_FILE"

if [ "$REWRITE_EJABBERD_DUMP" = true ]; then
    log "  $REWRITTEN_EJABBERD_SQL_FILE"
fi

log "Done."
