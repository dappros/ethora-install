#!/bin/bash

# Service Initialization Script
# Initializes databases, creates admin users, and sets up base app

set -e

SCRIPT_VERSION="2025-12-19.17"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# docker-compose.enterprise.yml has fail-closed data volumes (${MONGO_DATA_DIR:?...}),
# so compose refuses to interpolate the file - even for `ps`/`logs`/`down` - unless
# these are exported. Matters when this script is run standalone rather than from
# install.sh / update.sh, which export them already.
# shellcheck source=deploy/scripts/load-data-env.sh
source "$SCRIPT_DIR/load-data-env.sh"
ethora_load_data_env "$DEPLOY_DIR" || exit 1
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

warn() {
    echo "[WARN] $1"
}

# Run a command as the non-root deploying user when possible (avoids root-owned node_modules in /home/*).
# Backend run mode (deploy.yml services.backend.mode). In image mode the host
# has no source, node_modules or dist for the API: the one-off Node scripts
# (initEthoraApp.js, scripts/deploy/*.js) ship inside the image under
# dist/scripts and run as `<image> script <path>` with the rendered .env
# passed as --env-file. See docs/CONTAINER_IMAGES.md.
INIT_CONFIG_FILE="${CANONICAL_DEPLOY_CONFIG_FILE:-$DEPLOY_DIR/config/deploy.yml}"
_cfg() { # _cfg <yq path> <fallback> <default>
    local v=""
    if [ -f "$INIT_CONFIG_FILE" ] && command -v yq >/dev/null 2>&1; then v="$(yq eval "$1 // \"\"" "$INIT_CONFIG_FILE" 2>/dev/null || true)"; fi
    [ "$v" = "null" ] && v=""
    [ -z "$v" ] && v="$2"
    [ -z "$v" ] || [ "$v" = "null" ] && v="$3"
    printf '%s' "$v"
}
BACKEND_MODE="$(_cfg '.services.backend.mode' "${BACKEND_MODE:-}" source)"
ETHORA_API_IMAGE="$(_cfg '.services.backend.image' "${ETHORA_API_IMAGE:-}" "")"

# backend_node <script> [args...]: run a Node script with the backend's
# dependencies, cwd = the API dir. Script paths are absolute or relative to
# the API dir. Stdout/stderr pass through so callers can redirect.
backend_node() {
    local script="$1"; shift
    local api_dir="${BACKEND_API_DIR:-}"
    if [ "$BACKEND_MODE" = "image" ]; then
        # The image carries the scripts (dist/scripts) and its own node_modules;
        # only the rendered .env crosses the boundary. No source on the host.
        [ -n "$ETHORA_API_IMAGE" ] || { echo "ETHORA_API_IMAGE is empty" >&2; return 1; }
        local env_args=()
        [ -f "$api_dir/.env" ] && env_args=(--env-file "$api_dir/.env")
        docker run --rm --network host \
            "${env_args[@]}" \
            -e NODE_NO_WARNINGS=1 -e NODE_OPTIONS="${NODE_OPTIONS:---no-deprecation}" \
            "$ETHORA_API_IMAGE" script "$script" "$@"
    else
        run_as_deploy_user "cd \"$api_dir\" && NODE_NO_WARNINGS=1 NODE_OPTIONS=\"${NODE_OPTIONS:---no-deprecation}\" node \"$script\" $(printf '%q ' "$@")"
    fi
}

# "node is available" for the purposes of this script: on the host, or via the image.
have_backend_node() {
    [ "$BACKEND_MODE" = "image" ] || command -v node >/dev/null 2>&1
}

run_as_deploy_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        sudo -u "$SUDO_USER" -H bash -lc "$*"
    else
        bash -lc "$*"
    fi
}

# Ensure backend node_modules exist before running initEthoraApp.js (it requires dotenv, mongoose, etc.)
ensure_backend_node_modules() {
    local backend_dir="$1"
    if [ -z "$backend_dir" ] || [ ! -d "$backend_dir" ]; then
        warn "Backend directory not found for dependency install: $backend_dir"
        return 1
    fi

    local stamp_dir="$backend_dir/.ethora_deploy"
    local stamp_file="$stamp_dir/deps.sha256"
    local lockfile=""
    if [ -f "$backend_dir/package-lock.json" ]; then
        lockfile="$backend_dir/package-lock.json"
    elif [ -f "$backend_dir/package.json" ]; then
        lockfile="$backend_dir/package.json"
    fi

    hash_file_sha256() {
        local file="$1"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$file" | awk '{print $1}'
            return 0
        fi
        if command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$file" | awk '{print $1}'
            return 0
        fi
        echo ""
    }

    local current_hash=""
    if [ -n "$lockfile" ]; then
        current_hash="$(hash_file_sha256 "$lockfile")"
    fi

    local need_install=false
    if [ ! -d "$backend_dir/node_modules" ]; then
        need_install=true
    elif [ ! -f "$stamp_file" ]; then
        need_install=true
    elif [ -z "$current_hash" ]; then
        need_install=true
    elif [ "$(cat "$stamp_file" 2>/dev/null || echo '')" != "$current_hash" ]; then
        need_install=true
    fi

    if [ "$need_install" != "true" ]; then
        return 0
    fi

    log "Installing backend dependencies (required for initEthoraApp.js)..."

    # Reduce npm noise in deploy logs (especially deprecation warnings from transitive deps).
    # This does NOT change behavior; it only controls output.
    local NPM_QUIET_FLAGS="--no-fund --no-audit --loglevel=error"
    # IMPORTANT:
    # During deploy we often export NODE_ENV=production globally, which can make npm omit devDependencies.
    # We *need* devDependencies even here because some init scripts and toolchains may rely on them.
    local NPM_INCLUDE_DEV_FLAGS="--include=dev"
    if [ -f "$backend_dir/package-lock.json" ]; then
        # Some backend branches have an out-of-sync lockfile. Prefer reproducibility, but fall back gracefully.
        if ! run_as_deploy_user "cd \"$backend_dir\" && npm ci $NPM_INCLUDE_DEV_FLAGS $NPM_QUIET_FLAGS"; then
            warn "npm ci failed (lockfile likely out of sync). Falling back to npm install..."
            run_as_deploy_user "cd \"$backend_dir\" && npm install $NPM_INCLUDE_DEV_FLAGS $NPM_QUIET_FLAGS"
        fi
    else
        run_as_deploy_user "cd \"$backend_dir\" && npm install $NPM_INCLUDE_DEV_FLAGS $NPM_QUIET_FLAGS"
    fi

    mkdir -p "$stamp_dir" >/dev/null 2>&1 || true
    if [ -n "$current_hash" ]; then
        echo "$current_hash" >"$stamp_file" 2>/dev/null || true
    else
        date -u +'%Y-%m-%dT%H:%M:%SZ' >"$stamp_file" 2>/dev/null || true
    fi
}

