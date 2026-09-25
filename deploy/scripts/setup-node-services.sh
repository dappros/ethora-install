#!/bin/bash

# Node.js Services Setup Script
# Builds and starts Node.js services using PM2

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
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

ensure_global_npm_version() {
    local target_version="${ETHORA_NPM_VERSION:-11.12.1}"
    local current_version lowest_version

    if ! command -v npm >/dev/null 2>&1; then
        return 0
    fi

    current_version="$(npm --version 2>/dev/null || echo '')"
    if [ -z "$current_version" ] || [ "$current_version" = "$target_version" ]; then
        return 0
    fi

    lowest_version="$(printf '%s\n%s\n' "$current_version" "$target_version" | sort -V | head -n1)"
    if [ "$lowest_version" = "$target_version" ]; then
        return 0
    fi

    log "Upgrading npm from ${current_version} to ${target_version}..."
    npm install -g "npm@${target_version}" >/dev/null 2>&1 \
        || warn "Failed to upgrade npm to ${target_version}; continuing with ${current_version}"
}

# Wait for an HTTP endpoint to respond.
wait_for_http() {
    local name="$1"
    local url="$2"
    local timeout="${3:-60}"
    local interval="${4:-2}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -fsS "$url" >/dev/null 2>&1; then
            log "$name is responding: $url"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

# Ensure nginx can read built static assets served from user-owned directories.
ensure_nginx_can_read_static_dir() {
    local target_dir="$1"
    local label="${2:-static assets}"
    if [ -z "$target_dir" ] || [ ! -d "$target_dir" ]; then
        return 0
    fi

    # Prefer ACLs (least invasive). Fall back to world-traverse if ACL tooling isn't available.
    if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
        log "Ensuring nginx (www-data) can read ${label} via ACLs..."
        # Nginx must be able to traverse parent directories too (common issue under /home/<user>/...).
        local d1 d2 d3
        d1="$(dirname "$target_dir")"
        d2="$(dirname "$d1")"
        d3="$(dirname "$d2")"
        sudo setfacl -m u:www-data:rx "$target_dir" "$d1" "$d2" "$d3" 2>/dev/null || true
        # Also grant traverse on /home and /home/<user> if applicable.
        if echo "$target_dir" | grep -qE '^/home/[^/]+/'; then
            local home_parent="/home"
            local user_home
            user_home="/home/$(echo "$target_dir" | cut -d'/' -f3)"
            sudo setfacl -m u:www-data:rx "$home_parent" "$user_home" 2>/dev/null || true
        fi
        sudo setfacl -R -m u:www-data:rx "$target_dir" 2>/dev/null || true
        sudo setfacl -dR -m u:www-data:rx "$target_dir" 2>/dev/null || true
    else
        warn "setfacl/getfacl not found. Falling back to chmod o+rx on parent dirs so nginx can serve ${label}."
        # Walk up a few levels (dist -> app dir -> base dir) but avoid being overly clever; chmod failures are non-fatal.
        sudo chmod o+rx "$(dirname "$target_dir")" 2>/dev/null || true
        sudo chmod o+rx "$(dirname "$(dirname "$target_dir")")" 2>/dev/null || true
        sudo chmod o+rx "$target_dir" 2>/dev/null || true
    fi

    sudo chown -R "${SUDO_USER:-ubuntu}:www-data" "$target_dir" 2>/dev/null || true
    sudo find "$target_dir" -type d -exec chmod 755 {} \; 2>/dev/null || true
    sudo find "$target_dir" -type f -exec chmod 644 {} \; 2>/dev/null || true
}

finalize_widget_assets() {
    local dist_dir="$1"
    local version="${2:-}"
    if [ -z "$dist_dir" ] || [ ! -d "$dist_dir" ] || [ ! -f "$dist_dir/ethora_assistant.js" ]; then
        return 0
    fi

    cp -f "$dist_dir/ethora_assistant.js" "$dist_dir/assistant.js"
    if [ -n "$version" ]; then
        cp -f "$dist_dir/ethora_assistant.js" "$dist_dir/assistant${version}.js"
    fi

    if [ -f "$dist_dir/ethora_assistant.js.map" ]; then
        cp -f "$dist_dir/ethora_assistant.js.map" "$dist_dir/assistant.js.map"
        if [ -n "$version" ]; then
            cp -f "$dist_dir/ethora_assistant.js.map" "$dist_dir/assistant${version}.js.map"
        fi
    fi
}

# Run a command as the non-root deploying user when possible.
# This avoids root-owned node_modules and ensures PM2 runs under the correct user.
run_as_deploy_user() {
    local cmd="$1"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        sudo -u "$SUDO_USER" -H bash -lc "source \"$ENV_FILE\" >/dev/null 2>&1 || true; $cmd"
    else
        bash -lc "source \"$ENV_FILE\" >/dev/null 2>&1 || true; $cmd"
    fi
}

# When AI features are disabled in deploy.yml, drop the @ethora/ai-chat-widget
# dependency from the frontend's package.json + lockfile before npm install.
# Without this, npm would still fetch the GitHub-pinned ref declared in
# ethora-app-reactjs/package.json -- wasted bandwidth, time, and disk for
# customers whose contract excludes AI. The frontend's
# src/pages/AppSettings/AIWidget.tsx still imports from @ethora/ai-chat-widget
# at compile time; install_ai_widget_stub_when_disabled below provides a
# no-op stub that satisfies the import without building the real widget.
#
# Operates only on the frontend tree and leaves the canonical source repo
# untouched (rsync from source restores package.json on the next AI-enabled
# run).
strip_ai_widget_dep_when_disabled() {
    local frontend_dir="$1"
    [ -n "$frontend_dir" ] || return 0
    [ "$frontend_dir" = "${ROOT_DIR:-}/ethora-app-reactjs" ] || return 0
    [ "${AI_SERVICE_ENABLED:-false}" != "true" ] || return 0
    [ -f "$frontend_dir/package.json" ] || return 0

    run_as_deploy_user "APP_DIR=\"$frontend_dir\" python3 - <<'PY'
from pathlib import Path
import json
import os

app_dir = Path(os.environ['APP_DIR'])
pkg_path = app_dir / 'package.json'
lock_path = app_dir / 'package-lock.json'
target = '@ethora/ai-chat-widget'

pkg = json.loads(pkg_path.read_text())
deps = pkg.get('dependencies', {})
changed = False
if target in deps:
    del deps[target]
    changed = True
dev_deps = pkg.get('devDependencies', {})
if target in dev_deps:
    del dev_deps[target]
    changed = True
if changed:
    pkg_path.write_text(json.dumps(pkg, indent=2) + '\n')

if lock_path.exists():
    lock = json.loads(lock_path.read_text())
    lock_changed = False
    root_pkg = lock.get('packages', {}).get('', {})
    for key in ('dependencies', 'devDependencies'):
        sub = root_pkg.get(key, {})
        if target in sub:
            del sub[target]
            lock_changed = True
    nm_path = 'node_modules/' + target
    if nm_path in lock.get('packages', {}):
        del lock['packages'][nm_path]
        lock_changed = True
    legacy_deps = lock.get('dependencies', {})
    if target in legacy_deps:
        del legacy_deps[target]
        lock_changed = True
    if lock_changed:
        lock_path.write_text(json.dumps(lock, indent=2) + '\n')
PY" || warn "Failed to strip @ethora/ai-chat-widget from frontend package.json"
}

# Companion to strip_ai_widget_dep_when_disabled: when AI features are
# disabled in deploy.yml we drop the real @ethora/ai-chat-widget dep, but
# the frontend's src/pages/AppSettings/AIWidget.tsx still imports from it
# (`AiAssistant`, `XmppProvider`, `createAnonymousXmppCredentials`). To let
# `tsc -b && vite build` succeed without actually fetching/building the
# ~1.2MB widget bundle (~24s npm install + ~32s vite build:lib), we write a
# tiny no-op package into node_modules/@ethora/ai-chat-widget/. At runtime
# the AIWidget settings page still renders, but its widget-backed components
# do nothing (which is correct -- AI is off).
#
# Idempotent: safe to call on every ensure_node_deps invocation.
install_ai_widget_stub_when_disabled() {
    local frontend_dir="$1"
    [ -n "$frontend_dir" ] || return 0
    [ "$frontend_dir" = "${ROOT_DIR:-}/ethora-app-reactjs" ] || return 0
    [ "${AI_SERVICE_ENABLED:-false}" != "true" ] || return 0
    [ -d "$frontend_dir/node_modules" ] || return 0

    log "Installing no-op @ethora/ai-chat-widget stub in frontend node_modules (AI features disabled in deploy.yml)..."
    run_as_deploy_user "APP_DIR=\"$frontend_dir\" python3 - <<'PY'
import os
from pathlib import Path

app_dir = Path(os.environ['APP_DIR'])
stub_dir = app_dir / 'node_modules' / '@ethora' / 'ai-chat-widget'
dist_dir = stub_dir / 'dist'
dist_dir.mkdir(parents=True, exist_ok=True)

# package.json: declares main + types so node/bundler resolution finds dist/main.{js,d.ts}.
# A stable version string ('0.0.0-deploy-stub') makes it obvious in 'npm ls' that
# this is not the real package.
(stub_dir / 'package.json').write_text(
    '{\n'
    '  \"name\": \"@ethora/ai-chat-widget\",\n'
    '  \"version\": \"0.0.0-deploy-stub\",\n'
    '  \"description\": \"Deploy-time no-op stub. Real package: github:dappros/ai-assistant-ui. Replaced because services.ai_service.enabled / features.ai_service is false in deploy.yml.\",\n'
    '  \"type\": \"module\",\n'
    '  \"main\": \"dist/main.js\",\n'
    '  \"module\": \"dist/main.js\",\n'
    '  \"types\": \"dist/main.d.ts\",\n'
    '  \"sideEffects\": false\n'
    '}\n'
)

# Runtime no-op exports. Names mirror the real package's exports that the
# frontend currently consumes (see src/pages/AppSettings/AIWidget.tsx).
# XmppProvider must pass children through so any sibling JSX still mounts;
# AiAssistant and createAnonymousXmppCredentials simply produce nothing.
(dist_dir / 'main.js').write_text(
    '// Auto-generated by deploy/scripts/setup-node-services.sh\n'
    '// when AI features are disabled in deploy.yml. Do not edit by hand.\n'
    'export const AiAssistant = () => null;\n'
    'export const XmppProvider = (props) => (props && props.children !== undefined ? props.children : null);\n'
    'export const createAnonymousXmppCredentials = () => ({});\n'
    'export default {};\n'
)

# Type declarations for the names AIWidget.tsx imports. Use any to avoid
# coupling this stub to the real widgets evolving public types.
(dist_dir / 'main.d.ts').write_text(
    '// Auto-generated by deploy/scripts/setup-node-services.sh\n'
    '// when AI features are disabled in deploy.yml. Do not edit by hand.\n'
    'export declare const AiAssistant: any;\n'
    'export declare const XmppProvider: any;\n'
    'export declare const createAnonymousXmppCredentials: () => any;\n'
    'declare const _default: any;\n'
    'export default _default;\n'
)
PY" || warn "Failed to install @ethora/ai-chat-widget stub"
}

ensure_ai_postgres_schema() {
    local ai_dir="$1"
    local ai_env_file="$ai_dir/.env"
    local migration_file="$ai_dir/drizzle/0000_massive_fat_cobra.sql"
    local script_file=""

    if { [ -z "${AI_PG_URL:-}" ] || [ "${AI_PG_URL:-}" == "null" ]; } && [ -f "$ai_env_file" ]; then
        AI_PG_URL="$(awk -F= '/^PG_URL=/{sub(/^PG_URL=/, ""); print; exit}' "$ai_env_file")"
        export AI_PG_URL
    fi

    if [ -z "${AI_PG_URL:-}" ] || [ "${AI_PG_URL:-}" == "null" ]; then
        error "AI_PG_URL is empty. Run setup-env.sh first, or set services.ai_service.pg_url, or use the managed AI Postgres defaults."
    fi
    if [ ! -f "$migration_file" ]; then
        error "AI Postgres migration file not found: $migration_file"
    fi

    script_file="$(mktemp "${TMPDIR:-/tmp}/ethora-ai-schema.XXXXXX.cjs")"
    cat >"$script_file" <<'EOF'
const fs = require('fs');
const { createRequire } = require('module');

async function main() {
  const appDir = process.env.AI_PG_APP_DIR || process.cwd();
  const pgUrl = process.env.AI_PG_URL || process.env.PG_URL || '';
  const migrationFile = process.env.AI_PG_MIGRATION_FILE || '';
  const requireFromApp = createRequire(`${appDir.replace(/\/$/, '')}/package.json`);
  const { Client } = requireFromApp('pg');
  if (!pgUrl) throw new Error('AI_PG_URL is empty');
  if (!migrationFile) throw new Error('AI_PG_MIGRATION_FILE is empty');

  const sql = fs.readFileSync(migrationFile, 'utf8');
  const statements = sql
    .split(/--> statement-breakpoint/g)
    .map((statement) => statement.trim())
    .filter(Boolean);

  const isIgnorableSchemaError = (error) => {
    const code = error && error.code ? String(error.code) : '';
    const message = error && error.message ? String(error.message) : '';
    return code === '42P07' || code === '42710' || /already exists/i.test(message);
  };

  const client = new Client({ connectionString: pgUrl });
  await client.connect();
  try {
    for (const statement of statements) {
      try {
        await client.query(statement);
      } catch (error) {
        if (!isIgnorableSchemaError(error)) {
          throw error;
        }
      }
    }

    const extensionResult = await client.query(
      "SELECT 1 FROM pg_extension WHERE extname = 'vector' LIMIT 1"
    );
    if (extensionResult.rowCount === 0) {
      throw new Error('pgvector extension was not created');
    }

    const tableResult = await client.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'documents' LIMIT 1"
    );
    if (tableResult.rowCount === 0) {
      throw new Error('documents table was not created');
    }
  } finally {
    await client.end().catch(() => {});
  }
}

main()
  .then(() => {
    console.log('AI Postgres schema is ready');
  })
  .catch((error) => {
    console.error(error && error.message ? error.message : error);
    process.exit(1);
  });
EOF
    chmod 644 "$script_file" 2>/dev/null || true

    log "Initializing AI Postgres schema..."
    if [ "${AI_MODE:-source}" = "image" ]; then
        # No host node_modules in image mode: run the same script inside the
        # AI image, whose /app/ai-service carries pg and the drizzle migrations.
        docker run --rm --network host -v /tmp:/tmp -w /app/ai-service \
            -e AI_PG_URL="$AI_PG_URL" -e AI_PG_APP_DIR=/app/ai-service \
            -e AI_PG_MIGRATION_FILE="/app/ai-service/drizzle/$(basename "$migration_file")" \
            --entrypoint node "$ETHORA_AI_IMAGE" "$script_file" \
            || error "Failed to initialize AI Postgres schema (image mode)"
    else
    run_as_deploy_user "cd \"$ai_dir\" && AI_PG_URL=\"$AI_PG_URL\" AI_PG_APP_DIR=\"$ai_dir\" AI_PG_MIGRATION_FILE=\"$migration_file\" node \"$script_file\"" \
        || error "Failed to initialize AI Postgres schema"
    fi
    rm -f "$script_file" 2>/dev/null || true
}

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
    # Very old systems: no hash tool. Return empty string (forces install).
    echo ""
}

