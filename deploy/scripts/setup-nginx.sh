#!/bin/bash

# Nginx Configuration Setup Script
# Generates Nginx configurations from templates

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
NGINX_CONF_DIR="/etc/nginx/conf.d"

# Refresh domain/base app values in .deploy.env if deploy.yml changed.
REFRESH_SCRIPT="$DEPLOY_DIR/scripts/refresh-deploy-env.sh"
if [ -f "$REFRESH_SCRIPT" ]; then
    bash "$REFRESH_SCRIPT" || true
fi

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root or with sudo"
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

# Root/apex domain = web domain minus its first label (app.chat.example.com
# -> chat.example.com). Used for the bare-domain -> app redirect below.
ROOT_DOMAIN="${ROOT_DOMAIN:-$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')}"

# Optional: refresh playground settings from deploy.yml (useful for upgrades)
CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"
if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    if [ -z "${PLAYGROUND_ENABLED:-}" ] || [ "${PLAYGROUND_ENABLED:-}" == "null" ]; then
        PLAYGROUND_ENABLED="$(yq eval '.services.playground.enabled | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; PLAYGROUND_ENABLED="${PLAYGROUND_ENABLED:-true}"
    fi
    if [ -z "${WIDGET_ENABLED:-}" ] || [ "${WIDGET_ENABLED:-}" == "null" ]; then
        WIDGET_ENABLED="$(yq eval '.services.widget.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    fi
    if [ -z "${PLAYGROUND_DOMAIN:-}" ] || [ "${PLAYGROUND_DOMAIN:-}" == "null" ]; then
        PLAYGROUND_DOMAIN="$(yq eval '.domains.playground // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${WIDGET_DOMAIN:-}" ] || [ "${WIDGET_DOMAIN:-}" == "null" ]; then
        WIDGET_DOMAIN="$(yq eval '.domains.widget // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${HOSTED_APPS_ROOT_DOMAIN:-}" ] || [ "${HOSTED_APPS_ROOT_DOMAIN:-}" == "null" ]; then
        HOSTED_APPS_ROOT_DOMAIN="$(yq eval '.domains.hosted_apps_root // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${PLAYGROUND_PORT:-}" ] || [ "${PLAYGROUND_PORT:-}" == "null" ]; then
        PLAYGROUND_PORT="$(yq eval '.services.playground.port // 3020' "$CONFIG_FILE" 2>/dev/null || echo "3020")"
    fi
    if [ -z "${WIDGET_SCRIPT_VERSION:-}" ] || [ "${WIDGET_SCRIPT_VERSION:-}" == "null" ]; then
        WIDGET_SCRIPT_VERSION="$(yq eval '.services.widget.script_version // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    # Hosted MCP server (optional): re-read the toggle raw so an explicit false wins.
    mcp_enabled_raw="$(yq eval '.services.mcp.enabled' "$CONFIG_FILE" 2>/dev/null)"
    if [ "$mcp_enabled_raw" = "true" ] || [ "$mcp_enabled_raw" = "false" ]; then
        MCP_ENABLED="$mcp_enabled_raw"
    else
        MCP_ENABLED="${MCP_ENABLED:-false}"
    fi
    if [ -z "${MCP_DOMAIN:-}" ] || [ "${MCP_DOMAIN:-}" == "null" ]; then
        MCP_DOMAIN="$(yq eval '.domains.mcp // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${MCP_PORT:-}" ] || [ "${MCP_PORT:-}" == "null" ]; then
        MCP_PORT="$(yq eval '.services.mcp.port // 3030' "$CONFIG_FILE" 2>/dev/null || echo "3030")"
    fi
    if [ -z "${HOSTED_APPS_ENABLED:-}" ] || [ "${HOSTED_APPS_ENABLED:-}" == "null" ]; then
        HOSTED_APPS_ENABLED="$(yq eval '.services.hosted_apps.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    fi
    if [ -z "${UPTIME_DOMAIN:-}" ] || [ "${UPTIME_DOMAIN:-}" == "null" ]; then
        UPTIME_DOMAIN="$(yq eval '.domains.uptime // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${UPTIME_PORT:-}" ] || [ "${UPTIME_PORT:-}" == "null" ]; then
        UPTIME_PORT="$(yq eval '.services.uptime.port // 8099' "$CONFIG_FILE" 2>/dev/null || echo "8099")"
    fi
    if [ -z "${API_CLIENT_MAX_BODY_SIZE:-}" ] || [ "${API_CLIENT_MAX_BODY_SIZE:-}" == "null" ]; then
        API_CLIENT_MAX_BODY_SIZE="$(yq eval '.services.backend.client_max_body_size // "50M"' "$CONFIG_FILE" 2>/dev/null || echo "50M")"
    fi
