#!/bin/bash

# Ejabberd Configuration Setup Script
# Updates Ejabberd config file with the correct domain

set -e

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

warn() {
    echo "[WARN] $1"
}

# In-place sed that works with both GNU sed (Linux) and BSD sed (macOS).
# BSD sed requires a suffix argument to -i, so a bare `sed -i "expr" file`
# silently consumes the expression as the suffix and fails — on macOS every
# render below would warn-and-skip, leaving url/secret blocks empty.
if sed --version >/dev/null 2>&1; then
    sed_i() { sed -i "$@"; }
else
    sed_i() { sed -i '' "$@"; }
fi

# Refresh deploy env in case deploy.yml changed.
REFRESH_SCRIPT="$DEPLOY_DIR/scripts/refresh-deploy-env.sh"
if [ -f "$REFRESH_SCRIPT" ]; then
    bash "$REFRESH_SCRIPT" || true
fi

# Source environment variables
ENV_FILE="$DEPLOY_DIR/.deploy.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    warn "Environment file not found: $ENV_FILE. Ejabberd config may not be updated correctly."
    exit 0
fi

if [ -z "$XMPP_DOMAIN" ]; then
    warn "XMPP_DOMAIN not set. Skipping Ejabberd config update."
    exit 0
fi

# Ensure EJABBERD_CONFIG_NAME is set when .deploy.env is stale or yq missing.
if [ -z "${EJABBERD_CONFIG_NAME:-}" ] || [ "${EJABBERD_CONFIG_NAME:-}" == "null" ]; then
    if [ "$XMPP_DOMAIN" == "localhost" ]; then
        EJABBERD_CONFIG_NAME="ejabberd-local.yml"
    else
        EJABBERD_CONFIG_NAME="ejabberd-prod.yml"
    fi
fi

log "Configuring Ejabberd for domain: $XMPP_DOMAIN"

# Get Ejabberd directory + config name from environment or use defaults
EJABBERD_DIR="${EJABBERD_DIR:-$ROOT_DIR/ejabberd-docker}"
EJABBERD_CONFIG="$EJABBERD_DIR/docker/$EJABBERD_CONFIG_NAME"

log "Ejabberd directory: $EJABBERD_DIR"
log "Ejabberd config file: $EJABBERD_CONFIG"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.enterprise.yml"

# Also ensure Ejabberd SQL password matches the MySQL container root password.
# If these diverge, Ejabberd may start but will fail XMPP features and drop HTTP requests (/ws, /bosh),
# resulting in nginx 502 and reconnect loops in the frontend.
update_sql_password() {
    local cfg="$1"
    if [ -z "${MYSQL_ROOT_PASSWORD:-}" ]; then
        warn "MYSQL_ROOT_PASSWORD is not set; skipping ejabberd sql_password update"
        return 0
    fi
    if [ ! -f "$cfg" ]; then
        warn "Ejabberd config not found for sql_password update: $cfg"
        return 0
    fi

    # Replace only the sql_password line (keep config structure intact).
    # Quote the value because passwords may include special characters.
    sed_i "s|^sql_password:.*|sql_password: \"${MYSQL_ROOT_PASSWORD}\"|g" "$cfg" || warn "Failed to update sql_password in $cfg"
    log "Updated ejabberd sql_password to match MYSQL_ROOT_PASSWORD"
    grep -n "^sql_username:" -n "$cfg" 2>/dev/null || true
    grep -n "^sql_password:" -n "$cfg" 2>/dev/null || true
}