# Ensure dependencies are installed AND up-to-date with the lockfile.
# This avoids a common failure mode where node_modules exists from a previous install
# but package.json / package-lock.json changed (e.g. new deps like `helmet`).
ensure_node_deps() {
    local dir="$1"
    local required_module="${2:-}"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        warn "Dependency install skipped; directory not found: $dir"
        return 0
    fi
    # An uninitialized submodule is an empty directory, which passes the check
    # above and then makes npm fail with an ENOENT on package.json that reads
    # like a broken install rather than a missing checkout. Say what it is.
    if [ ! -f "$dir/package.json" ]; then
        warn "Dependency install skipped; no package.json in $dir (submodule not initialized?)"
        return 0
    fi

    local stamp_dir="$dir/.ethora_deploy"
    local stamp_file="$stamp_dir/deps.sha256"
    local lockfile=""
    local current_hash=""
    local use_local_frontend_package_overrides="false"
    local local_chat_component_dir=""
    local local_ai_widget_dir=""

    if [ "$dir" = "${ROOT_DIR:-}/ethora-app-reactjs" ]; then
        if [ -f "${ROOT_DIR:-}/ethora-chat-component/package.json" ]; then
            use_local_frontend_package_overrides="true"
            local_chat_component_dir="${ROOT_DIR:-}/ethora-chat-component"
        fi
        # Only treat the local AI widget folder as a frontend dep override when
        # AI features are enabled. Otherwise we'd burn ~24s of npm install +
        # ~32s of vite build:lib on every deploy for customers whose contract
        # excludes AI (and whose frontend doesn't actually import the widget).
        if [ "${AI_SERVICE_ENABLED:-false}" == "true" ] && [ -f "${ROOT_DIR:-}/ethora-ai-chat-widget/package.json" ]; then
            use_local_frontend_package_overrides="true"
            local_ai_widget_dir="${ROOT_DIR:-}/ethora-ai-chat-widget"
        fi
    fi

    if [ -f "$dir/pnpm-lock.yaml" ]; then
        lockfile="$dir/pnpm-lock.yaml"
    elif [ -f "$dir/package-lock.json" ]; then
        lockfile="$dir/package-lock.json"
    elif [ -f "$dir/package.json" ]; then
        lockfile="$dir/package.json"
    fi

    if [ -n "$lockfile" ]; then
        current_hash="$(hash_file_sha256 "$lockfile")"
    fi

    if [ "$use_local_frontend_package_overrides" = "true" ]; then
        local local_dep_hashes=""
        if [ -n "$local_chat_component_dir" ]; then
            local_dep_hashes="${local_dep_hashes} $(project_tree_sha256 "$local_chat_component_dir")"
        fi
        if [ -n "$local_ai_widget_dir" ]; then
            local_dep_hashes="${local_dep_hashes} $(project_tree_sha256 "$local_ai_widget_dir")"
        fi
        if [ -n "$local_dep_hashes" ]; then
            if command -v sha256sum >/dev/null 2>&1; then
                current_hash="$(printf '%s %s\n' "$current_hash" "$local_dep_hashes" | sha256sum | awk '{print $1}')"
            elif command -v shasum >/dev/null 2>&1; then
                current_hash="$(printf '%s %s\n' "$current_hash" "$local_dep_hashes" | shasum -a 256 | awk '{print $1}')"
            fi
        fi
    fi

    # Mix the AI service flag into the frontend dep hash so that flipping
    # services.ai_service.enabled in deploy.yml invalidates the cached
    # node_modules and re-runs npm install. Without this, after we strip the
    # @ethora/ai-chat-widget dep from package.json (when AI is off), a later
    # rsync that restores the canonical package.json would NOT trigger a
    # reinstall, because the lockfile hash matches the recorded stamp -- so
    # re-enabling AI would leave the widget uninstalled until cache cleared.
    if [ "$dir" = "${ROOT_DIR:-}/ethora-app-reactjs" ] && [ -n "$current_hash" ]; then
        local ai_flag_token="ai:${AI_SERVICE_ENABLED:-false}"
        if command -v sha256sum >/dev/null 2>&1; then
            current_hash="$(printf '%s %s\n' "$current_hash" "$ai_flag_token" | sha256sum | awk '{print $1}')"
        elif command -v shasum >/dev/null 2>&1; then
            current_hash="$(printf '%s %s\n' "$current_hash" "$ai_flag_token" | shasum -a 256 | awk '{print $1}')"
        fi
    fi

    local need_install=false
    if [ ! -d "$dir/node_modules" ]; then
        need_install=true
    elif [ -n "$required_module" ] && [ ! -d "$dir/node_modules/$required_module" ]; then
        warn "Missing required dependency '$required_module' in $dir/node_modules; reinstalling..."
        need_install=true
    elif [ ! -f "$stamp_file" ]; then
        need_install=true
    elif [ -z "$current_hash" ]; then
        need_install=true
    elif [ "$(cat "$stamp_file" 2>/dev/null || echo '')" != "$current_hash" ]; then
        need_install=true
    fi

    # Local frontend dependencies (chat-component, ai-chat-widget) must be fully
    # resolved for TypeScript: both the source dist AND the node_modules symlink in
    # the frontend must point to a valid build with type declarations.
    # If anything is missing (submodule re-init, git clean, broken symlink, stale
    # npm install from a GitHub ref instead of local file:), force a full rebuild.
    if [ "$need_install" != "true" ] && [ "$use_local_frontend_package_overrides" = "true" ]; then
        if [ -n "$local_chat_component_dir" ]; then
            if [ ! -d "$local_chat_component_dir/dist" ]; then
                warn "Local @ethora/chat-component dist missing; forcing dependency rebuild..."
                need_install=true
            elif [ ! -f "$dir/node_modules/@ethora/chat-component/dist/main.d.ts" ] 2>/dev/null; then
                warn "Frontend node_modules/@ethora/chat-component types missing; forcing dependency rebuild..."
                need_install=true
            fi
        fi
        if [ -n "$local_ai_widget_dir" ]; then
            if [ ! -d "$local_ai_widget_dir/dist" ]; then
                warn "Local @ethora/ai-chat-widget dist missing; forcing dependency rebuild..."
                need_install=true
            elif [ ! -f "$dir/node_modules/@ethora/ai-chat-widget/dist/main.d.ts" ] 2>/dev/null; then
                warn "Frontend node_modules/@ethora/ai-chat-widget types missing; forcing dependency rebuild..."
                need_install=true
            fi
        fi
    fi

    if [ "$need_install" != "true" ]; then
        # Cache hit. The widget stub still needs to be present in node_modules
        # for the frontend build/typecheck when AI is disabled (e.g., after a
        # previous run installed real widget types and now we've flipped AI
        # off without invalidating node_modules). Idempotent no-op when AI is
        # enabled or when not handling the frontend dir.
        install_ai_widget_stub_when_disabled "$dir"
        return 0
    fi

    # In rsync-based update mode we often run as root, which can leave service directories root-owned.
    # But we intentionally install deps and run PM2 under the non-root deploy user ($SUDO_USER).
    # Ensure the deploy user can create node_modules and stamp files.
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        sudo chown -R "$SUDO_USER":"$SUDO_USER" "$dir" 2>/dev/null || sudo chown -R "$SUDO_USER" "$dir" 2>/dev/null || true
        sudo chmod -R u+rwX "$dir" 2>/dev/null || true
    fi

    log "Installing dependencies in: $dir"
    mkdir -p "$stamp_dir" >/dev/null 2>&1 || true

    # Wipe node_modules when the lockfile content changed since the last
    # successful install. `npm ci` does this itself, but the local-overrides
    # frontend path uses `npm install` (so it can resolve `file:` deps to
    # the just-built chat-component / ai-widget folders) — and `npm install`
    # only adds/updates, it doesn't prune nested copies left over from the
    # previous install. Without this wipe, lockfile changes that move a
    # transitive dep (e.g. a `csstype` override removing a previously-nested
    # @types/react/node_modules/csstype) leave the stale nested copy in
    # place and the frontend's `tsc -b` then sees two structurally-different
    # `CSSProperties` types and refuses to build.
    #
    # Skip on first install (stamp_file absent) — node_modules is either
    # already missing or was just created by something else, no benefit to
    # wiping. Also skip when current_hash is empty (no reliable way to tell
    # whether deps moved).
    if [ -f "$stamp_file" ] && [ -d "$dir/node_modules" ] && [ -n "$current_hash" ]; then
        local previous_hash
        previous_hash="$(cat "$stamp_file" 2>/dev/null || echo '')"
        if [ -n "$previous_hash" ] && [ "$previous_hash" != "$current_hash" ]; then
            log "Lockfile content changed in $dir; wiping node_modules so npm install can resolve cleanly..."
            rm -rf "$dir/node_modules" 2>/dev/null || sudo rm -rf "$dir/node_modules" 2>/dev/null || true
        fi
    fi

    # Reduce npm noise in deploy logs (especially deprecation warnings from transitive deps).
    # This does NOT change behavior; it only controls output.
    local NPM_QUIET_FLAGS="--no-fund --no-audit --loglevel=error"
    local npm_cache_root="$stamp_dir/npm-cache"
    local npm_tmp_root="$stamp_dir/npm-tmp"
    local npm_cache_dir=""
    local npm_tmp_dir=""
    mkdir -p "$npm_cache_root" "$npm_tmp_root" >/dev/null 2>&1 || true
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        sudo chown -R "$SUDO_USER":"$SUDO_USER" "$stamp_dir" "$npm_cache_root" "$npm_tmp_root" 2>/dev/null || sudo chown -R "$SUDO_USER" "$stamp_dir" "$npm_cache_root" "$npm_tmp_root" 2>/dev/null || true
        sudo chmod -R u+rwX "$stamp_dir" "$npm_cache_root" "$npm_tmp_root" 2>/dev/null || true
    fi

    prepare_npm_workdirs() {
        local attempt_label="$1"
        local unique_suffix
        unique_suffix="${attempt_label}-$$-$(date +%s%N)"
        npm_cache_dir="$npm_cache_root/$unique_suffix"
        npm_tmp_dir="$npm_tmp_root/$unique_suffix"
        rm -rf "$npm_cache_dir" "$npm_tmp_dir" 2>/dev/null || true
        mkdir -p "$npm_cache_dir" "$npm_tmp_dir" >/dev/null 2>&1 || true
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
            sudo chown -R "$SUDO_USER":"$SUDO_USER" "$npm_cache_dir" "$npm_tmp_dir" 2>/dev/null || sudo chown -R "$SUDO_USER" "$npm_cache_dir" "$npm_tmp_dir" 2>/dev/null || true
            sudo chmod -R u+rwX "$npm_cache_dir" "$npm_tmp_dir" 2>/dev/null || true
        fi
    }

    cleanup_npm_git_temp_cache() {
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
            sudo chown -R "$SUDO_USER":"$SUDO_USER" "$stamp_dir" "$npm_cache_root" "$npm_tmp_root" "$dir/node_modules" 2>/dev/null || sudo chown -R "$SUDO_USER" "$stamp_dir" "$npm_cache_root" "$npm_tmp_root" "$dir/node_modules" 2>/dev/null || true
            sudo chmod -R u+rwX "$stamp_dir" "$npm_cache_root" "$npm_tmp_root" "$dir/node_modules" 2>/dev/null || true
        fi
        run_as_deploy_user "if [ -d \"$npm_cache_root\" ]; then rm -rf \"$npm_cache_root\"/*; fi; if [ -d \"$npm_tmp_root\" ]; then rm -rf \"$npm_tmp_root\"/*; fi; if [ -d \"$dir/node_modules\" ]; then shopt -s nullglob; for path in \"$dir/node_modules\"/.npm-*; do rm -rf \"\$path\"; done; fi"
    }

    prepare_local_frontend_dependency_overrides() {
        [ "$use_local_frontend_package_overrides" = "true" ] || return 0

        if [ -n "$local_chat_component_dir" ]; then
            log "Preparing local @ethora/chat-component dependency for frontend..."
            ensure_node_deps "$local_chat_component_dir" "typescript"
            run_as_deploy_user "cd \"$local_chat_component_dir\" && npm run build:lib" || error "Failed to build local chat component dependency"
        fi

        if [ -n "$local_ai_widget_dir" ]; then
            log "Preparing local @ethora/ai-chat-widget dependency for frontend..."
            ensure_node_deps "$local_ai_widget_dir" "typescript"
            run_as_deploy_user "cd \"$local_ai_widget_dir\" && npm run build:lib" || error "Failed to build local AI widget dependency"
        fi

        run_as_deploy_user "APP_DIR=\"$dir\" CHAT_COMPONENT_PKG=\"${local_chat_component_dir:+$local_chat_component_dir/package.json}\" AI_WIDGET_PKG=\"${local_ai_widget_dir:+$local_ai_widget_dir/package.json}\" python3 - <<'PY'
from pathlib import Path
import json
import os

app_dir = Path(os.environ['APP_DIR'])
pkg_path = app_dir / 'package.json'
lock_path = app_dir / 'package-lock.json'
pkg = json.loads(pkg_path.read_text())
changed = False

replacements = {}
chat_component_pkg = os.environ.get('CHAT_COMPONENT_PKG', '')
ai_widget_pkg = os.environ.get('AI_WIDGET_PKG', '')

if chat_component_pkg and Path(chat_component_pkg).is_file():
    replacements['@ethora/chat-component'] = 'file:../ethora-chat-component'
if ai_widget_pkg and Path(ai_widget_pkg).is_file():
    replacements['@ethora/ai-chat-widget'] = 'file:../ethora-ai-chat-widget'

for dep_name, dep_value in replacements.items():
    if pkg.get('dependencies', {}).get(dep_name) != dep_value:
        pkg.setdefault('dependencies', {})[dep_name] = dep_value
        changed = True

if changed:
    pkg_path.write_text(json.dumps(pkg, indent=2) + '\n')

if lock_path.exists():
    lock = json.loads(lock_path.read_text())
    root_pkg = lock.setdefault('packages', {}).setdefault('', {})
    root_deps = root_pkg.setdefault('dependencies', {})
    for dep_name, dep_value in replacements.items():
        root_deps[dep_name] = dep_value
    # Drop any pre-existing lockfile entries for the deps we are switching to
    # file: overrides. Mutating them in-place (just rewriting resolved
    # without touching name/version/integrity/link) leaves the lockfile in a
    # state npm 11+ rejects with EMISSINGTARGET because the corresponding
    # ../dep entry is absent. Removing the entries makes npm install rebuild
    # them in npms own canonical format from the file: dep declared in
    # package.json -- no need for us to mirror npms internal lockfile shape,
    # which has shifted between npm v7/v9/v11.
    package_entries = lock.setdefault('packages', {})
    file_package_paths = {
        '@ethora/chat-component': 'node_modules/@ethora/chat-component',
        '@ethora/ai-chat-widget': 'node_modules/@ethora/ai-chat-widget',
    }
    for dep_name, dep_value in replacements.items():
        nm_path = file_package_paths.get(dep_name)
        if nm_path and nm_path in package_entries:
            del package_entries[nm_path]
        if isinstance(dep_value, str) and dep_value.startswith('file:'):
            rel_path = dep_value[len('file:'):]
            if rel_path in package_entries:
                del package_entries[rel_path]
    lock_path.write_text(json.dumps(lock, indent=2) + '\n')
PY"
    }

    run_npm_with_git_cache_recovery() {
        local npm_command="$1"
        local label="$2"
        prepare_npm_workdirs "attempt"
        if run_as_deploy_user "cd \"$dir\" && TMPDIR=\"$npm_tmp_dir\" NPM_CONFIG_CACHE=\"$npm_cache_dir\" $npm_env_prefix $npm_command $NPM_QUIET_FLAGS"; then
            return 0
        fi

        warn "$label failed. Cleaning npm git temp cache and retrying once..."
        cleanup_npm_git_temp_cache
        prepare_npm_workdirs "retry"
        run_as_deploy_user "cd \"$dir\" && TMPDIR=\"$npm_tmp_dir\" NPM_CONFIG_CACHE=\"$npm_cache_dir\" $npm_env_prefix $npm_command $NPM_QUIET_FLAGS"
    }

    # Prefer npm when package-lock.json is present (reduces install warnings and avoids pnpm "approve-builds" prompts).
    #
    # Always force devDependencies to be installed. Every project this script
    # touches gets `npm run build` (tsc, rimraf, ts-node copyAssets, vite build,
    # etc.) right after the install, and those build tools live in
    # devDependencies. If the operator's shell or .npmrc sets
    # NPM_CONFIG_PRODUCTION=true or NODE_ENV=production, `npm ci` / `npm install`
    # silently skip devDeps and the subsequent build fails with
    # `sh: 1: ts-node: not found` or similar. Override here.
    #
    # Previously this was only set when a `required_module` was passed (which
    # the frontend always does), so the backend path silently skipped devDeps
    # on hosts with NODE_ENV=production.
    local npm_env_prefix="NPM_CONFIG_PRODUCTION=false"
    # Drop AI-only frontend deps when AI features are disabled in deploy.yml,
    # before any npm install/ci runs (otherwise npm fetches the GitHub-pinned
    # widget ref). The matching no-op stub is written after install completes,
    # so the frontend's `tsc -b && vite build` can still resolve
    # @ethora/ai-chat-widget imports.
    strip_ai_widget_dep_when_disabled "$dir"
    if [ "$use_local_frontend_package_overrides" = "true" ]; then
        prepare_local_frontend_dependency_overrides
        run_npm_with_git_cache_recovery "npm install" "npm install" || error "Failed to install frontend dependencies with local package overrides in $dir"
    elif [ -f "$dir/package-lock.json" ]; then
            # Some branches have an out-of-sync lockfile. Prefer reproducibility, but fall back gracefully.
            if ! run_npm_with_git_cache_recovery "npm ci" "npm ci"; then
                warn "npm ci failed (lockfile likely out of sync). Falling back to npm install..."
                run_npm_with_git_cache_recovery "npm install" "npm install" || error "Failed to install dependencies with npm in $dir"
            fi
    elif command -v pnpm >/dev/null 2>&1 && [ -f "$dir/pnpm-lock.yaml" ]; then
        run_as_deploy_user "cd \"$dir\" && pnpm install" || error "Failed to install dependencies with pnpm in $dir"
    else
        run_npm_with_git_cache_recovery "npm install" "npm install" || error "Failed to install dependencies with npm in $dir"
    fi

    # After npm install completes, write the no-op widget stub so the
    # frontend can resolve @ethora/ai-chat-widget at compile time. No-op when
    # AI is enabled or when not the frontend dir.
    install_ai_widget_stub_when_disabled "$dir"

    # Record the lockfile hash so future runs can detect changes.
    if [ -n "$current_hash" ]; then
        echo "$current_hash" >"$stamp_file" 2>/dev/null || true
    else
        # No reliable hash; still write a timestamp to avoid repeated installs in the same run.
        date -u +'%Y-%m-%dT%H:%M:%SZ' >"$stamp_file" 2>/dev/null || true
    fi
}