fi

if [ -z "${API_CLIENT_MAX_BODY_SIZE:-}" ] || [ "${API_CLIENT_MAX_BODY_SIZE:-}" == "null" ]; then
    API_CLIENT_MAX_BODY_SIZE="50M"
fi

# MCP domain fallback: mcp.<root-of-web> when enabled and not set (mirrors setup-env.sh).
if [ "${MCP_ENABLED:-false}" == "true" ] && \
   { [ -z "${MCP_DOMAIN:-}" ] || [ "${MCP_DOMAIN:-}" == "null" ]; } && \
   [ -n "${WEB_DOMAIN:-}" ] && [ "$WEB_DOMAIN" != "localhost" ] && [[ "$WEB_DOMAIN" == *.* ]]; then
    MCP_DOMAIN="mcp.$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')"
fi

# Basic-auth for the uptime pages + load-test control API.
# Referenced by nginx/uptime.conf.template (auth_basic_user_file).
UPTIME_HTPASSWD_FILE="/etc/nginx/ethora-uptime.htpasswd"

# (Re)generate the uptime htpasswd file. User/password come from deploy.yml
# (.services.uptime.auth_user / auth_password); when no password is configured we
# generate a strong one once and persist it to .deploy.env so it stays stable
# across deploys (retrieve with `grep UPTIME_AUTH_PASSWORD .deploy.env`). The
# hashed file is rewritten every run from the resolved values.
setup_uptime_basic_auth() {
    local user="${UPTIME_AUTH_USER:-}"
    local pass="${UPTIME_AUTH_PASSWORD:-}"
    if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
        [ -z "$user" ] && user="$(yq eval '.services.uptime.auth_user // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
        [ -z "$pass" ] && pass="$(yq eval '.services.uptime.auth_password // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    [ "$user" == "null" ] && user=""
    [ "$pass" == "null" ] && pass=""
    [ -z "$user" ] && user="admin"
    if [ -z "$pass" ]; then
        pass="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-24)"
        if [ -f "$ENV_FILE" ]; then
            local tmp
            tmp="$(mktemp)"
            grep -v '^export UPTIME_AUTH_USER=' "$ENV_FILE" 2>/dev/null | grep -v '^export UPTIME_AUTH_PASSWORD=' > "$tmp" || true
            printf 'export UPTIME_AUTH_USER="%s"\n' "$user" >> "$tmp"
            printf 'export UPTIME_AUTH_PASSWORD="%s"\n' "$pass" >> "$tmp"
            cat "$tmp" > "$ENV_FILE"
            rm -f "$tmp"
            chmod 600 "$ENV_FILE" 2>/dev/null || true
        fi
        log "Generated uptime basic-auth (user: $user). Retrieve password: grep UPTIME_AUTH_PASSWORD $ENV_FILE"
    fi
    printf '%s:%s\n' "$user" "$(openssl passwd -apr1 "$pass")" > "$UPTIME_HTPASSWD_FILE"
    chmod 640 "$UPTIME_HTPASSWD_FILE" 2>/dev/null || true
    chown root:www-data "$UPTIME_HTPASSWD_FILE" 2>/dev/null || true
    log "Wrote uptime basic-auth file: $UPTIME_HTPASSWD_FILE (user: $user)"
}