# Ensure the admin/apicommands ACL JID matches the configured XMPP domain.
# Otherwise Ejabberd HTTP API (/api/register etc) returns 403:
#   AccessRules: Account does not have the right to perform the operation.
update_api_acl_admin_jid() {
    local cfg="$1"
    if [ ! -f "$cfg" ]; then
        return 0
    fi
    local desired="admin@${XMPP_DOMAIN}"
    # Replace any existing JID entries inside acl.admin.user and acl.apicommands.user blocks.
    # Keep it simple and safe: only rewrite the quoted JID line, not the surrounding YAML.
    sed_i \
      -e "/^  admin:/,/^  [a-z]/ s|^[ ]*- \\\"[^\\\"]*\\\"|      - \\\"${desired}\\\"|g" \
      -e "/^  apicommands:/,/^  [a-z]/ s|^[ ]*- \\\"[^\\\"]*\\\"|      - \\\"${desired}\\\"|g" \
      "$cfg" || warn "Failed to update ejabberd acl admin/apicommands JID"
    log "Updated ejabberd acl admin/apicommands to: ${desired}"
    grep -n "^[ ]*admin:" -A3 "$cfg" 2>/dev/null || true
    grep -n "^[ ]*apicommands:" -A3 "$cfg" 2>/dev/null || true
}

update_tracking_urls_and_secret() {
    local cfg="$1"
    if [ ! -f "$cfg" ]; then
        return 0
    fi
    if [ -z "${TRACK_MEMBER_URL:-}" ] || [ -z "${TRACK_LAST_MESSAGE_URL:-}" ]; then
        warn "TRACK_MEMBER_URL / TRACK_LAST_MESSAGE_URL not set; skipping ejabberd tracking URL update"
        return 0
    fi
    if [ -z "${XMPP_SECRET:-}" ]; then
        warn "XMPP_SECRET not set; leaving ejabberd track secrets empty. The backend rejects an empty secret (fail closed), so tracking/audit callbacks stay DISABLED until you set security.xmpp_secret (or let the installer auto-generate it)."
        return 0
    fi

    # Update custom module URLs + secret (mod_track_member / mod_track_last_message /
    # mod_track_message). These modules post to the backend on each membership/message
    # event: track_member/track_last_message update app stats + chat-list previews,
    # track_message archives every message to the chat archive (search / unread).
    sed_i \
      -e "/^  mod_track_member:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"${TRACK_MEMBER_URL}\"|g" \
      -e "/^  mod_track_member:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"${XMPP_SECRET}\"|g" \
      -e "/^  mod_track_last_message:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"${TRACK_LAST_MESSAGE_URL}\"|g" \
      -e "/^  mod_track_last_message:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"${XMPP_SECRET}\"|g" \
      "$cfg" || warn "Failed to update ejabberd tracking urls/secrets"

    # mod_track_message is optional (only present once the ejabberd image ships it).
    # Substitute its url/secret only when the block exists so older configs don't break.
    if [ -n "${TRACK_MESSAGE_URL:-}" ] && grep -q "^  mod_track_message:" "$cfg"; then
      sed_i \
        -e "/^  mod_track_message:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"${TRACK_MESSAGE_URL}\"|g" \
        -e "/^  mod_track_message:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"${XMPP_SECRET}\"|g" \
        "$cfg" || warn "Failed to update mod_track_message url/secret"
    fi

    # mod_history_access posts MAM (XEP-0313) history-read audit events to the
    # backend, which records them in the `logs` collection for compliance
    # reporting. Same optional-block guard as mod_track_message: an older image's
    # config has no such block, and the install must not fail on that.
    if [ -n "${HISTORY_ACCESS_URL:-}" ] && grep -q "^  mod_history_access:" "$cfg"; then
      sed_i \
        -e "/^  mod_history_access:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"${HISTORY_ACCESS_URL}\"|g" \
        -e "/^  mod_history_access:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"${XMPP_SECRET}\"|g" \
        "$cfg" || warn "Failed to update mod_history_access url/secret"
    fi

    # mod_edit / mod_delete post message edit/delete audit events to the same
    # backend `logs` pipeline (POST /v1/chats/message-audit). Both share one
    # URL. The stock prod config ships them as bare `mod_edit: {}` /
    # `mod_delete: {}` blocks with no url/secret lines, so a plain
    # substitution is a no-op there and the modules never post (the backend
    # then never sees edits/deletes for the message archive). Expand a bare
    # block into empty url/secret lines first, then render it like the rest.
    if [ -n "${MESSAGE_AUDIT_URL:-}" ]; then
      for audit_mod in mod_edit mod_delete; do
        if grep -qE "^  ${audit_mod}:[[:space:]]*\{\}[[:space:]]*$" "$cfg"; then
          sed_i \
            -e "s|^  ${audit_mod}:[[:space:]]*{}[[:space:]]*$|  ${audit_mod}:|" \
            -e "/^  ${audit_mod}:$/a\    url: \"\"" \
            -e "/^  ${audit_mod}:$/a\    secret: \"\"" \
            "$cfg" || warn "Failed to expand bare ${audit_mod} block"
        fi
        if grep -q "^  ${audit_mod}:" "$cfg"; then
          sed_i \
            -e "/^  ${audit_mod}:/,/^  [a-z_]/ s|^[ ]*url:.*|    url: \"${MESSAGE_AUDIT_URL}\"|g" \
            -e "/^  ${audit_mod}:/,/^  [a-z_]/ s|^[ ]*secret:.*|    secret: \"${XMPP_SECRET}\"|g" \
            "$cfg" || warn "Failed to update ${audit_mod} url/secret"
        fi
      done
    fi

    log "Updated ejabberd tracking modules:"
    grep -n "mod_track_member:" -A3 "$cfg" 2>/dev/null || true
    grep -n "mod_track_last_message:" -A3 "$cfg" 2>/dev/null || true
    grep -n "mod_track_message:" -A3 "$cfg" 2>/dev/null || true
    grep -n "mod_history_access:" -A3 "$cfg" 2>/dev/null || true
    grep -n "mod_edit:" -A3 "$cfg" 2>/dev/null || true
    grep -n "mod_delete:" -A3 "$cfg" 2>/dev/null || true
}