project_tree_sha256() {
    local dir="$1"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo ""
        return 0
    fi

    if ! command -v tar >/dev/null 2>&1; then
        echo ""
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        (
            cd "$dir" || exit 1
            tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
                --exclude='./.git' \
                --exclude='./.env' \
                --exclude='./.env.*' \
                --exclude='./node_modules' \
                --exclude='./dist' \
                --exclude='./.ethora_deploy' \
                --exclude='./.next' \
                --exclude='./coverage' \
                --exclude='./tmp' \
                --exclude='./.turbo' \
                -cf - .
        ) | sha256sum | awk '{print $1}'
        return 0
    fi

    if command -v shasum >/dev/null 2>&1; then
        (
            cd "$dir" || exit 1
            tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
                --exclude='./.git' \
                --exclude='./.env' \
                --exclude='./.env.*' \
                --exclude='./node_modules' \
                --exclude='./dist' \
                --exclude='./.ethora_deploy' \
                --exclude='./.next' \
                --exclude='./coverage' \
                --exclude='./tmp' \
                --exclude='./.turbo' \
                -cf - .
        ) | shasum -a 256 | awk '{print $1}'
        return 0
    fi

    echo ""
}

filtered_env_sha256() {
    local file="$1"
    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo ""
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        awk '!/^(ETHORA_BUILD_TIME|ETHORA_BUILD_VERSION|ETHORA_BUILD_COMMIT)=/' "$file" | sha256sum | awk '{print $1}'
        return 0
    fi

    if command -v shasum >/dev/null 2>&1; then
        awk '!/^(ETHORA_BUILD_TIME|ETHORA_BUILD_VERSION|ETHORA_BUILD_COMMIT)=/' "$file" | shasum -a 256 | awk '{print $1}'
        return 0
    fi

    echo ""
}