# Skip Nginx setup for localhost
if [ "$API_DOMAIN" == "localhost" ]; then
    log "Skipping Nginx setup (localhost mode)"
    exit 0
fi

# Replace template variables
replace_template() {
    local template_file="$1"
    local output_file="$2"
    
    if [ ! -f "$template_file" ]; then
        error "Template file not found: $template_file"
    fi
    
    local content=$(cat "$template_file")
    
    # Replace variables
    content=$(echo "$content" | sed "s|{{API_DOMAIN}}|${API_DOMAIN}|g")
    content=$(echo "$content" | sed "s|{{WEB_DOMAIN}}|${WEB_DOMAIN}|g")
    content=$(echo "$content" | sed "s|{{ROOT_DOMAIN}}|${ROOT_DOMAIN:-}|g")
    content=$(echo "$content" | sed "s|{{XMPP_DOMAIN}}|${XMPP_DOMAIN}|g")
    content=$(echo "$content" | sed "s|{{FILES_DOMAIN}}|${FILES_DOMAIN}|g")
    content=$(echo "$content" | sed "s|{{SECURE_FILES_DOMAIN}}|${SECURE_FILES_DOMAIN:-}|g")
    content=$(echo "$content" | sed "s|{{BACKEND_PORT}}|${BACKEND_PORT}|g")
    content=$(echo "$content" | sed "s|{{API_CLIENT_MAX_BODY_SIZE}}|${API_CLIENT_MAX_BODY_SIZE}|g")
    content=$(echo "$content" | sed "s|{{PUSH_PORT}}|${PUSH_PORT:-8098}|g")
    content=$(echo "$content" | sed "s|{{FRONTEND_BUILD_DIR}}|${ROOT_DIR}/ethora-app-reactjs/dist|g")
    content=$(echo "$content" | sed "s|{{PLAYGROUND_DOMAIN}}|${PLAYGROUND_DOMAIN:-}|g")
    content=$(echo "$content" | sed "s|{{PLAYGROUND_PORT}}|${PLAYGROUND_PORT:-3020}|g")
    content=$(echo "$content" | sed "s|{{MCP_DOMAIN}}|${MCP_DOMAIN:-}|g")
    content=$(echo "$content" | sed "s|{{MCP_PORT}}|${MCP_PORT:-3030}|g")
    content=$(echo "$content" | sed "s|{{WIDGET_DOMAIN}}|${WIDGET_DOMAIN:-}|g")
    content=$(echo "$content" | sed "s|{{WIDGET_BUILD_DIR}}|${ROOT_DIR}/ethora-ai-chat-widget/dist|g")
    content=$(echo "$content" | sed "s|{{WIDGET_SCRIPT_VERSION}}|${WIDGET_SCRIPT_VERSION:-}|g")
    content=$(echo "$content" | sed "s|{{HOSTED_APPS_ROOT_DOMAIN}}|${HOSTED_APPS_ROOT_DOMAIN:-}|g")
    content=$(echo "$content" | sed "s|{{HOSTED_APPS_TLS_DOMAIN}}|${HOSTED_APPS_ROOT_DOMAIN:-}|g")
    content=$(echo "$content" | sed "s|{{UPTIME_DOMAIN}}|${UPTIME_DOMAIN:-}|g")
    content=$(echo "$content" | sed "s|{{UPTIME_PORT}}|${UPTIME_PORT:-8099}|g")
    
    echo "$content" > "$output_file"
    log "Generated Nginx config: $output_file"
}

log "Setting up Nginx configurations..."

# Remove stale optional configs when corresponding services are disabled or domains are unset.
remove_config_if_present() {
    local output_file="$1"
    if [ -f "$output_file" ]; then
        rm -f "$output_file"
        log "Removed Nginx config: $output_file"
    fi
}