update_offline_post_urls_and_secret() {
    local cfg="$1"
    if [ ! -f "$cfg" ]; then
        return 0
    fi

    # Derive defaults:
    # - localhost installs: ejabberd runs in docker and must reach host services via host.docker.internal
    # - production installs: use the public API domain and reverse-proxy /push/ to the local push service
    local common_url=""
    if [ -n "${PUSH_COMMON_POST_URL:-}" ] && [ "${PUSH_COMMON_POST_URL:-}" != "null" ]; then
        common_url="$PUSH_COMMON_POST_URL"
    else
        if [ "${API_DOMAIN:-}" == "localhost" ]; then
            common_url="http://host.docker.internal:${PUSH_PORT:-8098}/api/v2/push"
        else
            common_url="https://${API_DOMAIN}/push/api/v2/push"
        fi
    fi

    local voip_url=""
    if [ -n "${PUSH_VOIP_POST_URL:-}" ] && [ "${PUSH_VOIP_POST_URL:-}" != "null" ]; then
        voip_url="$PUSH_VOIP_POST_URL"
    else
        # Keep legacy default (best-effort; only used when VoIP payload is sent).
        voip_url="http://host.docker.internal:7778/api/v1/voippush"
    fi

    # mod_offline_post uses auth_token and sends it as access_token form field.
    # Reuse B2B_PUSH_SECRET so we don't introduce yet another secret.
    local token="${B2B_PUSH_SECRET:-}"
    if [ -z "$token" ]; then
        token="${INTERNAL_REQUESTS_SECRET:-}"
    fi

    if [ -z "$common_url" ]; then
        warn "PUSH common_post_url is empty; skipping mod_offline_post url update"
        return 0
    fi

    sed_i \
      -e "/^  mod_offline_post:/,/^  [a-z_]/ s|^[ ]*common_post_url:.*|    common_post_url: \"${common_url}\"|g" \
      -e "/^  mod_offline_post:/,/^  [a-z_]/ s|^[ ]*voip_post_url:.*|    voip_post_url: \"${voip_url}\"|g" \
      -e "/^  mod_offline_post:/,/^  [a-z_]/ s|^[ ]*auth_token:.*|    auth_token: \"${token}\"|g" \
      "$cfg" || warn "Failed to update mod_offline_post urls/token"

    log "Updated ejabberd mod_offline_post:"
    grep -n "mod_offline_post:" -A4 "$cfg" 2>/dev/null || true
}