BUILD_HASH_RESULT=""
BUILD_REASON_RESULT=""

needs_project_build() {
    local name="$1"
    local dir="$2"
    local output_path="$3"
    local env_file="${4:-}"
    local stamp_file="$dir/.ethora_deploy/build.${name}.sha256"
    local tree_hash=""
    local env_hash=""
    local extra_hashes=""

    tree_hash="$(project_tree_sha256 "$dir")"
    BUILD_HASH_RESULT="$tree_hash"
    BUILD_REASON_RESULT=""

    if [ "$dir" = "${ROOT_DIR:-}/ethora-app-reactjs" ]; then
        if [ -d "${ROOT_DIR:-}/ethora-chat-component" ]; then
            extra_hashes="${extra_hashes} $(project_tree_sha256 "${ROOT_DIR:-}/ethora-chat-component")"
        fi
        # Only mix the widget tree hash into the frontend build hash when AI
        # is enabled. With AI off, the widget is not a frontend dep and its
        # source changes shouldn't trigger a frontend rebuild.
        if [ "${AI_SERVICE_ENABLED:-false}" == "true" ] && [ -d "${ROOT_DIR:-}/ethora-ai-chat-widget" ]; then
            extra_hashes="${extra_hashes} $(project_tree_sha256 "${ROOT_DIR:-}/ethora-ai-chat-widget")"
        fi
        # Mix the AI flag itself into the frontend build hash so toggling
        # services.ai_service.enabled in deploy.yml triggers a rebuild (the
        # frontend may render different UI/imports based on this flag, and we
        # also want to ensure the cache invalidates symmetrically with
        # ensure_node_deps's hash that already includes this token).
        extra_hashes="${extra_hashes} ai:${AI_SERVICE_ENABLED:-false}"
        if [ -n "$extra_hashes" ]; then
            if command -v sha256sum >/dev/null 2>&1; then
                BUILD_HASH_RESULT="$(printf '%s %s\n' "$BUILD_HASH_RESULT" "$extra_hashes" | sha256sum | awk '{print $1}')"
            elif command -v shasum >/dev/null 2>&1; then
                BUILD_HASH_RESULT="$(printf '%s %s\n' "$BUILD_HASH_RESULT" "$extra_hashes" | shasum -a 256 | awk '{print $1}')"
            fi
        fi
    fi

    if [ -n "$env_file" ] && [ -f "$env_file" ]; then
        env_hash="$(filtered_env_sha256 "$env_file")"
        if [ -z "$BUILD_HASH_RESULT" ] || [ -z "$env_hash" ]; then
            BUILD_HASH_RESULT=""
        else
            BUILD_HASH_RESULT="${BUILD_HASH_RESULT}|env:${env_hash}"
        fi
    fi

    if [ ! -e "$output_path" ]; then
        BUILD_REASON_RESULT="missing build output"
        return 0
    fi

    if [ -z "$BUILD_HASH_RESULT" ]; then
        BUILD_REASON_RESULT="source hash unavailable"
        return 0
    fi

    if [ ! -f "$stamp_file" ]; then
        BUILD_REASON_RESULT="missing build stamp"
        return 0
    fi

    if [ "$(cat "$stamp_file" 2>/dev/null || echo '')" != "$BUILD_HASH_RESULT" ]; then
        BUILD_REASON_RESULT="source tree changed"
        return 0
    fi

    return 1
}

record_project_build_hash() {
    local name="$1"
    local dir="$2"
    local build_hash="$3"
    local stamp_dir="$dir/.ethora_deploy"
    local stamp_file="$stamp_dir/build.${name}.sha256"

    if [ -z "$build_hash" ]; then
        return 0
    fi

    mkdir -p "$stamp_dir" >/dev/null 2>&1 || true
    echo "$build_hash" >"$stamp_file" 2>/dev/null || true
}

ensure_global_npm_version

# Check if PM2 is installed, install if not
if ! command -v pm2 &> /dev/null; then
    warn "PM2 is not installed. Installing PM2..."
    # Sometimes npm leaves a half-installed global pm2 directory behind which breaks future installs:
    #   ENOTEMPTY: directory not empty, rename '/usr/lib/node_modules/pm2' -> '/usr/lib/node_modules/.pm2-XXXX'
    # Try a normal install first, then clean up and retry with --force.
    if ! npm install -g pm2; then
        warn "PM2 install failed. Attempting cleanup of global pm2 directory and retry..."
        rm -rf /usr/lib/node_modules/pm2 /usr/local/lib/node_modules/pm2 /usr/lib/node_modules/.pm2-* /usr/local/lib/node_modules/.pm2-* 2>/dev/null || true
        npm cache clean --force >/dev/null 2>&1 || true
        npm install -g pm2 --force || error "Failed to install PM2. Please install it manually: npm install -g pm2 --force"
    fi
    log "PM2 installed successfully"
fi

# Source environment variables
# Refresh domain/base app values in .deploy.env if deploy.yml changed.
REFRESH_SCRIPT="$DEPLOY_DIR/scripts/refresh-deploy-env.sh"
if [ -f "$REFRESH_SCRIPT" ]; then
    bash "$REFRESH_SCRIPT" || true
fi