# Generate API configuration
replace_template \
    "$DEPLOY_DIR/nginx/api.conf.template" \
    "$NGINX_CONF_DIR/ethora-api.conf"

# Generate Web configuration
replace_template \
    "$DEPLOY_DIR/nginx/web.conf.template" \
    "$NGINX_CONF_DIR/ethora-web.conf"

# Generate Files configuration
replace_template \
    "$DEPLOY_DIR/nginx/files.conf.template" \
    "$NGINX_CONF_DIR/ethora-files.conf"

# Generate Secure Files configuration (optional: membership-gated chat attachments)
if [ -n "${SECURE_FILES_DOMAIN:-}" ] && [ "${SECURE_FILES_DOMAIN:-}" != "null" ]; then
    replace_template \
        "$DEPLOY_DIR/nginx/secure-files.conf.template" \
        "$NGINX_CONF_DIR/ethora-secure-files.conf"
else
    remove_config_if_present "$NGINX_CONF_DIR/ethora-secure-files.conf"
fi

# Generate XMPP configuration (optional)
replace_template \
    "$DEPLOY_DIR/nginx/xmpp.conf.template" \
    "$NGINX_CONF_DIR/ethora-xmpp.conf"

# Generate Playground configuration (optional)
if [ "${PLAYGROUND_ENABLED:-false}" == "true" ] && [ -n "${PLAYGROUND_DOMAIN:-}" ] && [ "${PLAYGROUND_DOMAIN:-}" != "null" ]; then
    replace_template \
        "$DEPLOY_DIR/nginx/playground.conf.template" \
        "$NGINX_CONF_DIR/ethora-playground.conf"
else
    remove_config_if_present "$NGINX_CONF_DIR/ethora-playground.conf"
fi

# Generate hosted MCP server configuration (optional)
if [ "${MCP_ENABLED:-false}" == "true" ] && [ -n "${MCP_DOMAIN:-}" ] && [ "${MCP_DOMAIN:-}" != "null" ]; then
    replace_template \
        "$DEPLOY_DIR/nginx/mcp.conf.template" \
        "$NGINX_CONF_DIR/ethora-mcp.conf"
else
    remove_config_if_present "$NGINX_CONF_DIR/ethora-mcp.conf"
fi

# Generate Widget configuration (optional)
if [ "${WIDGET_ENABLED:-false}" == "true" ] && [ -n "${WIDGET_DOMAIN:-}" ] && [ "${WIDGET_DOMAIN:-}" != "null" ]; then
    replace_template \
        "$DEPLOY_DIR/nginx/widget.conf.template" \
        "$NGINX_CONF_DIR/ethora-widget.conf"
else
    remove_config_if_present "$NGINX_CONF_DIR/ethora-widget.conf"
fi

if [ "${HOSTED_APPS_ENABLED:-false}" == "true" ] && [ -n "${HOSTED_APPS_ROOT_DOMAIN:-}" ] && [ "${HOSTED_APPS_ROOT_DOMAIN:-}" != "null" ]; then
    replace_template \
        "$DEPLOY_DIR/nginx/hosted-apps.conf.template" \
        "$NGINX_CONF_DIR/ethora-hosted-apps.conf"
else
    remove_config_if_present "$NGINX_CONF_DIR/ethora-hosted-apps.conf"
fi