# Find the running MongoDB container without relying on docker-compose exec.
get_mongo_container() {
    # Prefer the common default container name
    if docker ps --format '{{.Names}}' | grep -q '^deploy_mongo_1$'; then
        echo "deploy_mongo_1"
        return 0
    fi
    # Docker Compose v2 naming (hyphens)
    if docker ps --format '{{.Names}}' | grep -q '^deploy-mongo-1$'; then
        echo "deploy-mongo-1"
        return 0
    fi

    # Prefer compose service label (works regardless of project name)
    local by_label
    by_label="$(docker ps --filter 'label=com.docker.compose.service=mongo' --format '{{.Names}}' | head -n 1)"
    if [ -n "$by_label" ]; then
        echo "$by_label"
        return 0
    fi

    return 1
}

get_redis_container() {
    if docker ps --format '{{.Names}}' | grep -q '^deploy_redis-server_1$'; then
        echo "deploy_redis-server_1"
        return 0
    fi
    if docker ps --format '{{.Names}}' | grep -q '^deploy-redis-server-1$'; then
        echo "deploy-redis-server-1"
        return 0
    fi
    local by_label
    by_label="$(docker ps --filter 'label=com.docker.compose.service=redis-server' --format '{{.Names}}' | head -n 1)"
    if [ -n "$by_label" ]; then
        echo "$by_label"
        return 0
    fi
    return 1
}

ensure_redis_data_writable() {
    local redis_container
    redis_container="$(get_redis_container)" || return 0
    if docker exec "$redis_container" sh -lc 'test -w /data' >/dev/null 2>&1; then
        return 0
    fi
    log "Fixing Redis data dir permissions (/data) in container: ${redis_container}"
    docker exec -u root "$redis_container" sh -lc 'chown -R redis:redis /data 2>/dev/null || chown -R 999:999 /data 2>/dev/null || true' >/dev/null 2>&1 || true
    if ! docker exec "$redis_container" sh -lc 'test -w /data' >/dev/null 2>&1; then
        warn "Redis /data is still not writable. Redis may enter MISCONF (stop-writes-on-bgsave-error)."
    fi
}

mongo_eval_safe() {
    local timeout_seconds="${1:-4}"
    shift
    local js="${1:-db.adminCommand('ping')}"

    # mongosh --eval is occasionally sensitive to multiline input; normalize to one line.
    js="${js//$'\n'/ }"

    local mongo_container
    mongo_container="$(get_mongo_container)" || return 1

    if command -v timeout >/dev/null 2>&1; then
        timeout -k 1s "${timeout_seconds}s" docker exec "$mongo_container" mongosh --eval "$js" --quiet
    else
        docker exec "$mongo_container" mongosh --eval "$js" --quiet
    fi
}

mongo_is_primary() {
    local timeout_seconds="${1:-4}"
    local result=""

    result="$(mongo_eval_safe "$timeout_seconds" "try { const h = db.hello(); print(h && h.isWritablePrimary ? 'true' : 'false'); } catch (e) { print('false'); }" 2>/dev/null | tr -d '\r' | awk 'NF { last = $0 } END { print last }')"
    [ "$result" = "true" ]
}

# Log helper for background tasks
log_bg() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')][bg] $1"
}

# Find the running Ejabberd container without using docker-compose (faster and avoids compose parsing/build issues).
get_xmpp_container() {
    # Prefer the common default container name
    if docker ps --format '{{.Names}}' | grep -q '^deploy_xmpp_1$'; then
        echo "deploy_xmpp_1"
        return 0
    fi
    # Docker Compose v2 naming (hyphens)
    if docker ps --format '{{.Names}}' | grep -q '^deploy-xmpp-1$'; then
        echo "deploy-xmpp-1"
        return 0
    fi

    # Prefer compose service label (works regardless of project name)
    local by_label
    by_label="$(docker ps --filter 'label=com.docker.compose.service=xmpp' --format '{{.Names}}' | head -n 1)"
    if [ -n "$by_label" ]; then
        echo "$by_label"
        return 0
    fi

    return 1
}

# Run an ejabberdctl command with a short timeout to avoid long hangs during early startup.
ejabberdctl_safe() {
    local timeout_seconds="${1:-6}"
    shift

    local xmpp_container
    xmpp_container="$(get_xmpp_container)" || return 1

    # stdin must come from /dev/null, never the controlling terminal: `docker exec -i`
    # attaches stdin, and `timeout` (without --foreground) runs it in a background
    # process group. A read from the tty there earns SIGTTIN, which stops both docker
    # and timeout — so the timeout never fires and the caller hangs forever.
    # Use timeout if available (coreutils). If not available, run without it.
    if command -v timeout >/dev/null 2>&1; then
        # Use a hard kill to avoid rare cases where SIGTERM doesn't stop the command
        timeout -k 1s "${timeout_seconds}s" docker exec -i "$xmpp_container" /home/ejabberd/bin/ejabberdctl "$@" </dev/null
    else
        docker exec -i "$xmpp_container" /home/ejabberd/bin/ejabberdctl "$@" </dev/null
    fi
}

ejabberd_admin_exists() {
    docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql \
        mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" ejabberd_db \
        -e "SELECT username FROM users WHERE username='admin' LIMIT 1;" 2>/dev/null | grep -qx "admin"
}

ejabberd_user_exists() {
    local username="$1"
    [ -n "$username" ] || return 1
    local username_escaped="${username//\'/\'\'}"
    docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql \
        mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" ejabberd_db \
        -e "SELECT username FROM users WHERE username='${username_escaped}' LIMIT 1;" 2>/dev/null | grep -qx "$username"
}

# Ensure a user can authenticate against Ejabberd with the given password.
# This is needed because the backend stores xmppUsername/xmppPassword in Mongo,
# but ejabberd users live in its own SQL DB. After --reset / DB reinit, those accounts
# may not exist in ejabberd yet, causing frontend SASLError: not-authorized.
ensure_ejabberd_user_password() {
    local username="$1"
    local password="$2"
    if [ -z "$username" ] || [ -z "$password" ]; then
        return 1
    fi

    if ejabberd_user_exists "$username"; then
        # Keep ejabberd aligned with Mongo value (idempotent).
        ejabberdctl_safe 4 change_password "$username" "$XMPP_DOMAIN" "$password" >/dev/null 2>&1 || true
        log "Ejabberd user password ensured: ${username}@${XMPP_DOMAIN}"
        return 0
    fi

    # Create if missing (idempotent enough; if created concurrently it'll just fail).
    if ejabberdctl_safe 4 register "$username" "$XMPP_DOMAIN" "$password" >/dev/null 2>&1; then
        log "Ejabberd user created: ${username}@${XMPP_DOMAIN}"
        return 0
    fi

    # Last resort: try setting password in case the user exists but list is stale.
    ejabberdctl_safe 4 change_password "$username" "$XMPP_DOMAIN" "$password" >/dev/null 2>&1 || true
    log "Ejabberd user password ensured (fallback): ${username}@${XMPP_DOMAIN}"
    return 0
}