ENV_FILE="$DEPLOY_DIR/.deploy.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# Optional: refresh playground settings from deploy.yml (useful for upgrades)
CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"
PLAYGROUND_CREDENTIALS_EXPLICIT="false"
if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    if [ -z "${PLAYGROUND_ENABLED:-}" ] || [ "${PLAYGROUND_ENABLED:-}" == "null" ]; then
        PLAYGROUND_ENABLED="$(yq eval '.services.playground.enabled | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; PLAYGROUND_ENABLED="${PLAYGROUND_ENABLED:-true}"
    fi
    if [ -z "${PLAYGROUND_PORT:-}" ] || [ "${PLAYGROUND_PORT:-}" == "null" ]; then
        PLAYGROUND_PORT="$(yq eval '.services.playground.port // 3020' "$CONFIG_FILE" 2>/dev/null || echo "3020")"
    fi
    if [ -z "${PLAYGROUND_DOMAIN:-}" ] || [ "${PLAYGROUND_DOMAIN:-}" == "null" ]; then
        PLAYGROUND_DOMAIN="$(yq eval '.domains.playground // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    # Hosted MCP server: always re-read the toggle so flipping it in deploy.yml
    # takes effect on update. Read raw (yq `//` falls through on explicit false).
    mcp_enabled_raw="$(yq eval '.services.mcp.enabled' "$CONFIG_FILE" 2>/dev/null)"
    if [ "$mcp_enabled_raw" = "true" ] || [ "$mcp_enabled_raw" = "false" ]; then
        MCP_ENABLED="$mcp_enabled_raw"
    else
        MCP_ENABLED="${MCP_ENABLED:-false}"
    fi
    if [ -z "${MCP_PORT:-}" ] || [ "${MCP_PORT:-}" == "null" ]; then
        MCP_PORT="$(yq eval '.services.mcp.port // 3030' "$CONFIG_FILE" 2>/dev/null || echo "3030")"
    fi
    if [ -z "${WIDGET_ENABLED:-}" ] || [ "${WIDGET_ENABLED:-}" == "null" ]; then
        WIDGET_ENABLED="$(yq eval '.services.widget.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    fi
    if [ -z "${WIDGET_DOMAIN:-}" ] || [ "${WIDGET_DOMAIN:-}" == "null" ]; then
        WIDGET_DOMAIN="$(yq eval '.domains.widget // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${WIDGET_SCRIPT_VERSION:-}" ] || [ "${WIDGET_SCRIPT_VERSION:-}" == "null" ]; then
        WIDGET_SCRIPT_VERSION="$(yq eval '.services.widget.script_version // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    config_playground_app_id="$(yq eval '.playground.app_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    config_playground_app_secret="$(yq eval '.playground.app_secret // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    [ "$config_playground_app_id" = "null" ] && config_playground_app_id=""
    [ "$config_playground_app_secret" = "null" ] && config_playground_app_secret=""
    if [ -n "$config_playground_app_id" ] && [ -n "$config_playground_app_secret" ]; then
        PLAYGROUND_APP_ID="$config_playground_app_id"
        PLAYGROUND_APP_SECRET="$config_playground_app_secret"
        PLAYGROUND_CREDENTIALS_EXPLICIT="true"
    fi
fi

# Get ROOT_DIR from environment or calculate
if [ -z "$ROOT_DIR" ]; then
    ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
fi

log "Setting up Node.js services..."

# Many installs run on small VMs. TypeScript builds can look "stuck" when the machine is memory-starved
# (GC thrash / swapping). Allow a configurable Node heap for build steps (used by tsc/vite/etc).
NODE_BUILD_MAX_OLD_SPACE_MB="${NODE_BUILD_MAX_OLD_SPACE_MB:-2048}"

# Get paths from environment or use defaults
BACKEND_DIR="${BACKEND_DIR:-$ROOT_DIR/ethora-backend}"
FRONTEND_DIR="${FRONTEND_DIR:-$ROOT_DIR/ethora-app-reactjs}"
PLAYGROUND_DIR="${PLAYGROUND_DIR:-$ROOT_DIR/ethora-sdk-playground}"
MCP_DIR="${MCP_DIR:-$ROOT_DIR/ethora-mcp-server}"
LEGACY_WIDGET_DIR="$ROOT_DIR/ethora-sdk-widget"
CANONICAL_WIDGET_DIR="$ROOT_DIR/ethora-ai-chat-widget"
if [ -n "${WIDGET_DIR:-}" ] && [ "${WIDGET_DIR:-}" != "$CANONICAL_WIDGET_DIR" ]; then
    if [ "${WIDGET_DIR:-}" = "$LEGACY_WIDGET_DIR" ]; then
        log "Migrating legacy widget path from $LEGACY_WIDGET_DIR to $CANONICAL_WIDGET_DIR"
    else
        warn "Overriding custom WIDGET_DIR (${WIDGET_DIR:-}) with canonical path $CANONICAL_WIDGET_DIR"
    fi
fi
WIDGET_DIR="$CANONICAL_WIDGET_DIR"

# Backend repo layout support:
# - legacy layout:   $BACKEND_DIR/backend, $BACKEND_DIR/ai_service, $BACKEND_DIR/docs_parse_service
# - new layout:      $BACKEND_DIR/services/api, $BACKEND_DIR/services/ai/ai-service, $BACKEND_DIR/services/ai/docs-parse
if [ -d "$BACKEND_DIR/services/api" ]; then
    BACKEND_API_DIR="$BACKEND_DIR/services/api"
    AI_SERVICE_DIR="$BACKEND_DIR/services/ai/ai-service"
    DOCS_PARSE_DIR="$BACKEND_DIR/services/ai/docs-parse"
    PUSH_DIR="$BACKEND_DIR/services/push"
else
    BACKEND_API_DIR="$BACKEND_DIR/backend"
    AI_SERVICE_DIR="$BACKEND_DIR/ai_service"
    DOCS_PARSE_DIR="$BACKEND_DIR/docs_parse_service"
    PUSH_DIR=""
fi

# Run modes (deploy.yml services.backend.mode / services.frontend.mode).
# deploy.yml is the source of truth; the values setup-env.sh persisted into
# .deploy.env are only a fallback for when the config is not readable here.
# (A stale persisted value must never override an edited deploy.yml.)
cfg_mode() { # cfg_mode <yq path> <fallback env value> <default>
    local v=""
    if [ -f "$CONFIG_FILE" ]; then v="$(yq eval "$1 // \"\"" "$CONFIG_FILE" 2>/dev/null || true)"; fi
    [ "$v" = "null" ] && v=""
    [ -z "$v" ] && v="$2"
    [ -z "$v" ] || [ "$v" = "null" ] && v="$3"
    printf '%s' "$v"
}
BACKEND_MODE="$(cfg_mode '.services.backend.mode' "${BACKEND_MODE:-}" source)"
ETHORA_API_IMAGE="$(cfg_mode '.services.backend.image' "${ETHORA_API_IMAGE:-}" "")"
FRONTEND_MODE="$(cfg_mode '.services.frontend.mode' "${FRONTEND_MODE:-}" source)"
ETHORA_FRONTEND_IMAGE="$(cfg_mode '.services.frontend.image' "${ETHORA_FRONTEND_IMAGE:-}" "")"
AI_MODE="$(cfg_mode '.services.ai_service.mode' "${AI_MODE:-}" source)"
ETHORA_AI_IMAGE="$(cfg_mode '.services.ai_service.image' "${ETHORA_AI_IMAGE:-}" "")"
PUSH_MODE="$(cfg_mode '.services.push.mode' "${PUSH_MODE:-}" source)"
ETHORA_PUSH_IMAGE="$(cfg_mode '.services.push.image' "${ETHORA_PUSH_IMAGE:-}" "")"
PLAYGROUND_MODE="$(cfg_mode '.services.playground.mode' "${PLAYGROUND_MODE:-}" source)"
ETHORA_PLAYGROUND_IMAGE="$(cfg_mode '.services.playground.image' "${ETHORA_PLAYGROUND_IMAGE:-}" "")"
MCP_MODE="$(cfg_mode '.services.mcp.mode' "${MCP_MODE:-}" source)"
ETHORA_MCP_IMAGE="$(cfg_mode '.services.mcp.image' "${ETHORA_MCP_IMAGE:-}" "")"
log "Run modes: backend=$BACKEND_MODE${ETHORA_API_IMAGE:+ ($ETHORA_API_IMAGE)} frontend=$FRONTEND_MODE${ETHORA_FRONTEND_IMAGE:+ ($ETHORA_FRONTEND_IMAGE)} ai=$AI_MODE push=$PUSH_MODE playground=$PLAYGROUND_MODE mcp=$MCP_MODE"
API_COMPOSE_FILE="$DEPLOY_DIR/docker-compose.api.yml"

# Compose wrapper for the API image stack. Host networking, the rendered
# backend .env, uploads under DATA_DIR. Blockchain worker only when enabled.
# The compose file declares its own project name (ethora-api) so it can never
# see the enterprise stack's containers as orphans. Do NOT add
# --remove-orphans here: with a shared project it removed Mongo/XMPP/MySQL/
# Redis/MinIO on a QA host.
api_compose() {
    local uploads_dir="${DATA_DIR:-$HOME/ethora-data}/api-uploads"
    mkdir -p "$uploads_dir" 2>/dev/null || true
    # Push keeps its uploads at the host path its .env names; mount it 1:1.
    local push_uploads="${PUSH_UPLOADS_DIR:-}"
    [ -z "$push_uploads" ] && [ -f "${PUSH_DIR:-/nonexistent}/.env" ] && push_uploads="$(awk -F= '/^PUSH_UPLOADS_DIR=/{sub(/^PUSH_UPLOADS_DIR=/,""); print; exit}' "$PUSH_DIR/.env")"
    [ -z "$push_uploads" ] && push_uploads="${DATA_DIR:-$HOME/ethora-data}/push-uploads"
    mkdir -p "$push_uploads" 2>/dev/null || true
    local profile=()
    [ "${BLOCKCHAIN_ENABLED:-false}" = "true" ] && profile=(--profile blockchain)
    ETHORA_API_IMAGE="$ETHORA_API_IMAGE" \
    ETHORA_BACKEND_ENV_FILE="$BACKEND_API_DIR/.env" \
    ETHORA_API_UPLOADS_DIR="$uploads_dir" \
    ETHORA_AI_IMAGE="${ETHORA_AI_IMAGE:-}" \
    ETHORA_AI_ENV_FILE="${AI_SERVICE_DIR:-}/.env" \
    ETHORA_DOCS_PARSE_ENV_FILE="${DOCS_PARSE_DIR:-}/.env" \
    ETHORA_PUSH_IMAGE="${ETHORA_PUSH_IMAGE:-}" \
    ETHORA_PUSH_ENV_FILE="${PUSH_DIR:-}/.env" \
    ETHORA_PUSH_UPLOADS_DIR="$push_uploads" \
    ETHORA_PLAYGROUND_IMAGE="${ETHORA_PLAYGROUND_IMAGE:-}" \
    ETHORA_PLAYGROUND_ENV_FILE="${PLAYGROUND_DIR:-}/.env.local" \
    PLAYGROUND_PORT="${PLAYGROUND_PORT:-3020}" \
    ETHORA_MCP_IMAGE="${ETHORA_MCP_IMAGE:-}" \
    ETHORA_MCP_ENV_FILE="${MCP_DIR:-}/.env" \
    docker compose -f "$API_COMPOSE_FILE" "${profile[@]}" "$@"
}

# image_up <profile> <image-var-name> <service...>: pull if absent, remove
# same-named containers from another compose project, bring the services up.
image_up() {
    local profile="$1" image_var="$2"; shift 2
    local image="${!image_var}"
    [ -n "$image" ] || error "$image_var is empty in deploy.yml (services.*.image) but the service mode is image"
    command -v docker >/dev/null 2>&1 || error "docker is required for image mode"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        log "Pulling $image..."
        docker pull --quiet "$image" >/dev/null || error "could not pull $image (private images need: docker login ghcr.io)"
    fi
    for svc in "$@"; do
        local c="ethora-$svc"
        if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
            local proj; proj="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$c" 2>/dev/null || true)"
            [ "$proj" = "ethora-api" ] || docker rm -f "$c" >/dev/null 2>&1 || true
        fi
    done
    api_compose --profile "$profile" up -d "$@" || error "docker compose up failed for: $*"
}

# image_down <profile> <service...>: stop + remove those containers (source mode).
image_down() {
    local profile="$1"; shift
    [ -f "$API_COMPOSE_FILE" ] || return 0
    api_compose --profile "$profile" rm -sf "$@" >/dev/null 2>&1 || true
    for svc in "$@"; do docker rm -f "ethora-$svc" >/dev/null 2>&1 || true; done
}

wait_for_port() { # name host port tries delay
    local name="$1" host="$2" port="$3" tries="${4:-30}" delay="${5:-2}" i
    for i in $(seq 1 "$tries"); do
        (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null && { log "$name is listening on $host:$port"; return 0; }
        sleep "$delay"
    done
    warn "$name did not open $host:$port within timeout"; return 1
}

if [ "$BACKEND_MODE" = "image" ]; then
    # ------------------------------------------------------------ image mode
    [ -n "$ETHORA_API_IMAGE" ] || error "services.backend.mode is image but services.backend.image is empty in deploy.yml"
    [ -f "$API_COMPOSE_FILE" ] || error "missing $API_COMPOSE_FILE"
    command -v docker >/dev/null 2>&1 || error "docker is required for services.backend.mode: image"
    log "Backend runs from image $ETHORA_API_IMAGE (no host build)"
    # PM2 must not hold port 8080 or restart a stale source build.
    run_as_deploy_user "pm2 delete backend backend-jobs backend-bc-worker 2>/dev/null || true"
    if ! docker image inspect "$ETHORA_API_IMAGE" >/dev/null 2>&1; then
        log "Pulling $ETHORA_API_IMAGE..."
        docker pull --quiet "$ETHORA_API_IMAGE" >/dev/null || error "could not pull $ETHORA_API_IMAGE (private images need: docker login ghcr.io)"
    fi
    # Containers with these fixed names from an older project (or a hand run)
    # would block `up` with a name conflict; they are stateless, so drop them.
    for c in ethora-backend ethora-backend-jobs ethora-backend-bc-worker; do
        if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
            proj="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$c" 2>/dev/null || true)"
            if [ "$proj" != "ethora-api" ]; then
                log "Removing stale container $c (compose project '${proj:-none}')"
                docker rm -f "$c" >/dev/null 2>&1 || true
            fi
        fi
    done
    api_compose up -d || error "docker compose up failed for the API image stack"
    if ! wait_for_http "Backend (image)" "http://127.0.0.1:${BACKEND_PORT:-8080}/v1/ping" 90 2; then
        docker logs --tail 40 ethora-backend 2>&1 | sed 's/^/    /' >&2 || true
        error "Backend container did not answer /v1/ping"
    fi
    log "Backend image stack is up: $(docker ps --format '{{.Names}}' | grep -E '^ethora-backend' | tr '\n' ' ')"
else
    # ----------------------------------------------------------- source mode
    # Coming back from image mode: the containers would hold port 8080.
    if [ -f "$API_COMPOSE_FILE" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^ethora-backend'; then
        log "Stopping the API image stack (services.backend.mode is source)..."
        api_compose down >/dev/null 2>&1 || warn "could not stop the API image stack; port 8080 may be busy"
        # Belt and braces for containers created under an older project name.
        docker rm -f ethora-backend ethora-backend-jobs ethora-backend-bc-worker >/dev/null 2>&1 || true
    fi

# Build and start Backend
log "Building backend..."
cd "$BACKEND_API_DIR"

# Install dependencies if needed (or if lockfile changed)
ensure_node_deps "$BACKEND_API_DIR"

# Build backend only when inputs changed (or output is missing).
if needs_project_build "backend" "$BACKEND_API_DIR" "$BACKEND_API_DIR/dist" "$BACKEND_API_DIR/.env"; then
    log "Building backend TypeScript (${BUILD_REASON_RESULT}; this may take a few minutes)..."
    set +e
    run_as_deploy_user "cd \"$BACKEND_API_DIR\" && NODE_OPTIONS=\"--max-old-space-size=${NODE_BUILD_MAX_OLD_SPACE_MB}\" npm run build"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 130 ]; then
            error "Backend build was interrupted (Ctrl+C). Re-run install and let the build complete."
        fi
        error "Backend build failed (exit code: $rc)"
    fi
    record_project_build_hash "backend" "$BACKEND_API_DIR" "$BUILD_HASH_RESULT"
else
    log "Backend source unchanged; skipping build"
fi

# Start backend with PM2
log "Starting backend with PM2..."
run_as_deploy_user "pm2 delete backend 2>/dev/null || true"
# Backend entrypoint differs between legacy and new layouts:
# - legacy backend layout typically builds `dist/app.js`
# - services/api layout builds `dist/src/app.js` (tsconfig outDir keeps src/ prefix)
#
# We intentionally start PM2 with cwd=dist so:
# - PM2 shows dist/package.json version (stamped to ETHORA_BUILD_VERSION) in `pm2 list`
# - /ping can read ../../../package.json from dist/src/routes/* reliably
PM2_BACKEND_CWD="$BACKEND_API_DIR/dist"
BACKEND_ENTRY="./app.js"
if [ ! -f "$BACKEND_API_DIR/dist/app.js" ] && [ -f "$BACKEND_API_DIR/dist/src/app.js" ]; then
    BACKEND_ENTRY="./src/app.js"
fi

