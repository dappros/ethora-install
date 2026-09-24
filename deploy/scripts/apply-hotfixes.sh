#!/bin/bash
#
# Apply small, idempotent hotfixes to the deployed source tree before build.
# This keeps installs stable even when submodules lag behind the monoserver deploy scripts.
#
# Safe to run multiple times.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
warn() { echo "[WARN] $1"; }

# Source environment variables (best-effort)
ENV_FILE="$DEPLOY_DIR/.deploy.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
fi

BACKEND_DIR="${BACKEND_DIR:-$ROOT_DIR/ethora-backend}"

# Backend repo layout support:
# - legacy: backend/
# - new: services/api/
if [ -d "$BACKEND_DIR/services/api" ]; then
  BACKEND_API_DIR="$BACKEND_DIR/services/api"
else
  BACKEND_API_DIR="$BACKEND_DIR/backend"
fi

if [ ! -d "$BACKEND_API_DIR" ]; then
  warn "Backend API dir not found: $BACKEND_API_DIR (skipping hotfixes)"
  exit 0
fi

apply_patch_track_member() {
  local f="$BACKEND_API_DIR/src/controllers/chat.controller/chat.trackMember.js"
  [ -f "$f" ] || return 0

  # Only patch if the legacy parsing line exists.
  if ! grep -q "const \\[_appId, userId\\] = LUser\\.split('_')" "$f" 2>/dev/null; then
    return 0
  fi

  log "Applying hotfix: track-member robust LUser parsing"

  perl -0777 -i -pe 's/\n\s*const \[_appId, userId\] = LUser\.split\(\x27_\x27\)\n/\n    \/\/ LUser is expected to be in the canonical multi-tenant format: \"<appId>_<userId>\".\n    \/\/ Some synthetic\/legacy users (e.g. uptime_health_u1) include extra \"_\" segments which breaks parsing and can\n    \/\/ cause Mongoose CastErrors when userId is expected to be an ObjectId.\n    const parts = String(LUser || \"\").split(\"_\")\n    if (parts.length < 2) {\n        return res.send({ ok: true, success: true })\n    }\n    const userId = parts[1]\n    \/\/ Only accept 24-hex userId (Mongo ObjectId) to avoid casting errors in User2Chats schema.\n    if (!\/^[a-f0-9]{24}$\/i.test(userId)) {\n        return res.send({ ok: true, success: true })\n    }\n/sm' "$f" || true

  # Wrap DB ops with try/catch if not already.
  if ! grep -q "\\[track-member\\] failed" "$f" 2>/dev/null; then
    perl -0777 -i -pe 's/\n\s*if \(Type === \"join\"\) \{\n\s*await User2Chats\.updateOne\((.*?)\);\n\s*\}\n\n\s*if \(Type === \"exit\"\) \{\n\s*if \(Room\.split\(\x27_\x27\)\.length == 2\) \{\n\s*await User2Chats\.deleteMany\((.*?)\)\n\s*\}\n\s*\}\n/\n    try {\n        if (Type === \"join\") {\n            await User2Chats.updateOne({chatName: Room, userId: userId}, {$set: {userId: userId, chatName: Room, updated: new Date(), isNew: false}}, { upsert: true, new: true });\n        }\n\n        if (Type === \"exit\") {\n            if (Room.split(\"_\").length == 2) {\n                await User2Chats.deleteMany({chatName: Room, userId: userId})\n            }\n        }\n    } catch (e) {\n        \/\/ Do not fail ejabberd hooks on backend-side tracking errors (would cause join\/leave flakiness).\n        console.warn(\"[track-member] failed (non-fatal):\", e?.message || e)\n    }\n/sm' "$f" || true
  fi
}

apply_patch_xmpp_http_basic_auth() {
  local f="$BACKEND_API_DIR/src/services/xmpp.b2b.service.ts"
  [ -f "$f" ] || return 0

  # Only patch if tokenXMPP uses config.XMPP_ADMIN directly (legacy).
  if ! grep -q "tokenXMPP.*config\\.XMPP_ADMIN" "$f" 2>/dev/null; then
    return 0
  fi
  if grep -q "httpApiUser" "$f" 2>/dev/null; then
    return 0
  fi

  log "Applying hotfix: ejabberd HTTP API Basic auth user normalization"

  perl -0777 -i -pe 's/const tokenXMPP = `Basic \$\{base64\.encode\(\n\s*`\$\{config\.XMPP_ADMIN\}:\$\{config\.XMPP_PASSWORD\}`\n\)\}`;/\/\/ Ejabberd HTTP API ACLs commonly expect the full JID (e.g. admin\@xmpp.example.com) as the auth username.\n\/\/ Our deploy templates may provide only the localpart (\"admin\"), so normalize to full JID when needed.\nconst httpApiUser =\n    String(config.XMPP_ADMIN || \"\").includes(\"\@\")\n        ? String(config.XMPP_ADMIN || \"\")\n        : `\$\{String(config.XMPP_ADMIN || \"\")\}\@\$\{String(XMPP_HOST || \"\")\}`\n\nconst tokenXMPP = `Basic \$\{base64.encode(`\$\{httpApiUser\}:\$\{config.XMPP_PASSWORD\}`)\}`;/sm' "$f" || true
}

apply_patch_track_member
apply_patch_xmpp_http_basic_auth

log "Hotfixes applied (if needed)."