ensure_base_app_xmpp_users() {
    # Preferred method: use backend HTTP API to fetch appToken + user.xmppUsername/xmppPassword.
    # This avoids brittle raw Mongo queries and matches the real frontend flow.
    local base_slug="${BASE_APP_DOMAIN_NAME:-}"
    local admin_email="${ADMIN_EMAIL:-}"
    local admin_password="${ADMIN_PASSWORD:-}"
    local backend_port="${BACKEND_PORT:-8080}"

    if [ -z "$admin_email" ] || [ -z "$admin_password" ]; then
        warn "Admin credentials missing; cannot auto-provision XMPP users in ejabberd."
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        return 0
    fi

    # Also try the web subdomain (matches frontend VITE_DOMAIN_NAME by default in prod).
    local web_slug=""
    if [ -n "${WEB_DOMAIN:-}" ] && [ "${WEB_DOMAIN:-}" != "localhost" ]; then
        web_slug="$(echo "$WEB_DOMAIN" | cut -d'.' -f1)"
    fi

    local slug_try
    for slug_try in "$base_slug" "$web_slug"; do
        if [ -z "$slug_try" ] || [ "$slug_try" == "null" ]; then
            continue
        fi

        local cfg_json app_token login_json xmpp_user xmpp_pass
        cfg_json="$(curl -fsS "http://127.0.0.1:${backend_port}/v1/apps/get-config?domainName=${slug_try}" 2>/dev/null || true)"
        if [ -z "$cfg_json" ]; then
            continue
        fi

        app_token="$(python3 - <<PY
import json,sys
try:
  d=json.loads(sys.stdin.read())
  r=d.get('result') or {}
  print(r.get('appToken') or '')
except Exception:
  print('')
PY
<<<"$cfg_json")"

        if [ -n "$app_token" ]; then
            login_json="$(curl -fsS \
              -H "Authorization: ${app_token}" \
              -H "Content-Type: application/json" \
              -d "{\"email\":\"${admin_email}\",\"password\":\"${admin_password}\"}" \
              "http://127.0.0.1:${backend_port}/v1/users/login-with-email" 2>/dev/null || true)"

            if [ -n "$login_json" ]; then
                xmpp_user="$(python3 - <<PY
import json,sys
try:
  d=json.loads(sys.stdin.read())
  u=d.get('user') or {}
  print(u.get('xmppUsername') or '')
except Exception:
  print('')
PY
<<<"$login_json")"
                xmpp_pass="$(python3 - <<PY
import json,sys
try:
  d=json.loads(sys.stdin.read())
  u=d.get('user') or {}
  print(u.get('xmppPassword') or '')
except Exception:
  print('')