# Optional: start a dedicated jobs runner if present (prevents cron from being tied to API uptime).
# Major-version behavior: cron does NOT run inside the API process; it only runs in backend-jobs.
JOBS_ENTRY=""
if [ -f "$BACKEND_API_DIR/dist/src/jobs.js" ]; then
    JOBS_ENTRY="./src/jobs.js"
elif [ -f "$BACKEND_API_DIR/dist/jobs.js" ]; then
    JOBS_ENTRY="./jobs.js"
fi

if [ -n "$JOBS_ENTRY" ]; then
    log "Starting backend jobs with PM2..."
    run_as_deploy_user "pm2 delete backend-jobs 2>/dev/null || true"
    run_as_deploy_user "cd \"$PM2_BACKEND_CWD\" && pm2 start $JOBS_ENTRY --name backend-jobs --time --update-env" || warn "Failed to start backend-jobs (cron will not run)"
fi

# Bull queue worker (add-app-chat, walletPreCreating, web3request). Without this
# process, jobs enqueued by the API sit in Redis forever — e.g. admin-created
# pinned chats fail to propagate to existing users.
BC_WORKER_ENTRY=""
if [ -f "$BACKEND_API_DIR/dist/src/worker/bc.worker.js" ]; then
    BC_WORKER_ENTRY="./src/worker/bc.worker.js"
elif [ -f "$BACKEND_API_DIR/dist/worker/bc.worker.js" ]; then
    BC_WORKER_ENTRY="./worker/bc.worker.js"
fi

if [ -n "$BC_WORKER_ENTRY" ]; then
    log "Starting backend bc.worker (Bull queue consumer) with PM2..."
    run_as_deploy_user "pm2 delete backend-bc-worker 2>/dev/null || true"
    run_as_deploy_user "cd \"$PM2_BACKEND_CWD\" && pm2 start $BC_WORKER_ENTRY --name backend-bc-worker --time --update-env" || warn "Failed to start backend-bc-worker (queue jobs will not be processed)"
fi

run_as_deploy_user "cd \"$PM2_BACKEND_CWD\" && pm2 start $BACKEND_ENTRY --name backend --time --update-env" || error "Failed to start backend"

# Wait for backend to actually start listening. Avoids transient 502s right after PM2 restart.
if ! wait_for_http "Backend" "http://127.0.0.1:${BACKEND_PORT:-8080}/ping" 60 2; then
    warn "Backend did not respond to /ping within timeout. Showing last 80 lines of PM2 backend logs for diagnostics..."
    run_as_deploy_user "pm2 logs backend --lines 80 --nostream" || true
fi
fi  # BACKEND_MODE source

# Start push notifications service (optional; enabled by default when present).
if [ -n "${PUSH_DIR:-}" ] && [ -d "$PUSH_DIR" ] && [ "${PUSH_ENABLED:-true}" == "true" ] && [ "$PUSH_MODE" = "image" ]; then
    log "Push service runs from image $ETHORA_PUSH_IMAGE (no host build)"
    run_as_deploy_user "pm2 delete push push-worker 2>/dev/null || true"
    image_up push ETHORA_PUSH_IMAGE push push-worker
    wait_for_http "Push service (image)" "http://127.0.0.1:${PUSH_PORT:-8098}/health" 30 2 || warn "Push service did not respond to /health within timeout."
elif [ -n "${PUSH_DIR:-}" ] && [ -d "$PUSH_DIR" ] && [ "${PUSH_ENABLED:-true}" == "true" ]; then
    log "Setting up push service..."
    image_down push push push-worker
    ensure_node_deps "$PUSH_DIR"

    log "Starting push service with PM2..."
    run_as_deploy_user "pm2 delete push 2>/dev/null || true"
    run_as_deploy_user "pm2 delete push-worker 2>/dev/null || true"

    # Start server + worker; use PUSH_PORT from env (setup-env.sh persists it into .deploy.env).
    run_as_deploy_user "cd \"$PUSH_DIR\" && PUSH_PORT=${PUSH_PORT:-8098} pm2 start ./server.js --name push --time --update-env" || warn "Failed to start push service"
    run_as_deploy_user "cd \"$PUSH_DIR\" && pm2 start ./worker.js --name push-worker --time --update-env" || warn "Failed to start push worker"

    if ! wait_for_http "Push service" "http://127.0.0.1:${PUSH_PORT:-8098}/health" 30 2; then
        warn "Push service did not respond to /health within timeout."
    fi
fi

# Build and start AI Service (if enabled)
if [ "${AI_SERVICE_ENABLED}" == "true" ] && [ "$AI_MODE" = "image" ]; then
    log "AI service runs from image $ETHORA_AI_IMAGE (no host build)"
    run_as_deploy_user "pm2 delete ai-service 2>/dev/null || true"
    [ -n "$ETHORA_AI_IMAGE" ] || error "services.ai_service.image is empty but services.ai_service.mode is image"
    docker image inspect "$ETHORA_AI_IMAGE" >/dev/null 2>&1 || docker pull --quiet "$ETHORA_AI_IMAGE" >/dev/null || error "could not pull $ETHORA_AI_IMAGE"
    ensure_ai_postgres_schema "$AI_SERVICE_DIR"
    image_up ai ETHORA_AI_IMAGE ai-service
    wait_for_port "AI service (image)" 127.0.0.1 "${AI_SERVICE_PORT:-8013}" 45 2 || true
elif [ "${AI_SERVICE_ENABLED}" == "true" ]; then
    log "Building AI service..."
    cd "$AI_SERVICE_DIR"
    image_down ai ai-service

    ensure_node_deps "$AI_SERVICE_DIR"
    ensure_ai_postgres_schema "$AI_SERVICE_DIR"

    if needs_project_build "ai-service" "$AI_SERVICE_DIR" "$AI_SERVICE_DIR/dist/server.js"; then
        log "Building AI service (${BUILD_REASON_RESULT})..."
        if run_as_deploy_user "cd \"$AI_SERVICE_DIR\" && npm run build"; then
            record_project_build_hash "ai-service" "$AI_SERVICE_DIR" "$BUILD_HASH_RESULT"
        else
            warn "AI service build failed"
        fi
    else
        log "AI service source unchanged; skipping build"
    fi
    
    log "Starting AI service with PM2..."
    run_as_deploy_user "pm2 delete ai-service 2>/dev/null || true"
    run_as_deploy_user "cd \"$AI_SERVICE_DIR\" && pm2 start ./dist/server.js --name ai-service --time --update-env" || warn "Failed to start AI service"
fi

# Build and start Docs Parse Service (if enabled)
if [ "${DOCS_PARSE_ENABLED}" == "true" ] && [ "$AI_MODE" = "image" ]; then
    log "Docs parse service runs from image $ETHORA_AI_IMAGE (no host build)"
    run_as_deploy_user "pm2 delete docs-parse 2>/dev/null || true"
    image_up ai ETHORA_AI_IMAGE docs-parse
    wait_for_http "Docs parse (image)" "http://127.0.0.1:${DOCS_PARSE_PORT:-8201}/health" 30 2 || warn "Docs parse did not respond to /health within timeout."
elif [ "${DOCS_PARSE_ENABLED}" == "true" ]; then
    log "Building docs parse service..."
    cd "$DOCS_PARSE_DIR"
    image_down ai docs-parse

    ensure_node_deps "$DOCS_PARSE_DIR"
    
    log "Starting docs parse service with PM2..."
    run_as_deploy_user "pm2 delete docs-parse 2>/dev/null || true"
    if [ -f "ecosystem.config.js" ]; then
        run_as_deploy_user "cd \"$DOCS_PARSE_DIR\" && pm2 start ecosystem.config.js --only docs-parse --time --update-env" || warn "Failed to start docs parse service"
    else
        run_as_deploy_user "cd \"$DOCS_PARSE_DIR\" && pm2 start index.js --name docs-parse --time --update-env" || warn "Failed to start docs parse service"
    fi
fi

# Setup Frontend
log "Setting up frontend..."
cd "$FRONTEND_DIR"

# Frontend image mode needs nothing built on the host: no npm install, no
# local chat-component / widget builds. Localhost mode still runs the Vite
# dev server from source, so it keeps the dependency steps.
if [ "$FRONTEND_MODE" = "image" ] && [ "${API_DOMAIN}" != "localhost" ]; then
    log "Frontend runs from image $ETHORA_FRONTEND_IMAGE; skipping host dependency install and local package builds"
else
# Frontend build uses TypeScript (`tsc -b`), which is typically a devDependency.
# Some environments set NPM_CONFIG_PRODUCTION=true globally, which would omit devDependencies
# and cause `tsc: not found` during `npm run build`.
ensure_node_deps "$FRONTEND_DIR" "typescript"

# Safety net: after ensure_node_deps (which may have been cached), verify that
# local frontend packages (@ethora/ai-chat-widget, @ethora/chat-component) are
# fully resolvable. If not, build them from source, patch package.json to use
# file: overrides, and reinstall so `tsc -b` can find them.
#
# This catches:
# - ensure_node_deps cache hit that skipped the widget/component build
# - git submodule update resetting package.json to the GitHub URL
# - widget/component dist cleaned while node_modules symlink became stale
ensure_local_frontend_deps_built() {
    local widget_dir="${ROOT_DIR:-}/ethora-ai-chat-widget"
    local chat_dir="${ROOT_DIR:-}/ethora-chat-component"
    local needs_reinstall=false
    # When AI is disabled, treat the widget folder as if it weren't present:
    # don't build it and don't expect the frontend's node_modules to contain
    # its types. The frontend never imports it; ensure_node_deps will have
    # already stripped the dep from package.json before installing.
    local widget_active="false"
    if [ "${AI_SERVICE_ENABLED:-false}" == "true" ] && [ -f "$widget_dir/package.json" ]; then
        widget_active="true"
    fi

    # Step 1: build local packages if their dist is missing
    if [ "$widget_active" = "true" ] && [ ! -d "$widget_dir/dist" ]; then
        warn "Local @ethora/ai-chat-widget dist missing; building..."
        ensure_node_deps "$widget_dir" "typescript"
        run_as_deploy_user "cd \"$widget_dir\" && npm run build:lib" || warn "Failed to build @ethora/ai-chat-widget"
    fi
    if [ -f "$chat_dir/package.json" ] && [ ! -d "$chat_dir/dist" ]; then
        warn "Local @ethora/chat-component dist missing; building..."
        ensure_node_deps "$chat_dir" "typescript"
        run_as_deploy_user "cd \"$chat_dir\" && npm run build:lib" || warn "Failed to build @ethora/chat-component"
    fi

    # Step 2: check if the frontend can actually resolve the types
    if [ "$widget_active" = "true" ] && [ ! -f "$FRONTEND_DIR/node_modules/@ethora/ai-chat-widget/dist/main.d.ts" ]; then
        warn "Frontend cannot resolve @ethora/ai-chat-widget types"
        needs_reinstall=true
    fi
    if [ -f "$chat_dir/package.json" ] && [ ! -f "$FRONTEND_DIR/node_modules/@ethora/chat-component/dist/main.d.ts" ]; then
        warn "Frontend cannot resolve @ethora/chat-component types"
        needs_reinstall=true
    fi

    # Step 3: if types aren't resolvable, patch package.json + lockfile and reinstall
    if [ "$needs_reinstall" = "true" ]; then
        log "Re-linking local frontend dependencies..."
        # Pass an empty WIDGET_PKG when AI is disabled so the python block
        # below does not re-add @ethora/ai-chat-widget as a file: override.
        local widget_pkg_arg=""
        if [ "$widget_active" = "true" ]; then
            widget_pkg_arg="${widget_dir}/package.json"
        fi
        run_as_deploy_user "FRONTEND_DIR=\"$FRONTEND_DIR\" WIDGET_PKG=\"${widget_pkg_arg}\" CHAT_PKG=\"${chat_dir}/package.json\" python3 - <<'PYLINK'
import json, os
from pathlib import Path

frontend = Path(os.environ['FRONTEND_DIR'])
pkg_path = frontend / 'package.json'
lock_path = frontend / 'package-lock.json'
pkg = json.loads(pkg_path.read_text())
deps = pkg.setdefault('dependencies', {})

overrides = {}
if Path(os.environ.get('WIDGET_PKG', '')).is_file():
    overrides['@ethora/ai-chat-widget'] = 'file:../ethora-ai-chat-widget'
if Path(os.environ.get('CHAT_PKG', '')).is_file():
    overrides['@ethora/chat-component'] = 'file:../ethora-chat-component'

for name, value in overrides.items():
    deps[name] = value
pkg_path.write_text(json.dumps(pkg, indent=2) + '\n')

if lock_path.exists():
    lock = json.loads(lock_path.read_text())
    root_deps = lock.setdefault('packages', {}).setdefault('', {}).setdefault('dependencies', {})
    nm_entries = lock.setdefault('packages', {})
    nm_paths = {
        '@ethora/chat-component': 'node_modules/@ethora/chat-component',
        '@ethora/ai-chat-widget': 'node_modules/@ethora/ai-chat-widget',
    }
    for name, value in overrides.items():
        root_deps[name] = value
        # See the matching note in prepare_local_frontend_dependency_overrides:
        # remove the entries instead of patching resolved so npm 11+ does not
        # bail with EMISSINGTARGET (file:../dep referenced but does not exist).
        # npm install regenerates them in its own canonical shape.
        nm_path = nm_paths.get(name)
        if nm_path and nm_path in nm_entries:
            del nm_entries[nm_path]
        if isinstance(value, str) and value.startswith('file:'):
            rel_path = value[len('file:'):]
            if rel_path in nm_entries:
                del nm_entries[rel_path]
    lock_path.write_text(json.dumps(lock, indent=2) + '\n')
PYLINK" || warn "Failed to patch frontend package.json for local deps"

        # The re-link install MUST keep devDependencies. On QA/prod boxes where
        # NODE_ENV=production (or `npm config set production true`) is set at
        # the user/system level, a bare `npm install` runs in --omit=dev mode
        # and prunes typescript/vite/eslint along with everything else listed
        # under devDependencies. The next `npm run build` then explodes with
        # `sh: 1: tsc: not found` (since tsc only exists under devDependencies).
        #
        # Mirror what ensure_node_deps does when it needs typescript: prepend
        # NPM_CONFIG_PRODUCTION=false on the call so npm reads it as a
        # per-process override regardless of the inherited environment.
        run_as_deploy_user "cd \"$FRONTEND_DIR\" && NPM_CONFIG_PRODUCTION=false npm install --no-fund --no-audit --loglevel=error" || warn "Failed to re-link frontend deps"
    fi

    # Final safety net: re-install the no-op widget stub if AI is disabled.
    # The reinstall above (or any earlier ensure_node_deps call) may have
    # wiped node_modules/@ethora/ai-chat-widget/. Without this, the next
    # `tsc -b && vite build` fails with TS2307 on AIWidget.tsx's import.
    install_ai_widget_stub_when_disabled "$FRONTEND_DIR"
}
ensure_local_frontend_deps_built