# Generate Uptime configuration (optional)
if [ "${UPTIME_ENABLED:-false}" == "true" ] && [ -n "${UPTIME_DOMAIN:-}" ] && [ "${UPTIME_DOMAIN:-}" != "null" ]; then
    # Must run before rendering: the conf references the htpasswd file, so it has
    # to exist or `nginx -t` fails.
    setup_uptime_basic_auth
    # Hand the (optional) monitoring stack its public base URL so Grafana and
    # Prometheus emit correct absolute links behind the /grafana//prometheus/
    # sub-paths, plus everything Grafana alerting needs: recipients, SMTP and
    # whether to run the screenshot renderer. SMTP defaults to the platform's
    # Postmark server token (integrations.postmark) unless
    # services.monitoring.alerts.smtp_* override it. docker compose auto-loads
    # this .env from the compose directory.
    if [ -d "$DEPLOY_DIR/monitoring" ]; then
        mon_cfg() { yq eval "$1 // \"\"" "$CONFIG_FILE" 2>/dev/null || echo ""; }
        alert_emails="$(mon_cfg '.services.monitoring.alerts.emails')"
        smtp_host="$(mon_cfg '.services.monitoring.alerts.smtp_host')"
        smtp_user="$(mon_cfg '.services.monitoring.alerts.smtp_user')"
        smtp_password="$(mon_cfg '.services.monitoring.alerts.smtp_password')"
        smtp_from="$(mon_cfg '.services.monitoring.alerts.smtp_from')"
        screenshots="$(mon_cfg '.services.monitoring.screenshots')"
        if [ -z "$smtp_host" ]; then
            postmark_token="$(mon_cfg '.integrations.postmark.token')"
            if [ -n "$postmark_token" ]; then
                smtp_host="smtp.postmarkapp.com:587"
                smtp_user="$postmark_token"
                smtp_password="$postmark_token"
                [ -n "$smtp_from" ] || smtp_from="$(mon_cfg '.integrations.postmark.from_email')"
            fi
        fi
        smtp_enabled="false"
        [ -n "$smtp_host" ] && smtp_enabled="true"
        renderer_profile=""
        [ "$screenshots" == "true" ] && renderer_profile="renderer"

        # Render the alerting provisioning. Grafana validates the e-mail
        # contact point at start-up and exits when `addresses` is empty, so
        # with no recipients configured we provision no contact point at all
        # and route the notification policy to Grafana's built-in
        # grafana-default-email receiver. Rules and templates ship either way.
        alerting_src="$DEPLOY_DIR/monitoring/grafana/provisioning/alerting"
        alerting_dir="$DEPLOY_DIR/generated/monitoring/alerting"
        mkdir -p "$alerting_dir" && rm -f "$alerting_dir"/*.yml
        for f in rules.yml templates.yml; do
            [ -f "$alerting_src/$f" ] && cp "$alerting_src/$f" "$alerting_dir/$f"
        done
        if [ -n "$alert_emails" ]; then
            cp "$alerting_src/contact-points.yml" "$alerting_dir/contact-points.yml"
            cp "$alerting_src/policies.yml" "$alerting_dir/policies.yml"
        else
            sed 's/receiver: ethora-email/receiver: grafana-default-email/' "$alerting_src/policies.yml" > "$alerting_dir/policies.yml"
            log "Monitoring: no services.monitoring.alerts.emails configured; Grafana alerts route to the built-in default receiver (no e-mail)."
        fi
        chmod -R a+rX "$alerting_dir" 2>/dev/null || true
        {
            printf 'MONITORING_BASE_URL=https://%s\n' "$UPTIME_DOMAIN"
            printf 'GRAFANA_ALERT_EMAILS="%s"\n' "$alert_emails"
            printf 'GRAFANA_ALERTING_DIR="%s"\n' "$alerting_dir"
            printf 'GRAFANA_SMTP_ENABLED=%s\n' "$smtp_enabled"
            printf 'GRAFANA_SMTP_HOST="%s"\n' "$smtp_host"
            printf 'GRAFANA_SMTP_USER="%s"\n' "$smtp_user"
            printf 'GRAFANA_SMTP_PASSWORD="%s"\n' "$smtp_password"
            printf 'GRAFANA_SMTP_FROM="%s"\n' "$smtp_from"
            printf 'GRAFANA_SCREENSHOTS=%s\n' "${screenshots:-false}"
            printf 'COMPOSE_PROFILES=%s\n' "$renderer_profile"
        } > "$DEPLOY_DIR/monitoring/.env" 2>/dev/null || true
        chmod 600 "$DEPLOY_DIR/monitoring/.env" 2>/dev/null || true
    fi
    replace_template \
        "$DEPLOY_DIR/nginx/uptime.conf.template" \
        "$NGINX_CONF_DIR/ethora-uptime.conf"
else
    remove_config_if_present "$NGINX_CONF_DIR/ethora-uptime.conf"
    rm -f "$UPTIME_HTPASSWD_FILE" 2>/dev/null || true
fi

# Bare root/apex domain -> app subdomain redirect (so e.g. chat.example.com
# lands on the app login instead of nginx's default "Welcome" page). Only
# when the apex differs from the web domain AND a cert covering the apex
# exists (the hosted-apps wildcard provides apex + *.<root>). The cert check
# avoids referencing a missing certificate, which would fail `nginx -t`.
if [ -n "${ROOT_DOMAIN:-}" ] && [ "${ROOT_DOMAIN}" != "${WEB_DOMAIN}" ] && [ -f "/etc/letsencrypt/live/${ROOT_DOMAIN}/fullchain.pem" ]; then
    replace_template \
        "$DEPLOY_DIR/nginx/root-redirect.conf.template" \
        "$NGINX_CONF_DIR/ethora-root-redirect.conf"
else
    remove_config_if_present "$NGINX_CONF_DIR/ethora-root-redirect.conf"
fi

# Bump top-level nginx limits in /etc/nginx/nginx.conf if the host is still
# on the stock defaults. Stock is `worker_connections 768;` with no
# `worker_rlimit_nofile`, which is inadequate for an Ethora host because
# every running bot in ai-service holds a persistent XMPP WebSocket
# connection through this nginx instance. With ~2000 bots (the realistic
# fleet size after the legacy-AI-Bot migration) the connection pool is
# exhausted and ALL new TLS handshakes (API, admin UI, monitoring probes)
# start failing with no worker available.
#
# Idempotent:
#  - Only bumps `worker_connections` when current value is < 8192.
#  - Only inserts `worker_rlimit_nofile 65535;` if no line for that
#    directive exists.
# A noop on hosts that already meet the threshold.
NGINX_MAIN_CONF="/etc/nginx/nginx.conf"
if [ -f "$NGINX_MAIN_CONF" ]; then
    if grep -qE '^[[:space:]]*worker_connections[[:space:]]+[0-9]+;' "$NGINX_MAIN_CONF"; then
        current_wc="$(grep -E '^[[:space:]]*worker_connections[[:space:]]+[0-9]+;' "$NGINX_MAIN_CONF" \
            | head -1 | grep -oE '[0-9]+' | head -1)"
        if [ -n "$current_wc" ] && [ "$current_wc" -lt 8192 ]; then
            sed -i 's/worker_connections[[:space:]]\+[0-9]\+;/worker_connections 16384;/' "$NGINX_MAIN_CONF"
            log "Bumped nginx worker_connections: ${current_wc} -> 16384"
        fi
    fi
    if ! grep -qE '^[[:space:]]*worker_rlimit_nofile\b' "$NGINX_MAIN_CONF"; then
        # Insert right after the worker_processes directive so it sits at
        # the top of the main context (the only valid location).
        sed -i '/^worker_processes/a worker_rlimit_nofile 65535;' "$NGINX_MAIN_CONF"
        log "Added worker_rlimit_nofile 65535 to nginx.conf"
    fi
fi

# Test Nginx configuration
log "Testing Nginx configuration..."
if nginx -t; then
    log "Nginx configuration is valid"
    systemctl reload nginx || systemctl restart nginx
    log "Nginx reloaded successfully"
else
    error "Nginx configuration test failed"
fi

log "Nginx setup completed successfully"