PY
<<<"$login_json")"

                if [ -n "$xmpp_user" ] && [ -n "$xmpp_pass" ]; then
                    ensure_ejabberd_user_password "$xmpp_user" "$xmpp_pass" || true
                    return 0
                fi
            fi
        else
            warn "Base app config did not contain appToken for domainName='${slug_try}'. Falling back to Mongo query for XMPP provisioning."
        fi

        # Fallback helper: query Mongo using backend's Node/Mongoose models instead of mongosh.
        # Some environments have flaky/empty mongosh output (exit=0 but no stdout), which breaks provisioning.
        node_mongo_fallback() {
            local domain_slug="$1"
            local email="$2"
            local backend_dir="$3"
            local api_dir=""
            if [ -z "$domain_slug" ] || [ -z "$email" ] || [ -z "$backend_dir" ]; then
                return 1
            fi
            if ! have_backend_node; then
                return 1
            fi

            if [ "$BACKEND_MODE" = "image" ]; then
                api_dir="${BACKEND_API_DIR:-$backend_dir/services/api}"
            elif [ -d "$backend_dir/src/models" ]; then
                api_dir="$backend_dir"
            elif [ -d "$backend_dir/backend/src/models" ]; then
                api_dir="$backend_dir/backend"
            elif [ -d "$backend_dir/services/api/src/models" ]; then
                api_dir="$backend_dir/services/api"
            else
                return 1
            fi

            # Ensure deps exist so mongoose models can load (source mode only).
            [ "$BACKEND_MODE" = "image" ] || ensure_backend_node_modules "$api_dir" >/dev/null 2>&1 || true

            # Capture stdout only; Node/Mongoose warnings go to stderr and would break parsing.
            local tmp_err="/tmp/ethora-xmpp-mongo-fallback.$$.stderr"
            local tmp_out="/tmp/ethora-xmpp-mongo-fallback.$$.stdout"
            rm -f "$tmp_err" "$tmp_out" >/dev/null 2>&1 || true
            BACKEND_API_DIR="$api_dir" backend_node scripts/deploy/xmpp-app-lookup.js "$MONGO_URI" "$domain_slug" "$email" 1>"$tmp_out" 2>"$tmp_err" || true

            local out
            out="$(cat "$tmp_out" 2>/dev/null || true)"
            if [ -z "$out" ]; then
                local err
                err="$(cat "$tmp_err" 2>/dev/null || true)"
                if [ -n "$err" ]; then
                    warn "Node/Mongoose fallback stderr (first 240 chars): $(echo "$err" | tr '\n' ' ' | head -c 240)"
                fi
            fi
            echo "$out"
        }

        # Fallback: read from Mongo directly (works even if appToken is hidden).
        local payload
        # Run mongosh and capture stderr too (timeouts / parse errors otherwise look like "empty output").
        local js out ec
        # Quick probe: ensure mongosh output is actually capturable in this environment.
        # (We've seen cases where --eval returns exit=0 with empty output; this helps diagnose that.)
        local probe
        probe="$(mongo_eval_safe 6 "print('ethora_mongo_probe')" 2>&1 || true)"
        if [ -z "$probe" ]; then
            warn "Mongo probe produced no output (exit=$?). Mongo XMPP provisioning may not work until mongosh output is fixed."
        fi
        js="
          // IMPORTANT: Always emit *one line* of JSON (even on exceptions),
          // otherwise the bash/python parsing will fail and we'll lose diagnostics.
          (function () {
            let usedDb = null;
            let app = null;
            let d = null;
            try {
              // Try to locate the app across likely DB names (we can't assume MONGO_DB always matches the actual DB).
              const dbnames = ['${MONGO_DB}', 'ethora_prod'];
              for (const n of dbnames) {
                if (!n || n === 'null') continue;
                d = db.getSiblingDB(n);
                app = d.apps.findOne({ domainName: '${slug_try}' });
                if (app) { usedDb = n; break; }
              }
              if (!app) {
                print(JSON.stringify({ debug: { usedDb: usedDb, appFound: false, appDomainName: '${slug_try}' } }));
                return;
              }

              // Owner lookup strategy:
              // 1) Prefer owner2apps mapping (most reliable; doesn't depend on email/appId matching).
              // 2) Fall back to AppAcl mapping.
              // 3) Final fallback: query by admin_email + appId (handles older installs).
              const appIdStr = String(app._id);
              let ownerId = null;

              const owner2 = (d && d.owner2apps) ? (d.owner2apps.findOne({ appId: appIdStr }) || d.owner2apps.findOne({ appId: app._id })) : null;
              if (owner2 && owner2.ownerId) ownerId = owner2.ownerId;

              if (!ownerId && d && d.appacls) {
                const acl = d.appacls.findOne({ appId: appIdStr }) || d.appacls.findOne({ appId: app._id });
                if (acl && acl.userId) ownerId = acl.userId;
              }

              function maybeObjectId(s) {
                try {
                  if (typeof s === 'string' && s.length === 24) return ObjectId(s);
                } catch (e) {}
                return null;
              }

              let owner = null;
              if (ownerId) {
                const oid = maybeObjectId(ownerId);
                owner = oid ? d.users.findOne({ _id: oid }, { xmppUsername: 1, xmppPassword: 1, email: 1, emails: 1, appId: 1 }) : null;
              }
              if (!owner) {
                // NOTE: user emails sometimes live in user.email OR user.emails[].email (social logins, legacy data).
                // NOTE: users.appId may be stored as String (common) or ObjectId (older data).
                owner = d.users.findOne(
                  {
                    \$and: [
                      { \$or: [{ email: '${admin_email}' }, { 'emails.email': '${admin_email}' }] },
                      { \$or: [{ appId: appIdStr }, { appId: app._id }] },
                    ],
                  },
                  { xmppUsername: 1, xmppPassword: 1, email: 1, emails: 1, appId: 1 }
                );
              }

              const out = {
                debug: {
                  usedDb,
                  appFound: true,
                  appDomainName: '${slug_try}',
                  appId: appIdStr,
                  ownerIdFound: !!ownerId,
                  ownerId: ownerId ? String(ownerId) : null,
                  ownerFound: !!owner,
                  ownerAppIdType: owner ? (typeof owner.appId) : null,
                  ownerXmppUsernamePresent: owner ? !!owner.xmppUsername : false,
                  ownerEmailPresent: owner ? !!owner.email : false,
                  ownerEmailsArrayPresent: owner ? (Array.isArray(owner.emails) && owner.emails.length > 0) : false
                },
                owner: owner ? { xmppUsername: owner.xmppUsername, xmppPassword: owner.xmppPassword } : null,
                system: app.systemChatAccount ? { jid: app.systemChatAccount.jid, password: app.systemChatAccount.password } : null
              };
              print(JSON.stringify(out));
            } catch (e) {
              print(JSON.stringify({ debug: { usedDb: usedDb, appDomainName: '${slug_try}', error: String(e) } }));
            }
          })();
        "

        out="$(mongo_eval_safe 60 "$js" 2>&1)"
        ec=$?
        payload="$out"

        if [ "${ec:-0}" -eq 124 ]; then
            warn "Mongo fallback timed out after 60s for domainName='${slug_try}'."
            warn "Mongo fallback raw output (first 240 chars): $(echo "$payload" | tr '\n' ' ' | head -c 240)"
            continue
        fi

        if [ -z "$payload" ]; then
            warn "Mongo fallback returned empty output for domainName='${slug_try}' (exit=${ec})."
            # Provide actionable diagnostics even when stdout is empty.
            if [ "${ec:-0}" -ne 0 ]; then
                warn "Mongo fallback failed (exit=${ec}). Common causes: docker permission, container name mismatch, mongosh failure."
            fi
            # Even if empty, print the first chars (will be blank, but keeps behavior consistent).
            warn "Mongo fallback raw output (first 240 chars): $(echo "$out" | tr '\n' ' ' | head -c 240)"
            # If mongosh produced nothing but exit=0, fall back to Node/Mongoose query.
            warn "Trying Node/Mongoose fallback for XMPP provisioning..."
            # Capture stdout only; stderr is handled inside node_mongo_fallback (and warned separately).
            payload="$(node_mongo_fallback "$slug_try" "$admin_email" "$BACKEND_DIR" || true)"
            if [ -z "$payload" ]; then
                continue
            fi
        fi

        # Prefer Node fallback key/value format (base64-encoded), otherwise fall back to JSON parsing.
        if echo "$payload" | grep -q '^ETHORA_XMPP_OWNER_USERNAME_B64='; then
            xmpp_user="$(echo "$payload" | sed -n 's/^ETHORA_XMPP_OWNER_USERNAME_B64=//p' | head -n 1 | base64 -d 2>/dev/null || true)"
            xmpp_pass="$(echo "$payload" | sed -n 's/^ETHORA_XMPP_OWNER_PASSWORD_B64=//p' | head -n 1 | base64 -d 2>/dev/null || true)"
            login_user="$(echo "$payload" | sed -n 's/^ETHORA_XMPP_LOGIN_USERNAME_B64=//p' | head -n 1 | base64 -d 2>/dev/null || true)"
            login_pass="$(echo "$payload" | sed -n 's/^ETHORA_XMPP_LOGIN_PASSWORD_B64=//p' | head -n 1 | base64 -d 2>/dev/null || true)"
        else
            xmpp_user="$(python3 - <<'PY'
import json,sys
s=sys.stdin.read()
try:
  i=s.find('{')
  if i < 0: raise ValueError('no_json_object')
  d,_ = json.JSONDecoder().raw_decode(s[i:])
  o=d.get('owner') or {}
  print(o.get('xmppUsername') or '')
except Exception:
  print('')
PY
<<<"$payload")"
            xmpp_pass="$(python3 - <<'PY'
import json,sys
s=sys.stdin.read()
try:
  i=s.find('{')
  if i < 0: raise ValueError('no_json_object')
  d,_ = json.JSONDecoder().raw_decode(s[i:])
  o=d.get('owner') or {}
  print(o.get('xmppPassword') or '')
except Exception:
  print('')
PY
<<<"$payload")"
            login_user=""
            login_pass=""
        fi

        # Ensure the actual adminEmail login user first (this is what the frontend will use).
        if [ -n "${login_user:-}" ] && [ -n "${login_pass:-}" ]; then
            ensure_ejabberd_user_password "$login_user" "$login_pass" || true
        fi

        if [ -n "$xmpp_user" ] && [ -n "$xmpp_pass" ]; then
            ensure_ejabberd_user_password "$xmpp_user" "$xmpp_pass" || true
        fi

        # Also ensure the base app system chat account exists (app_<appId>).
        local sys_user sys_pass
        if echo "$payload" | grep -q '^ETHORA_XMPP_SYSTEM_JID_B64='; then
            sys_user="$(echo "$payload" | sed -n 's/^ETHORA_XMPP_SYSTEM_JID_B64=//p' | head -n 1 | base64 -d 2>/dev/null || true)"
            sys_pass="$(echo "$payload" | sed -n 's/^ETHORA_XMPP_SYSTEM_PASSWORD_B64=//p' | head -n 1 | base64 -d 2>/dev/null || true)"
        else
            sys_user="$(python3 - <<'PY'
import json,sys
s=sys.stdin.read()
try:
  i=s.find('{')
  if i < 0: raise ValueError('no_json_object')
  d,_ = json.JSONDecoder().raw_decode(s[i:])
  ss=d.get('system') or {}
  print(ss.get('jid') or '')
except Exception:
  print('')
PY
<<<"$payload")"
            sys_pass="$(python3 - <<'PY'