fi  # FRONTEND_MODE source (or localhost)

# Check if we're in localhost mode - run dev server instead of building
if [ "${API_DOMAIN}" == "localhost" ]; then
    # Pick a stable port (prefer 5173; fall back to the next free port).
    is_port_free() {
        local port="$1"
        if command -v ss >/dev/null 2>&1; then
            ! ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port"
            return $?
        fi
        if command -v lsof >/dev/null 2>&1; then
            ! lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
            return $?
        fi
        # Fallback: try connecting; if connect succeeds, port is in use.
        if command -v nc >/dev/null 2>&1; then
            ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1
            return $?
        fi
        return 0
    }

    FRONTEND_PORT="${FRONTEND_PORT:-5173}"
    if ! is_port_free "$FRONTEND_PORT"; then
        for try_port in 5174 5175 5176 5177; do
            if is_port_free "$try_port"; then
                FRONTEND_PORT="$try_port"
                break
            fi
        done
    fi

    # Persist the selected port so installer output and follow-up scripts can report the correct URL.
    # NOTE: Do not delete comments in .deploy.env; only replace/update the FRONTEND_PORT assignment.
    if [ -n "${DEPLOY_DIR:-}" ] && [ -f "$DEPLOY_DIR/.deploy.env" ]; then
        tmp_env="$(mktemp)"
        # Remove existing FRONTEND_PORT line(s) (if any), keep everything else unchanged.
        grep -v '^FRONTEND_PORT=' "$DEPLOY_DIR/.deploy.env" >"$tmp_env" 2>/dev/null || true
        echo "FRONTEND_PORT=$FRONTEND_PORT" >>"$tmp_env"
        mv "$tmp_env" "$DEPLOY_DIR/.deploy.env"
    fi

    log "Localhost mode detected - starting frontend dev server..."
    run_as_deploy_user "pm2 delete frontend 2>/dev/null || true"
    run_as_deploy_user "cd \"$FRONTEND_DIR\" && pm2 start npm --name frontend --time --update-env -- run dev -- --host 0.0.0.0 --port $FRONTEND_PORT" || error "Failed to start frontend dev server"
    log "Frontend dev server started. Access at http://localhost:${FRONTEND_PORT}"
else
    if [ "$FRONTEND_MODE" = "image" ]; then
        # Export the runtime-configured bundle from the prebuilt image into the
        # directory nginx already serves. No npm, no vite on the host.
        [ -n "$ETHORA_FRONTEND_IMAGE" ] || error "services.frontend.mode is image but services.frontend.image is empty in deploy.yml"
        log "Frontend bundle from image $ETHORA_FRONTEND_IMAGE (no host build)"
        ETHORA_FRONTEND_IMAGE="$ETHORA_FRONTEND_IMAGE" \
        FRONTEND_ENV_FILE="$FRONTEND_DIR/.env" \
        FRONTEND_BUILD_DIR="$FRONTEND_DIR/dist" \
        DOCKER_ENV_FILE="$DEPLOY_DIR/generated/frontend.image.env" \
        bash "$SCRIPT_DIR/frontend-from-image.sh" || error "frontend-from-image.sh failed"
    elif needs_project_build "frontend" "$FRONTEND_DIR" "$FRONTEND_DIR/dist" "$FRONTEND_DIR/.env"; then
        log "Building frontend production bundle (${BUILD_REASON_RESULT})..."
        run_as_deploy_user "cd \"$FRONTEND_DIR\" && npm run build" || error "Frontend build failed"
        record_project_build_hash "frontend" "$FRONTEND_DIR" "$BUILD_HASH_RESULT"
        log "Frontend build completed. Static files are in: $FRONTEND_DIR/dist"
    else
        log "Frontend source unchanged; skipping production build"
    fi

    # Ensure nginx can read dist when serving from user-owned paths.
    ensure_nginx_can_read_static_dir "$FRONTEND_DIR/dist" "frontend dist"
    
    # Optionally serve the built frontend with a simple HTTP server
    # This would require nginx or another web server in production
fi

# Setup AI Widget static bundle (optional)
if [ "${WIDGET_ENABLED:-false}" == "true" ]; then
    if [ ! -f "$WIDGET_DIR/package.json" ]; then
        if [ -d "$WIDGET_DIR" ]; then
            error "Widget hosting is enabled, but $WIDGET_DIR has no package.json (submodule not initialized). Initialize it in the source tree with: git submodule update --init ethora-ai-chat-widget"
        fi
        error "Widget hosting is enabled, but widget directory is missing at $WIDGET_DIR"
    else
        log "Setting up widget..."
        cd "$WIDGET_DIR"

        if [ -z "${WIDGET_SCRIPT_VERSION:-}" ] || [ "${WIDGET_SCRIPT_VERSION:-}" == "null" ]; then
            WIDGET_SCRIPT_VERSION="$(date -u +'%y%m')"
        fi

        if [ "$AI_MODE" = "image" ]; then
            log "Widget bundle from image $ETHORA_AI_IMAGE (no host build)"
            ETHORA_AI_IMAGE="$ETHORA_AI_IMAGE" WIDGET_DIR="$WIDGET_DIR" WIDGET_SCRIPT_VERSION="$WIDGET_SCRIPT_VERSION" \
            DOCKER_ENV_FILE="$DEPLOY_DIR/generated/widget.image.env" \
            bash "$SCRIPT_DIR/widget-from-image.sh" || error "widget-from-image.sh failed"
        else
        ensure_node_deps "$WIDGET_DIR" "typescript"

        if needs_project_build "widget" "$WIDGET_DIR" "$WIDGET_DIR/dist/assistant.js" "$WIDGET_DIR/.env.production.local"; then
            log "Building widget production bundle (${BUILD_REASON_RESULT})..."
            run_as_deploy_user "cd \"$WIDGET_DIR\" && npm run build" || error "Widget build failed"
            finalize_widget_assets "$WIDGET_DIR/dist" "$WIDGET_SCRIPT_VERSION"
            record_project_build_hash "widget" "$WIDGET_DIR" "$BUILD_HASH_RESULT"
            log "Widget build completed. Static files are in: $WIDGET_DIR/dist"
        else
            log "Widget source unchanged; skipping production build"
            finalize_widget_assets "$WIDGET_DIR/dist" "$WIDGET_SCRIPT_VERSION"
        fi
        fi  # AI_MODE

        ensure_nginx_can_read_static_dir "$WIDGET_DIR/dist" "widget dist"
    fi
fi

# Setup SDK Playground (optional)
if [ "${PLAYGROUND_ENABLED:-false}" == "true" ]; then
    if [ ! -f "$PLAYGROUND_DIR/package.json" ]; then
        warn "SDK playground sources not found at $PLAYGROUND_DIR (submodule not initialized?)"
    else
        log "Setting up SDK playground..."
        cd "$PLAYGROUND_DIR"

        # Explicit deploy.yml values win. Otherwise, derive the current base-app credentials
        # from Mongo so stale persisted PLAYGROUND_* values do not survive reinstall/update cycles.
        if [ "${PLAYGROUND_CREDENTIALS_EXPLICIT:-false}" != "true" ]; then
            prev_playground_app_id="${PLAYGROUND_APP_ID:-}"
            prev_playground_app_secret="${PLAYGROUND_APP_SECRET:-}"
            PLAYGROUND_APP_ID=""
            PLAYGROUND_APP_SECRET=""

            if command -v node >/dev/null 2>&1 && [ -n "${MONGO_DB:-}" ] && [ -n "${BASE_APP_DOMAIN_NAME:-}" ]; then
                tmp_js="/tmp/ethora-playground-mongo.$$.js"
                cat >"$tmp_js" <<'NODEJS'
const { createRequire } = require('module');
const requireFromCwd = createRequire(process.cwd() + '/');
const mongoose = requireFromCwd('mongoose');
const App = requireFromCwd('./src/models/apps');

const mongoUri = process.argv[2] || '';
const domainName = process.argv[3] || '';