update_translate_url() {
    local cfg="$1"
    if [ -z "${TRANSLATE_URL:-}" ]; then
        return 0
    fi
    if [ ! -f "$cfg" ]; then
        return 0
    fi
    # Replace only the active (non-commented) translate_url line, preserving indent.
    sed_i "s|^\([[:space:]]*\)translate_url:.*|\1translate_url: \"${TRANSLATE_URL}\"|" "$cfg" \
      || warn "Failed to update translate_url in $cfg"
    log "Updated ejabberd translate_url"
    grep -n "translate_url:" "$cfg" 2>/dev/null || true
}

update_certfiles_path() {
    local cfg="$1"
    if [ ! -f "$cfg" ]; then
        return 0
    fi
    # Update any /cert/*.pem entry to the current XMPP domain cert.
    sed_i "s|/cert/[^\" ]*\\.pem|/cert/${XMPP_DOMAIN}.pem|g" "$cfg" || warn "Failed to update certfiles path in $cfg"
    log "Updated ejabberd certfiles path to /cert/${XMPP_DOMAIN}.pem"
    grep -n "^certfiles:" -A2 "$cfg" 2>/dev/null || true
}

# Enable JWT SASL auth: the client connects with a short-lived JWT (issued by the
# backend, signed with XMPP_JWT_SECRET) as its password instead of the raw
# xmppPassword. ejabberd verifies it via jwt_key. We render the JWK key file from
# the same shared secret and add `jwt` to auth_method (keeping sql for register /
# system accounts / bots, and anonymous for widget/anon logins).
update_jwt_auth() {
    local cfg="$1"
    if [ ! -f "$cfg" ]; then
        return 0
    fi
    if [ -z "${XMPP_JWT_SECRET:-}" ] || [ "${XMPP_JWT_SECRET:-}" == "null" ]; then
        warn "XMPP_JWT_SECRET not set; skipping ejabberd JWT auth"
        return 0
    fi
    # JWK (oct) key file ejabberd verifies the token with. k = base64url(secret);
    # the backend signs the JWT with the same raw secret, so the HMAC keys match.
    local k keyfile
    k="$(printf '%s' "$XMPP_JWT_SECRET" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
    keyfile="$EJABBERD_DIR/docker/jwt.key"
    printf '{"kty":"oct","k":"%s"}' "$k" > "$keyfile" || { warn "Failed to write $keyfile"; return 0; }
    sed_i "s|^auth_method:.*|auth_method: [sql, jwt, anonymous]|" "$cfg" || warn "Failed to set auth_method"
    if ! grep -qE "^jwt_key:" "$cfg"; then
        sed_i "/^auth_method:/a jwt_key: \"/home/ejabberd/conf/jwt.key\"" "$cfg" || warn "Failed to add jwt_key"
        sed_i "/^jwt_key:/a jwt_jid_field: \"jid\"" "$cfg" || warn "Failed to add jwt_jid_field"
    fi
    log "Configured ejabberd JWT auth (auth_method + jwt_key)"
}

# Update the hosts section in ejabberd.yml
if [ "$XMPP_DOMAIN" == "localhost" ]; then
    log "Using localhost configuration for Ejabberd"
    # For localhost, use the local config which already has localhost
    if [ -f "$EJABBERD_DIR/docker/ejabberd-local.yml" ]; then
        # When EJABBERD_CONFIG_NAME is ejabberd-local.yml, source and destination
        # are the same file; cp errors out and (with set -e) aborts the script
        # before any url/secret rendering happens. Render in place instead.
        if [ "$EJABBERD_DIR/docker/ejabberd-local.yml" != "$EJABBERD_CONFIG" ]; then
            cp "$EJABBERD_DIR/docker/ejabberd-local.yml" "$EJABBERD_CONFIG"
            log "Copied ejabberd-local.yml -> $EJABBERD_CONFIG (configured for localhost)"
        else
            log "Config is ejabberd-local.yml itself; rendering in place"
        fi
        update_api_acl_admin_jid "$EJABBERD_CONFIG"
        update_sql_password "$EJABBERD_CONFIG"
        update_tracking_urls_and_secret "$EJABBERD_CONFIG"
        update_offline_post_urls_and_secret "$EJABBERD_CONFIG"
        update_certfiles_path "$EJABBERD_CONFIG"
        update_translate_url "$EJABBERD_CONFIG"
        update_jwt_auth "$EJABBERD_CONFIG"
    else
        warn "ejabberd-local.yml not found, using existing config"
    fi