import json,sys
s=sys.stdin.read()
try:
  i=s.find('{')
  if i < 0: raise ValueError('no_json_object')
  d,_ = json.JSONDecoder().raw_decode(s[i:])
  ss=d.get('system') or {}
  print(ss.get('password') or '')
except Exception:
  print('')
PY
<<<"$payload")"
        fi
        if [ -n "$sys_user" ] && [ -n "$sys_pass" ]; then
            ensure_ejabberd_user_password "$sys_user" "$sys_pass" || true
        fi

        # If Node fallback provided all app user creds, provision them too.
        if echo "$payload" | grep -q '^ETHORA_XMPP_USER_PAIR_B64='; then
            while IFS= read -r line; do
                pair_b64="$(echo "$line" | sed -n 's/^ETHORA_XMPP_USER_PAIR_B64=//p')"
                if [ -z "$pair_b64" ]; then
                    continue
                fi
                decoded="$(echo "$pair_b64" | base64 -d 2>/dev/null || true)"
                u_name="$(printf '%s' "$decoded" | head -n 1)"
                u_pass="$(printf '%s' "$decoded" | tail -n +2 | head -n 1)"
                if [ -n "$u_name" ] && [ -n "$u_pass" ]; then
                    ensure_ejabberd_user_password "$u_name" "$u_pass" || true
                fi
            done < <(echo "$payload" | grep '^ETHORA_XMPP_USER_PAIR_B64=' || true)
        fi

        if [ -n "$xmpp_user" ] && [ -n "$xmpp_pass" ]; then
            return 0
        fi

        # If we got here, we had an app but not the owner's XMPP credentials. Emit non-secret debug info.
        if [ -n "$payload" ]; then
            if echo "$payload" | grep -q '^ETHORA_XMPP_DEBUG_JSON_B64='; then
                local dbg
                dbg="$(echo "$payload" | sed -n 's/^ETHORA_XMPP_DEBUG_JSON_B64=//p' | head -n 1 | base64 -d 2>/dev/null || true)"
                if [ -n "$dbg" ]; then
                    warn "XMPP provisioning Mongo debug for domainName='${slug_try}': ${dbg}"
                    # keep going; we may still successfully provision from emitted user pairs
                fi
            fi
            debug_line="$(python3 - <<PY
import json,sys
s=sys.stdin.read()
try:
  i=s.find('{')
  if i < 0:
    raise ValueError('no_json_object')
  d,_ = json.JSONDecoder().raw_decode(s[i:])
except Exception:
  print('debug_parse_failed')
  sys.exit(0)
dbg=d.get('debug') or {}
print("usedDb={usedDb} appFound={appFound} appId={appId} ownerIdFound={ownerIdFound} ownerFound={ownerFound} xmppUserPresent={xmppUserPresent} error={error}".format(
  usedDb=dbg.get('usedDb'),
  appFound=dbg.get('appFound'),
  appId=dbg.get('appId'),
  ownerIdFound=dbg.get('ownerIdFound'),
  ownerFound=dbg.get('ownerFound'),
  xmppUserPresent=dbg.get('ownerXmppUsernamePresent'),
  error=dbg.get('error'),
))
PY
<<<"$payload")"
            warn "XMPP provisioning Mongo debug for domainName='${slug_try}': ${debug_line}"
            if [ "$debug_line" = "debug_parse_failed" ]; then
                # Show a small snippet of the raw mongosh output to debug quoting/runtime issues.
                warn "XMPP provisioning Mongo raw output (first 240 chars): $(echo "$payload" | tr '\n' ' ' | head -c 240)"
            fi
        fi
    done

    warn "Could not determine admin XMPP credentials for base app (tried slugs: '${base_slug}', '${web_slug}')."
    return 0
}

ensure_ejabberd_admin_loop() {
    # This runs in background to avoid blocking installs on slow ejabberd startup.
    # It retries with short timeouts and exits as soon as admin exists.
    local max_attempts="${1:-60}"
    local i

    if ejabberd_admin_exists; then
        # Ensure password matches current deploy env (install.sh may reuse/regenerate secrets).
        # Without this, the backend may authenticate with a different password and chat flows will break.
        ensure_ejabberd_user_password "admin" "$XMPP_ADMIN_PASSWORD" >/dev/null 2>&1 || true
        log_bg "Ejabberd admin already exists (password ensured)"
        return 0
    fi

    for i in $(seq 1 "$max_attempts"); do
        # Try register (idempotent enough; if user already exists it will fail fast)
        if ejabberdctl_safe 4 register admin "$XMPP_DOMAIN" "$XMPP_ADMIN_PASSWORD" >/dev/null 2>&1; then
            log_bg "Ejabberd admin created"
            return 0
        fi

        # Re-check existence (handles race where it was created by something else)
        if ejabberd_admin_exists; then
            ensure_ejabberd_user_password "admin" "$XMPP_ADMIN_PASSWORD" >/dev/null 2>&1 || true
            log_bg "Ejabberd admin became available (password ensured)"
            return 0
        fi

        log_bg "Ejabberd admin not ready yet (attempt ${i}/${max_attempts})"
        sleep 1
    done

    log_bg "Giving up: admin not created after ${max_attempts} attempts"
    return 1
}

# Refresh domain/base app values in .deploy.env if deploy.yml changed.
REFRESH_SCRIPT="$DEPLOY_DIR/scripts/refresh-deploy-env.sh"
if [ -f "$REFRESH_SCRIPT" ]; then
    bash "$REFRESH_SCRIPT" || true
fi

# Source environment variables
ENV_FILE="$DEPLOY_DIR/.deploy.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    error "Environment file not found: $ENV_FILE. Please run install.sh first."
fi

if [ -z "$API_DOMAIN" ]; then
    error "Environment variables not set. Please run install.sh first."
fi

# Get ROOT_DIR from environment or calculate
if [ -z "$ROOT_DIR" ]; then
    ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
fi

STATE_DIR="${STATE_DIR:-$DEPLOY_DIR/.deploy-state}"
mkdir -p "$STATE_DIR"

log "Initializing services..."
log "init-services.sh version: ${SCRIPT_VERSION}"

# Wait for MongoDB to be ready
log "Waiting for MongoDB to be ready..."
for i in {1..30}; do
    if docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mongo mongosh --eval "db.adminCommand('ping')" --quiet > /dev/null 2>&1; then
        log "MongoDB is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        error "MongoDB failed to start"
    fi
    sleep 2
done