async function main() {
  if (!mongoUri || !domainName) return;
  await mongoose.connect(mongoUri);
  const app = await App.findOne({ domainName }).lean();
  if (!app) return;
  const b64 = v => Buffer.from(String(v || ''), 'utf8').toString('base64');
  const authSecret = app.tenantSecret || app.appSecret || '';
  console.log(`ETHORA_PLAYGROUND_APP_ID_B64=${b64(app._id)}`);
  console.log(`ETHORA_PLAYGROUND_APP_SECRET_B64=${b64(authSecret)}`);
  await mongoose.disconnect();
}
main().catch(() => process.exit(0));
NODEJS
                MONGO_URI="mongodb://localhost:${MONGO_PORT}/${MONGO_DB}?directConnection=true"
                node_out=""
                node_out="$(run_as_deploy_user "cd \"$BACKEND_API_DIR\" && node \"$tmp_js\" \"${MONGO_URI}\" \"${BASE_APP_DOMAIN_NAME}\"" 2>/dev/null || true)"
                rm -f "$tmp_js" 2>/dev/null || true
                if [ -n "$node_out" ]; then
                    id_b64=""
                    secret_b64=""
                    id_b64="$(echo "$node_out" | grep -m1 '^ETHORA_PLAYGROUND_APP_ID_B64=' | sed 's/^[^=]*=//')"
                    secret_b64="$(echo "$node_out" | grep -m1 '^ETHORA_PLAYGROUND_APP_SECRET_B64=' | sed 's/^[^=]*=//')"
                    if [ -n "$id_b64" ] && [ -n "$secret_b64" ] && command -v base64 >/dev/null 2>&1; then
                        PLAYGROUND_APP_ID="$(echo "$id_b64" | base64 -d 2>/dev/null || true)"
                        PLAYGROUND_APP_SECRET="$(echo "$secret_b64" | base64 -d 2>/dev/null || true)"
                    fi
                fi
            fi

            if { [ -z "${PLAYGROUND_APP_ID:-}" ] || [ -z "${PLAYGROUND_APP_SECRET:-}" ]; } && [ -f "$PLAYGROUND_DIR/.env.local" ]; then
                PLAYGROUND_APP_ID="$(grep -m1 '^ETHORA_CHAT_APP_ID=' "$PLAYGROUND_DIR/.env.local" | cut -d= -f2-)"
                PLAYGROUND_APP_SECRET="$(grep -m1 '^ETHORA_CHAT_APP_SECRET=' "$PLAYGROUND_DIR/.env.local" | cut -d= -f2-)"
            fi

            if [ -z "${PLAYGROUND_APP_ID:-}" ] || [ -z "${PLAYGROUND_APP_SECRET:-}" ]; then
                PLAYGROUND_APP_ID="${prev_playground_app_id:-}"
                PLAYGROUND_APP_SECRET="${prev_playground_app_secret:-}"
            fi
        fi

        if [ -n "${PLAYGROUND_APP_ID:-}" ] && [ -n "${PLAYGROUND_APP_SECRET:-}" ]; then
            # Persist to .deploy.env for future runs.
            if [ -n "${DEPLOY_DIR:-}" ] && [ -f "$DEPLOY_DIR/.deploy.env" ]; then
                tmp_env="$(mktemp)"
                grep -v '^PLAYGROUND_APP_ID=' "$DEPLOY_DIR/.deploy.env" >"$tmp_env" 2>/dev/null || true
                grep -v '^PLAYGROUND_APP_SECRET=' "$tmp_env" >"${tmp_env}.2" 2>/dev/null || true
                mv "${tmp_env}.2" "$tmp_env"
                echo "PLAYGROUND_APP_ID=$PLAYGROUND_APP_ID" >>"$tmp_env"
                echo "PLAYGROUND_APP_SECRET=$PLAYGROUND_APP_SECRET" >>"$tmp_env"
                mv "$tmp_env" "$DEPLOY_DIR/.deploy.env"
            fi

            # Ensure .env.local is written with correct values.
            if [ "${API_DOMAIN}" == "localhost" ]; then
                PLAYGROUND_CHAT_API_URL="http://localhost:${BACKEND_PORT}"
                PLAYGROUND_BACKEND_URL="http://localhost:${PLAYGROUND_PORT:-3020}"
            else
                PLAYGROUND_CHAT_API_URL="https://${API_DOMAIN}"
                if [ -n "${PLAYGROUND_DOMAIN:-}" ] && [ "${PLAYGROUND_DOMAIN:-}" != "null" ]; then
                    PLAYGROUND_BACKEND_URL="https://${PLAYGROUND_DOMAIN}"
                else
                    PLAYGROUND_BACKEND_URL="https://${WEB_DOMAIN}"
                fi
            fi
            cat > "$PLAYGROUND_DIR/.env.local" <<EOF
ETHORA_CHAT_API_URL=${PLAYGROUND_CHAT_API_URL}
NEXT_PUBLIC_ETHORA_CHAT_API_URL=${PLAYGROUND_CHAT_API_URL}
ETHORA_CHAT_APP_ID=${PLAYGROUND_APP_ID}
ETHORA_CHAT_APP_SECRET=${PLAYGROUND_APP_SECRET}
NEXT_PUBLIC_BACKEND_URL=${PLAYGROUND_BACKEND_URL}
EOF
        fi

        if [ -z "${PLAYGROUND_APP_ID:-}" ] || [ -z "${PLAYGROUND_APP_SECRET:-}" ]; then
            warn "PLAYGROUND_APP_ID or PLAYGROUND_APP_SECRET is empty. SDK calls may fail until configured."
        fi

        if [ "$PLAYGROUND_MODE" = "image" ] && [ "${API_DOMAIN}" != "localhost" ]; then
            log "SDK playground runs from image $ETHORA_PLAYGROUND_IMAGE (no host build; Next builds inside the container on first start)"
            run_as_deploy_user "pm2 delete sdk-playground 2>/dev/null || true"
            image_up playground ETHORA_PLAYGROUND_IMAGE playground
            wait_for_port "SDK playground (image)" 127.0.0.1 "${PLAYGROUND_PORT:-3020}" 120 3 || true
        else
        image_down playground playground
        ensure_node_deps "$PLAYGROUND_DIR" "tailwindcss"

        if [ "${API_DOMAIN}" == "localhost" ]; then
            log "Localhost mode detected - starting SDK playground dev server..."
            run_as_deploy_user "pm2 delete sdk-playground 2>/dev/null || true"
            run_as_deploy_user "cd \"$PLAYGROUND_DIR\" && pm2 start npm --name sdk-playground --time --update-env -- run dev -- --hostname 0.0.0.0 --port ${PLAYGROUND_PORT:-3020}" \
                || warn "Failed to start SDK playground dev server"
        else
            if needs_project_build "sdk-playground" "$PLAYGROUND_DIR" "$PLAYGROUND_DIR/.next" "$PLAYGROUND_DIR/.env.local"; then
                log "Building SDK playground production bundle (${BUILD_REASON_RESULT})..."
                if run_as_deploy_user "cd \"$PLAYGROUND_DIR\" && npm run build"; then
                    record_project_build_hash "sdk-playground" "$PLAYGROUND_DIR" "$BUILD_HASH_RESULT"
                else
                    warn "SDK playground build failed"
                fi
            else
                log "SDK playground source unchanged; skipping production build"
            fi

            log "Starting SDK playground with PM2..."
            run_as_deploy_user "pm2 delete sdk-playground 2>/dev/null || true"
            run_as_deploy_user "cd \"$PLAYGROUND_DIR\" && pm2 start npm --name sdk-playground --time --update-env -- run start -- -p ${PLAYGROUND_PORT:-3020}" \
                || warn "Failed to start SDK playground"
        fi
        fi  # PLAYGROUND_MODE
    fi
fi

# Setup hosted MCP server (optional)
# Runs as PM2 process `mcp` (Streamable HTTP on 127.0.0.1:${MCP_PORT}); nginx
# publishes it on https://${MCP_DOMAIN}/mcp. Reads its config from
# $MCP_DIR/.env, rendered by setup-env.sh from templates/mcp.env.template.
if [ "${MCP_ENABLED:-false}" == "true" ]; then
    if [ ! -f "$MCP_DIR/package.json" ]; then
        warn "MCP server sources not found at $MCP_DIR (submodule not initialized?)"
    elif [ ! -f "$MCP_DIR/.env" ]; then
        warn "MCP server env not found at $MCP_DIR/.env (run setup-env.sh); skipping MCP server start"
    else
        log "Setting up hosted MCP server..."
        cd "$MCP_DIR"
        if [ "$MCP_MODE" = "image" ]; then
        log "MCP server runs from image $ETHORA_MCP_IMAGE (no host build)"
        run_as_deploy_user "pm2 delete mcp 2>/dev/null || true"
        image_up mcp ETHORA_MCP_IMAGE mcp
        wait_for_http "MCP server (image)" "http://127.0.0.1:${MCP_PORT:-3030}/healthz" 30 2 || warn "MCP server did not respond to /healthz within timeout."
        else
        image_down mcp mcp
        ensure_node_deps "$MCP_DIR" "typescript"

        if needs_project_build "mcp" "$MCP_DIR" "$MCP_DIR/dist/index.js"; then
            log "Building MCP server (${BUILD_REASON_RESULT})..."
            if run_as_deploy_user "cd \"$MCP_DIR\" && npm run build"; then
                record_project_build_hash "mcp" "$MCP_DIR" "$BUILD_HASH_RESULT"
            else
                warn "MCP server build failed"
            fi
        else
            log "MCP server source unchanged; skipping build"
        fi

        if [ -f "$MCP_DIR/dist/index.js" ]; then
            log "Starting MCP server with PM2..."
            run_as_deploy_user "pm2 delete mcp 2>/dev/null || true"
            run_as_deploy_user "cd \"$MCP_DIR\" && pm2 start dist/index.js --name mcp --time --update-env" \
                || warn "Failed to start MCP server"
            if ! wait_for_http "MCP server" "http://127.0.0.1:${MCP_PORT:-3030}/healthz" 30 2; then
                warn "MCP server did not respond to /healthz within timeout."
            fi
        else
            warn "MCP server build output missing at $MCP_DIR/dist/index.js; not starting PM2 process"
        fi
        fi  # MCP_MODE
    fi
else
    # Disabled in deploy.yml: make sure a previously started process does not linger.
    run_as_deploy_user "pm2 delete mcp 2>/dev/null || true"
fi

# Save PM2 process list
run_as_deploy_user "pm2 save" || warn "Failed to save PM2 process list"

# Ensure PM2 restarts on reboot (systemd).
# Without this, a reboot can leave backend/push down even though `pm2 save` was called.
ensure_pm2_startup() {
    # Only relevant on systemd-based hosts.
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    # Avoid false positives in containers or non-systemd init systems.
    if [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" != "systemd" ]; then
        return 0
    fi

    local deploy_user deploy_home pm2_bin
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        deploy_user="$SUDO_USER"
    else
        deploy_user="$(id -un 2>/dev/null || echo "root")"
    fi
    deploy_home="$(eval echo "~$deploy_user" 2>/dev/null || true)"
    if [ -z "$deploy_home" ] || [ "$deploy_home" == "~$deploy_user" ]; then
        deploy_home="$HOME"
    fi

    # Resolve the exact PM2 binary used by the deploy user (can differ under nvm/asdf).
    if command -v sudo >/dev/null 2>&1 && [ "$deploy_user" != "$(id -un 2>/dev/null || echo root)" ]; then
        pm2_bin="$(sudo -u "$deploy_user" -H bash -lc "command -v pm2" 2>/dev/null || true)"
    else
        pm2_bin="$(command -v pm2 2>/dev/null || true)"
    fi
    if [ -z "$pm2_bin" ]; then
        return 0
    fi

    log "Configuring PM2 systemd startup (pm2-${deploy_user}.service)..."
    if [ "$(id -u)" -eq 0 ]; then
        env PATH="$PATH:/usr/bin" "$pm2_bin" startup systemd -u "$deploy_user" --hp "$deploy_home" >/dev/null 2>&1 || warn "PM2 startup setup failed (systemd)."
        systemctl enable --now "pm2-${deploy_user}" >/dev/null 2>&1 || true
    else
        sudo env PATH="$PATH:/usr/bin" "$pm2_bin" startup systemd -u "$deploy_user" --hp "$deploy_home" >/dev/null 2>&1 || warn "PM2 startup setup failed (systemd)."
        sudo systemctl enable --now "pm2-${deploy_user}" >/dev/null 2>&1 || true
    fi
}
ensure_pm2_startup

log "Node.js services setup completed"