else
    log "Updating Ejabberd config for domain: $XMPP_DOMAIN"
    # For production, update the hosts line using sed
    if [ -f "$EJABBERD_CONFIG" ]; then
        # Simple sed replacement - find hosts: line and the next line with domain
        sed_i "/^hosts:/,/^[a-z]/s/^  -.*/  - $XMPP_DOMAIN/" "$EJABBERD_CONFIG" || \
        sed_i "s/^  - .*/  - $XMPP_DOMAIN/" "$EJABBERD_CONFIG" || \
        warn "Could not automatically update Ejabberd hosts - manual edit may be needed"
        log "Updated Ejabberd hosts to: $XMPP_DOMAIN"
        # Show the result for quick troubleshooting (helps when multiple ejabberd.yml files exist).
        grep -n "^hosts:" -A2 "$EJABBERD_CONFIG" || true
        update_api_acl_admin_jid "$EJABBERD_CONFIG"
        update_sql_password "$EJABBERD_CONFIG"
        update_tracking_urls_and_secret "$EJABBERD_CONFIG"
        update_offline_post_urls_and_secret "$EJABBERD_CONFIG"
        update_certfiles_path "$EJABBERD_CONFIG"
        update_translate_url "$EJABBERD_CONFIG"
        update_jwt_auth "$EJABBERD_CONFIG"
    else
        warn "ejabberd.yml not found, creating from template..."
        if [ -f "$ROOT_DIR/ejabberd-docker/docker/ejabberd-prod.yml" ]; then
            cp "$ROOT_DIR/ejabberd-docker/docker/ejabberd-prod.yml" "$EJABBERD_CONFIG"
            sed_i "s/^  - .*/  - $XMPP_DOMAIN/" "$EJABBERD_CONFIG"
            grep -n "^hosts:" -A2 "$EJABBERD_CONFIG" || true
            update_api_acl_admin_jid "$EJABBERD_CONFIG"
            update_sql_password "$EJABBERD_CONFIG"
            update_tracking_urls_and_secret "$EJABBERD_CONFIG"
            update_offline_post_urls_and_secret "$EJABBERD_CONFIG"
            update_certfiles_path "$EJABBERD_CONFIG"
            update_translate_url "$EJABBERD_CONFIG"
        update_jwt_auth "$EJABBERD_CONFIG"
        else
            warn "No Ejabberd template found"
        fi
    fi
fi

log "Ejabberd configuration updated"

# Note: Updating the host config file is not enough if the Ejabberd container isn't restarted.
# The most common pitfall is running docker-compose from $ROOT_DIR and using a relative compose path,
# which fails when ROOT_DIR is a custom base (e.g. /home/ubuntu/deptest) and the compose file lives in $DEPLOY_DIR.
if [ -f "$COMPOSE_FILE" ]; then
    log "To apply Ejabberd config changes, restart xmpp with:"
    echo "  sudo bash -lc 'source \"$ENV_FILE\"; docker-compose -f \"$COMPOSE_FILE\" restart xmpp'"
    echo "  # If restart doesn't pick up changes (rare), force recreate:"
    echo "  sudo bash -lc 'source \"$ENV_FILE\"; docker-compose -f \"$COMPOSE_FILE\" up -d --force-recreate xmpp'"
else
    warn "Compose file not found at $COMPOSE_FILE. If your xmpp container is running, restart it so config changes take effect."
    warn "Example: sudo docker restart deploy-xmpp-1"
fi