# Wait for MongoDB replica set PRIMARY.
# We run Mongo in replSet mode and a separate 'mongosetup' container initializes rs0.
# If we run initEthoraApp.js too early, Mongo can still be in election and throw:
#   MongoServerError: not primary and secondaryOk=false
log "Waiting for MongoDB replica set PRIMARY..."
MONGO_PRIMARY_PROBE_TIMEOUT_SECONDS="${MONGO_PRIMARY_PROBE_TIMEOUT_SECONDS:-4}"
MONGO_PRIMARY_MAX_ATTEMPTS="${MONGO_PRIMARY_MAX_ATTEMPTS:-15}"
for ((i=1; i<=MONGO_PRIMARY_MAX_ATTEMPTS; i++)); do
    # db.hello().isWritablePrimary is true only on PRIMARY.
    # Use an explicit printed boolean and a slightly longer timeout because some hosts take >2s
    # just to start mongosh inside docker, which otherwise causes false negatives and long waits.
    if mongo_is_primary "$MONGO_PRIMARY_PROBE_TIMEOUT_SECONDS"; then
        log "MongoDB is PRIMARY"
        break
    fi
    if [ "$i" -eq "$MONGO_PRIMARY_MAX_ATTEMPTS" ]; then
        warn "MongoDB did not report PRIMARY yet; continuing (initEthoraApp.js may fail if election is still in progress)"
    fi
    sleep 1
done

# Wait for MySQL to be ready
log "Waiting for MySQL to be ready..."
for i in {1..30}; do
    if docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql mysqladmin ping -h localhost -u root -p"$MYSQL_ROOT_PASSWORD" --silent > /dev/null 2>&1; then
        log "MySQL is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        error "MySQL failed to start"
    fi
    sleep 2
done

# Redis can fail writes if /data is owned by root (common on fresh volumes).
ensure_redis_data_writable

# Ensure MySQL schema for Ejabberd exists (including MUC tables).
# NOTE: MySQL's docker-entrypoint init scripts only run on first boot of an empty datadir.
# On updates, it's common to have an existing /var/lib/mysql volume with a partial schema.
# Missing muc_* tables causes ejabberd muc_room commands to return "Database error", and XMPP joins/sends fail.
log "Ensuring MySQL Ejabberd schema (muc_* tables)..."
if ! docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1 FROM information_schema.tables WHERE table_schema='ejabberd_db' AND table_name='muc_room' LIMIT 1;" 2>/dev/null | grep -q "1"; then
    warn "MySQL ejabberd_db.muc_room table missing; applying schema from /docker-entrypoint-initdb.d/01.sql..."
    if docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql sh -lc "mysql -uroot -p\"$MYSQL_ROOT_PASSWORD\" < /docker-entrypoint-initdb.d/01.sql" >/dev/null 2>&1; then
        log "Ejabberd MySQL schema applied successfully"
    else
        warn "Failed to apply Ejabberd MySQL schema (XMPP MUC may not work until fixed)"
    fi
else
    log "Ejabberd MySQL schema looks OK (muc_room table exists)"
fi

# Ensure a dedicated MySQL user exists for ejabberd. Using root from a container IP can fail on some MySQL setups (1045).
# We intentionally reuse MYSQL_ROOT_PASSWORD as the ejabberd DB user's password to avoid introducing new secrets.
log "Ensuring MySQL user 'ejabberd'@'%' exists and can access ejabberd_db..."
mysql_pw_escaped="${MYSQL_ROOT_PASSWORD//\'/\'\'}"
docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql sh -lc "mysql -uroot -p\"$MYSQL_ROOT_PASSWORD\" -e \"CREATE USER IF NOT EXISTS 'ejabberd'@'%' IDENTIFIED BY '${mysql_pw_escaped}'; GRANT ALL PRIVILEGES ON ejabberd_db.* TO 'ejabberd'@'%'; FLUSH PRIVILEGES;\" " >/dev/null 2>&1 || warn "Failed to ensure ejabberd MySQL user (may already exist or MySQL not ready yet)"

# Wait for Ejabberd to be ready
# NOTE: install.sh already waits for ejabberd health before calling init-services.sh.
# Here we only do a short confirmation check to avoid spending minutes on slow timeouts.
log "Waiting for Ejabberd to be ready..."
if xmpp_container="$(get_xmpp_container)"; then
    for i in {1..20}; do
        # Prefer docker health status when available (fast, no exec into container)
        if docker inspect -f '{{.State.Health.Status}}' "$xmpp_container" 2>/dev/null | grep -q '^healthy$'; then
            log "Ejabberd is ready"
            break
        fi
        # Fallback: quick ping
        if ejabberdctl_safe 2 ping > /dev/null 2>&1; then
            log "Ejabberd is ready"
            break
        fi
        if [ $i -eq 20 ]; then
            warn "Ejabberd may not be fully ready, but continuing..."
            warn "XMPP chat will NOT work until ejabberd is reachable on the host (expected: 127.0.0.1:5280)."
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" ps xmpp || true
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" logs --tail 120 xmpp || true
        fi
        sleep 1
    done
else
    warn "Ejabberd container not found; skipping readiness check"
fi

# Create Ejabberd admin user
#
# The uptime health-checker (if running) logs into XMPP as this same admin@$XMPP_DOMAIN
# JID every ~90s for its MUC probe. Before the real SQL-backed admin account exists,
# that login falls through to ejabberd's `anonymous` auth backend (auth_method: [sql,
# jwt, anonymous]), which makes ejabberd's user-exists check see "admin" as already
# taken -- so `ejabberdctl register` keeps failing with "conflict: already registered"
# even though the account was never actually persisted to MySQL. Pausing the uptime
# container for this window removes the colliding anonymous session so registration
# can actually land.
UPTIME_PAUSED_FOR_ADMIN_INIT=false
if [ "${UPTIME_ENABLED:-false}" == "true" ] && [ -f "$DEPLOY_DIR/docker-compose.uptime.yml" ]; then
    if [ -n "$(docker-compose -f "$DEPLOY_DIR/docker-compose.uptime.yml" ps -q uptime 2>/dev/null)" ]; then
        log "Pausing uptime health-checker during Ejabberd admin bootstrap (avoids an admin@ login race)..."
        docker-compose -f "$DEPLOY_DIR/docker-compose.uptime.yml" stop uptime >/dev/null 2>&1 \
            && UPTIME_PAUSED_FOR_ADMIN_INIT=true \
            || warn "Failed to pause uptime health-checker; admin creation may race with it"
    fi
fi

log "Creating Ejabberd admin user..."
EJABBERD_ADMIN_LOG="$STATE_DIR/ejabberd-admin-init.log"
: > "$EJABBERD_ADMIN_LOG" 2>/dev/null || true
if ensure_ejabberd_admin_loop 120 >>"$EJABBERD_ADMIN_LOG" 2>&1; then
    log "Ejabberd admin user ready: admin@$XMPP_DOMAIN"
else
    warn "Ejabberd admin creation did not complete successfully."
    warn "You can inspect the log at: $EJABBERD_ADMIN_LOG"
fi

if [ "$UPTIME_PAUSED_FOR_ADMIN_INIT" == "true" ]; then
    log "Resuming uptime health-checker..."
    docker-compose -f "$DEPLOY_DIR/docker-compose.uptime.yml" start uptime >/dev/null 2>&1 \
        || warn "Failed to resume uptime health-checker (uptime service)"
fi

# Get paths from environment or use defaults
BACKEND_DIR="${BACKEND_DIR:-$ROOT_DIR/ethora-backend}"
PLAYGROUND_DIR="${PLAYGROUND_DIR:-$ROOT_DIR/ethora-sdk-playground}"

# Backend repo layout support:
# - legacy layout:   $BACKEND_DIR/backend, $BACKEND_DIR/ai_service, $BACKEND_DIR/docs_parse_service
# - new layout:      $BACKEND_DIR/services/api, $BACKEND_DIR/services/ai/ai-service, $BACKEND_DIR/services/ai/docs-parse
if [ -d "$BACKEND_DIR/services/api" ]; then
    BACKEND_API_DIR="$BACKEND_DIR/services/api"
    AI_SERVICE_DIR="$BACKEND_DIR/services/ai/ai-service"
    DOCS_PARSE_DIR="$BACKEND_DIR/services/ai/docs-parse"
else
    BACKEND_API_DIR="$BACKEND_DIR/backend"
    AI_SERVICE_DIR="$BACKEND_DIR/ai_service"
    DOCS_PARSE_DIR="$BACKEND_DIR/docs_parse_service"
fi

# Initialize base app in backend
log "Initializing base app in backend..."
mkdir -p "$BACKEND_API_DIR" 2>/dev/null || true
cd "$BACKEND_API_DIR" || error "Failed to change to backend directory: $BACKEND_API_DIR"

# Verify Node.js is available (on the host, or via the API image in image mode)
if ! have_backend_node; then
    error "Node.js is not installed or not in PATH"
fi

# Set environment variables for the init script
export MONGO_URI="mongodb://localhost:${MONGO_PORT}/${MONGO_DB}?directConnection=true"
export PLATFORM_ACCOUNT_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
export PLATFORM_ACCOUNT_PASSWORD="${ADMIN_PASSWORD:-admin123}"
export BASE_APP_DISPLAY_NAME="${BASE_APP_DISPLAY_NAME:-Ethora}"
export BASE_APP_DOMAIN_NAME="${BASE_APP_DOMAIN_NAME:-}"
export BASE_APP_OWNER_EMAIL="${BASE_APP_OWNER_EMAIL:-$ADMIN_EMAIL}"
export BASE_APP_OWNER_PASSWORD="${BASE_APP_OWNER_PASSWORD:-$ADMIN_PASSWORD}"
export JWT_SECRET="${JWT_SECRET:-your-secret-key-change-in-production}"

# If base app slug is not provided, derive it from the web domain (consistent with install.sh / setup-env.sh).
if [ -z "$BASE_APP_DOMAIN_NAME" ] || [ "$BASE_APP_DOMAIN_NAME" == "null" ]; then
    if [ "${WEB_DOMAIN:-}" == "localhost" ] || [ -z "${WEB_DOMAIN:-}" ]; then
        export BASE_APP_DOMAIN_NAME="ethora"
    else
        export BASE_APP_DOMAIN_NAME="$(echo "$WEB_DOMAIN" | cut -d'.' -f1)"
    fi
fi

# Run the initialization script
if [ "$BACKEND_MODE" = "image" ] || [ -f "scripts/initEthoraApp.js" ]; then
    log "Running initEthoraApp.js..."
    if [ "$BACKEND_MODE" != "image" ]; then
        ensure_backend_node_modules "$BACKEND_API_DIR" || warn "Failed to ensure backend dependencies (initEthoraApp.js may fail)"
    fi
    # Silence one-off Mongoose deprecation noise during initialization only.
    if NODE_OPTIONS="--no-deprecation" backend_node scripts/initEthoraApp.js; then
        log "✅ Base app initialization completed successfully"
    else
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            # Script exits with 0 if app already exists (idempotent behavior)
            log "ℹ️  Base app already exists (skipped creation)"
        else
            warn "Base app initialization exited with code $exit_code (app may already exist or there was an error)"
            # Don't fail the entire deployment - the script is idempotent
        fi
    fi
else
    error "initEthoraApp.js not found at $BACKEND_API_DIR/scripts/initEthoraApp.js - base app initialization is required"
fi

# If SDK playground is enabled, auto-populate App ID/Secret from Mongo and refresh .env.local.
sync_playground_credentials() {
    if [ "${PLAYGROUND_ENABLED:-false}" != "true" ]; then
        return 0
    fi

    if [ ! -f "$PLAYGROUND_DIR/package.json" ]; then
        warn "SDK playground sources not found at $PLAYGROUND_DIR (submodule not initialized?)"
        return 0
    fi

    local app_id=""
    local app_secret=""
    local explicit_app_id=""
    local explicit_app_secret=""

    if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
        explicit_app_id="$(yq eval '.playground.app_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
        explicit_app_secret="$(yq eval '.playground.app_secret // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
        [ "$explicit_app_id" = "null" ] && explicit_app_id=""
        [ "$explicit_app_secret" = "null" ] && explicit_app_secret=""
    fi

    # Explicit deploy.yml values win. Otherwise, derive the current base-app credentials
    # from Mongo so stale persisted PLAYGROUND_* values do not survive reinstall/update cycles.
    if [ -n "$explicit_app_id" ] && [ -n "$explicit_app_secret" ]; then
        app_id="$explicit_app_id"
        app_secret="$explicit_app_secret"
    else
        # Try to read from Mongo via mongosh (fast path).
        local js="
const dbName = '${MONGO_DB}';
const domain = '${BASE_APP_DOMAIN_NAME}';
const app = db.getSiblingDB(dbName).apps.findOne({ domainName: domain }, { appSecret: 1, tenantSecret: 1 });
if (app) {
  const b64 = v => Buffer.from(String(v || ''), 'utf8').toString('base64');
  const authSecret = app.tenantSecret || app.appSecret || '';
  print('ETHORA_PLAYGROUND_APP_ID_B64=' + b64(app._id));
  print('ETHORA_PLAYGROUND_APP_SECRET_B64=' + b64(authSecret));
}
"
        local out=""
        out="$(mongo_eval_safe 8 "$js" 2>/dev/null || true)"
        if [ -n "$out" ]; then
            local id_b64=""
            local secret_b64=""
            id_b64="$(echo "$out" | grep -m1 '^ETHORA_PLAYGROUND_APP_ID_B64=' | sed 's/^[^=]*=//')"
            secret_b64="$(echo "$out" | grep -m1 '^ETHORA_PLAYGROUND_APP_SECRET_B64=' | sed 's/^[^=]*=//')"
            if [ -n "$id_b64" ] && [ -n "$secret_b64" ] && command -v base64 >/dev/null 2>&1; then
                app_id="$(echo "$id_b64" | base64 -d 2>/dev/null || true)"
                app_secret="$(echo "$secret_b64" | base64 -d 2>/dev/null || true)"
            fi
        fi

        # Fallback: query Mongo using backend models (handles mongosh empty stdout issues).
        if [ -z "$app_id" ] || [ -z "$app_secret" ]; then
            if have_backend_node; then
                [ "$BACKEND_MODE" = "image" ] || ensure_backend_node_modules "$BACKEND_API_DIR" >/dev/null 2>&1 || true
                local node_out=""
                node_out="$(backend_node scripts/deploy/playground-app-secret.js "${MONGO_URI}" "${BASE_APP_DOMAIN_NAME}" 2>/dev/null || true)"
                if [ -n "$node_out" ]; then
                    local id_b64=""
                    local secret_b64=""
                    id_b64="$(echo "$node_out" | grep -m1 '^ETHORA_PLAYGROUND_APP_ID_B64=' | sed 's/^[^=]*=//')"
                    secret_b64="$(echo "$node_out" | grep -m1 '^ETHORA_PLAYGROUND_APP_SECRET_B64=' | sed 's/^[^=]*=//')"
                    if [ -n "$id_b64" ] && [ -n "$secret_b64" ] && command -v base64 >/dev/null 2>&1; then
                        app_id="$(echo "$id_b64" | base64 -d 2>/dev/null || true)"
                        app_secret="$(echo "$secret_b64" | base64 -d 2>/dev/null || true)"
                    fi
                fi
            fi
        fi

        if [ -z "$app_id" ] || [ -z "$app_secret" ]; then
            if [ -n "${PLAYGROUND_APP_ID:-}" ] && [ -n "${PLAYGROUND_APP_SECRET:-}" ]; then
                warn "Falling back to existing PLAYGROUND_APP_ID / PLAYGROUND_APP_SECRET because current base-app credentials could not be derived from Mongo."
                app_id="${PLAYGROUND_APP_ID}"
                app_secret="${PLAYGROUND_APP_SECRET}"
            fi
        fi
    fi

    if [ -z "$app_id" ] || [ -z "$app_secret" ]; then
        warn "SDK playground credentials not found for base app domain '${BASE_APP_DOMAIN_NAME}'."
        warn "Playground will start but SDK calls may fail until credentials are set."
        return 0
    fi

    # Persist into .deploy.env for future runs (non-fatal if it fails).
    if [ -n "${DEPLOY_DIR:-}" ] && [ -f "$DEPLOY_DIR/.deploy.env" ]; then
        local tmp_env
        tmp_env="$(mktemp)"
        grep -v '^PLAYGROUND_APP_ID=' "$DEPLOY_DIR/.deploy.env" >"$tmp_env" 2>/dev/null || true
        grep -v '^PLAYGROUND_APP_SECRET=' "$tmp_env" >"${tmp_env}.2" 2>/dev/null || true
        mv "${tmp_env}.2" "$tmp_env"
        echo "PLAYGROUND_APP_ID=$app_id" >>"$tmp_env"
        echo "PLAYGROUND_APP_SECRET=$app_secret" >>"$tmp_env"
        mv "$tmp_env" "$DEPLOY_DIR/.deploy.env"
    fi

    # Generate .env.local for playground
    local api_url=""
    local backend_url=""
    if [ "${API_DOMAIN:-}" == "localhost" ]; then
        api_url="http://localhost:${BACKEND_PORT:-8080}"
        backend_url="http://localhost:${PLAYGROUND_PORT:-3020}"
    else
        api_url="https://${API_DOMAIN}"
        if [ -n "${PLAYGROUND_DOMAIN:-}" ] && [ "${PLAYGROUND_DOMAIN:-}" != "null" ]; then
            backend_url="https://${PLAYGROUND_DOMAIN}"
        else
            backend_url="https://${WEB_DOMAIN}"
        fi
    fi

    cat > "$PLAYGROUND_DIR/.env.local" <<EOF
ETHORA_CHAT_API_URL=${api_url}
NEXT_PUBLIC_ETHORA_CHAT_API_URL=${api_url}
ETHORA_CHAT_APP_ID=${app_id}
ETHORA_CHAT_APP_SECRET=${app_secret}
NEXT_PUBLIC_BACKEND_URL=${backend_url}
EOF
    log "SDK playground credentials synced to $PLAYGROUND_DIR/.env.local"
}

# Sync playground credentials after base app is initialized.
sync_playground_credentials || true

# Verify the base app config is actually retrievable (frontend blocks on this).
# If this returns 404, the frontend will show an infinite spinner while retrying.
if command -v curl >/dev/null 2>&1; then
    # NOTE: At this point in the installer, the backend API may not be running yet (it is started later by setup-node-services.sh).
    # Only perform this check if /ping is responding, otherwise we'd emit a misleading warning.
    if curl -fsS "http://127.0.0.1:${BACKEND_PORT:-8080}/ping" >/dev/null 2>&1; then
        # Prefer localhost backend to avoid any nginx/SSL/DNS issues.
        if ! curl -fsS "http://127.0.0.1:${BACKEND_PORT:-8080}/v1/apps/get-config?domainName=${BASE_APP_DOMAIN_NAME}" >/dev/null 2>&1; then
            warn "Base app config not found for domainName='${BASE_APP_DOMAIN_NAME}'."
            warn "Make sure deploy.yml base_app.domain_name (or derived domains.web subdomain) matches the frontend VITE_DOMAIN_NAME."
        fi
    else
        log "Backend /ping is not responding yet; skipping base app config HTTP check (will be covered by health-check)."
    fi
fi

# Ensure the base app's XMPP user exists in ejabberd (fixes frontend SASL not-authorized).
ensure_base_app_xmpp_users || true

# Push deploy.yml `translate.languages` into the database, where get-config
# reads it from. Runs on every install AND update (update.sh calls this script),
# so narrowing or widening the list is a deploy.yml edit plus an update - no
# manual database step.
#
# The backend script is idempotent and writes only when the list actually
# changed, so the common case is a no-op. Non-fatal: an install whose
# translation server languages did not sync is still a working install, it just
# keeps serving the previous list (or [] on a fresh one).
sync_translate_languages() {
    if [ ! -f "$BACKEND_API_DIR/src/utils/scripts/syncTranslateLanguages.js" ]; then
        log "syncTranslateLanguages.js not present in this backend build; skipping translate language sync"
        return 0
    fi
    if ! command -v node >/dev/null 2>&1; then
        warn "node not found; skipping translate language sync"
        return 0
    fi

    # Pass the value explicitly rather than relying on which .env this process
    # loaded - setup-env.sh has already rendered it, and being explicit keeps
    # the clearing case ("" means remove every language) unambiguous.
    local languages="${TRANSLATE_LANGUAGES:-}"
    local out
    if out="$(run_as_deploy_user "cd \"$BACKEND_API_DIR\" && NODE_NO_WARNINGS=1 node src/utils/scripts/syncTranslateLanguages.js \"$languages\"" 2>&1)"; then
        log "Translate languages: ${out}"
    else
        warn "Translate language sync failed (non-fatal): $(echo "$out" | tr '\n' ' ' | head -c 240)"
    fi
}

sync_translate_languages || true

log "Service initialization completed"

# Final check for ejabberd admin user (non-fatal)
if ! ejabberd_admin_exists; then
    warn "Ejabberd admin user is still not available at end of init. Chat may not work until it is created."
    if [ -n "${EJABBERD_ADMIN_LOG:-}" ]; then
        warn "Ejabberd admin creation log: ${EJABBERD_ADMIN_LOG}"
    fi
fi

