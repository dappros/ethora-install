#!/bin/bash

# SSL Certificate Management Script
# Handles SSL certificate setup via Certbot or provided certificates

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

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

warn() {
    echo "[WARN] $1"
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

# Optional: refresh playground domain from deploy.yml (useful for upgrades)
CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"
if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    if [ -z "${PLAYGROUND_DOMAIN:-}" ] || [ "${PLAYGROUND_DOMAIN:-}" == "null" ]; then
        PLAYGROUND_DOMAIN="$(yq eval '.domains.playground // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${WIDGET_DOMAIN:-}" ] || [ "${WIDGET_DOMAIN:-}" == "null" ]; then
        WIDGET_DOMAIN="$(yq eval '.domains.widget // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    # Hosted MCP server (optional): only requests a cert when enabled.
    mcp_enabled_raw="$(yq eval '.services.mcp.enabled' "$CONFIG_FILE" 2>/dev/null)"
    if [ "$mcp_enabled_raw" = "true" ] || [ "$mcp_enabled_raw" = "false" ]; then
        MCP_ENABLED="$mcp_enabled_raw"
    else
        MCP_ENABLED="${MCP_ENABLED:-false}"
    fi
    if [ -z "${MCP_DOMAIN:-}" ] || [ "${MCP_DOMAIN:-}" == "null" ]; then
        MCP_DOMAIN="$(yq eval '.domains.mcp // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ "${MCP_ENABLED:-false}" == "true" ] && \
       { [ -z "${MCP_DOMAIN:-}" ] || [ "${MCP_DOMAIN:-}" == "null" ]; } && \
       [ -n "${WEB_DOMAIN:-}" ] && [ "$WEB_DOMAIN" != "localhost" ] && [[ "$WEB_DOMAIN" == *.* ]]; then
        MCP_DOMAIN="mcp.$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')"
    fi
    if [ "${MCP_ENABLED:-false}" != "true" ]; then
        MCP_DOMAIN=""
    fi
    if [ -z "${SECURE_FILES_DOMAIN:-}" ] || [ "${SECURE_FILES_DOMAIN:-}" == "null" ]; then
        SECURE_FILES_DOMAIN="$(yq eval '.domains.secure_files // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${HOSTED_APPS_ROOT_DOMAIN:-}" ] || [ "${HOSTED_APPS_ROOT_DOMAIN:-}" == "null" ]; then
        HOSTED_APPS_ROOT_DOMAIN="$(yq eval '.domains.hosted_apps_root // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${HOSTED_APPS_ENABLED:-}" ] || [ "${HOSTED_APPS_ENABLED:-}" == "null" ]; then
        HOSTED_APPS_ENABLED="$(yq eval '.services.hosted_apps.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    fi
    if [ -z "${UPTIME_DOMAIN:-}" ] || [ "${UPTIME_DOMAIN:-}" == "null" ]; then
        UPTIME_DOMAIN="$(yq eval '.domains.uptime // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    LEGACY_DOMAINS_ENABLED="$(yq eval '.legacy_domains.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    LEGACY_WEB_DOMAIN="$(yq eval '.legacy_domains.web // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    LEGACY_FILES_DOMAIN="$(yq eval '.legacy_domains.files // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
fi

# Get SSL method from config
SSL_METHOD=${SSL_METHOD:-certbot}
SSL_EMAIL=${SSL_EMAIL:-admin@example.com}
HOSTED_APPS_CERT_PATH=""
HOSTED_APPS_KEY_PATH=""
CLOUDFLARE_API_TOKEN=""

if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    HOSTED_APPS_CERT_PATH="$(yq eval '.ssl.hosted_apps_cert_path // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    HOSTED_APPS_KEY_PATH="$(yq eval '.ssl.hosted_apps_key_path // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    # Optional Cloudflare API token. When set, the apex + wildcard cert for the
    # hosted-apps root is auto-provisioned over DNS-01 (HTTP-01/nginx cannot
    # validate a wildcard), with unattended renewal via the certbot timer.
    CLOUDFLARE_API_TOKEN="$(yq eval '.ssl.cloudflare_api_token // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
fi

# Skip SSL setup if method is 'none' or domain is localhost
if [ "$SSL_METHOD" == "none" ] || [ "$API_DOMAIN" == "localhost" ]; then
    log "Skipping SSL setup (localhost mode or SSL disabled)"
    exit 0
fi

log "Setting up SSL certificates (method: $SSL_METHOD)..."

copy_cert_for_domain() {
    local cert_path="$1"
    local key_path="$2"
    local domain="$3"

    if [ -z "$domain" ] || [ "$domain" == "null" ]; then
        return 0
    fi

    local cert_dir="/etc/letsencrypt/live/$domain"
    mkdir -p "$cert_dir"
    cp "$cert_path" "$cert_dir/fullchain.pem"
    cp "$key_path" "$cert_dir/privkey.pem"
    log "Copied provided certificates for $domain"
}

cert_matches_domain() {
    local domain="$1"
    local cert_file="$2"

    if [ -z "$domain" ] || [ -z "$cert_file" ] || [ ! -f "$cert_file" ]; then
        return 1
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        return 0
    fi

    openssl x509 -in "$cert_file" -noout -checkhost "$domain" >/dev/null 2>&1
}

copy_main_provided_certs() {
    local cert_path="$1"
    local key_path="$2"
    local domains=("$API_DOMAIN" "$WEB_DOMAIN" "$FILES_DOMAIN" "$SECURE_FILES_DOMAIN" "$XMPP_DOMAIN" "$PLAYGROUND_DOMAIN" "$WIDGET_DOMAIN" "$MCP_DOMAIN" "$UPTIME_DOMAIN")
    local domain=""

    if [ "${LEGACY_DOMAINS_ENABLED:-false}" == "true" ]; then
        domains+=("${LEGACY_WEB_DOMAIN:-}" "${LEGACY_FILES_DOMAIN:-}")
    fi

    for domain in "${domains[@]}"; do
        copy_cert_for_domain "$cert_path" "$key_path" "$domain"
    done
}

# Provision the apex + wildcard cert (<root> and *.<root>) for hosted tenant
# apps over the Cloudflare DNS-01 challenge. A wildcard cannot be validated via
# HTTP-01/nginx (there is no single host to answer for *.<root>), so DNS-01 is
# required. Persisting authenticator = dns-cloudflare into the renewal config
# means the certbot timer renews it unattended - no more 'manual' certs that
# silently expire. Idempotent: --keep-until-expiring only renews when due.
provision_wildcard_via_cloudflare() {
    local root="$HOSTED_APPS_ROOT_DOMAIN"
    local creds="/etc/letsencrypt/cloudflare.ini"

    if ! command -v certbot >/dev/null 2>&1; then
        warn "certbot not found; cannot provision wildcard via Cloudflare DNS-01"
        return 1
    fi

    if ! certbot plugins 2>/dev/null | grep -qi 'dns-cloudflare'; then
        log "Installing certbot dns-cloudflare plugin..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-dns-cloudflare >/dev/null 2>&1 \
            || { warn "Failed to install python3-certbot-dns-cloudflare; install it manually"; return 1; }
    fi

    # Write the Cloudflare API token credentials, kept private (mode 600).
    ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" > "$creds" )
    chmod 600 "$creds"

    if certbot certonly --dns-cloudflare \
        --dns-cloudflare-credentials "$creds" \
        --dns-cloudflare-propagation-seconds 30 \
        --cert-name "$root" \
        -d "$root" -d "*.$root" \
        --non-interactive --agree-tos --email "$SSL_EMAIL" --keep-until-expiring; then
        log "Provisioned apex + wildcard certificate for *.$root via Cloudflare DNS-01"
        return 0
    fi

    warn "Cloudflare DNS-01 wildcard issuance failed for *.$root"
    return 1
}

copy_hosted_apps_cert_if_configured() {
    if [ "${HOSTED_APPS_ENABLED:-false}" != "true" ] || [ -z "${HOSTED_APPS_ROOT_DOMAIN:-}" ] || [ "${HOSTED_APPS_ROOT_DOMAIN:-}" == "null" ]; then
        return 0
    fi

    # Preferred path: auto-provision the apex + wildcard over Cloudflare DNS-01
    # when a token is configured. Writes into /etc/letsencrypt/live/<root>/,
    # which is where ssl.hosted_apps_cert_path/key_path point.
    if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
        if provision_wildcard_via_cloudflare; then
            return 0
        fi
        warn "Falling back to provided/manual wildcard handling for ${HOSTED_APPS_ROOT_DOMAIN}"
    fi

    if [ -n "${HOSTED_APPS_CERT_PATH:-}" ] || [ -n "${HOSTED_APPS_KEY_PATH:-}" ]; then
        if [ -z "${HOSTED_APPS_CERT_PATH:-}" ] || [ -z "${HOSTED_APPS_KEY_PATH:-}" ]; then
            error "Hosted apps wildcard SSL requires both ssl.hosted_apps_cert_path and ssl.hosted_apps_key_path"
        fi
        if [ ! -f "$HOSTED_APPS_CERT_PATH" ] || [ ! -f "$HOSTED_APPS_KEY_PATH" ]; then
            error "Hosted apps certificate files not found: $HOSTED_APPS_CERT_PATH or $HOSTED_APPS_KEY_PATH"
        fi
        copy_cert_for_domain "$HOSTED_APPS_CERT_PATH" "$HOSTED_APPS_KEY_PATH" "$HOSTED_APPS_ROOT_DOMAIN"
        return 0
    fi

    if [ "$SSL_METHOD" = "certbot" ]; then
        warn "Hosted apps enabled without dedicated wildcard cert paths. Nginx may fail if *.${HOSTED_APPS_ROOT_DOMAIN} is expected."
    fi
}

# Switch certbot renewal to the nginx authenticator.
#
# Initial issuance above uses --standalone (nginx is stopped during install, and
# is configured/started only later by setup-nginx.sh). But --standalone is also
# persisted into each renewal config, so the unattended certbot.timer renew later
# runs standalone *while nginx holds port 80* and fails silently every time -
# certs then expire at the 90-day mark. Flipping the persisted authenticator to
# nginx lets renewals succeed with nginx up (zero downtime). This is idempotent
# and repairs already-installed hosts on the next deploy. We only touch certs
# currently on 'standalone' - 'manual' (DNS/wildcard) certs are left alone.
configure_nginx_renewal() {
    local conf
    local switched=0
    for conf in /etc/letsencrypt/renewal/*.conf; do
        [ -f "$conf" ] || continue
        if grep -q '^authenticator = standalone' "$conf"; then
            sed -i 's/^authenticator = standalone/authenticator = nginx/' "$conf"
            log "Renewal authenticator -> nginx for $(basename "$conf" .conf)"
            switched=$((switched + 1))
        fi
    done
    [ "$switched" -gt 0 ] && log "Switched $switched certificate(s) to nginx renewal."
    return 0
}

# Install a global deploy hook run by `certbot renew` after any successful
# renewal. With the nginx authenticator there is no installer, so nginx must be
# told to reload to pick up the new cert; and ejabberd reads a combined
# fullchain+privkey PEM that it does not watch, so when the XMPP cert renews we
# rebuild that PEM and reload ejabberd. $RENEWED_LINEAGE is set by certbot to
# /etc/letsencrypt/live/<domain> for the cert that was just renewed.
install_renewal_deploy_hook() {
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook="$hook_dir/ethora-reload.sh"
    local ejabberd_cert="$ROOT_DIR/ejabberd-docker/docker/sitecert.pem"
    mkdir -p "$hook_dir"
    cat > "$hook" <<HOOK
#!/bin/sh
# Installed by ethora deploy/scripts/setup-ssl.sh. Do not edit by hand.
# Runs once per renewed certificate after a successful certbot renewal.

# nginx has no certbot installer here, so reload it to serve the new cert.
systemctl reload nginx 2>/dev/null || true

# Rebuild + reload the ejabberd cert only when the XMPP lineage renewed.
XMPP_DOMAIN="$XMPP_DOMAIN"
EJABBERD_CERT="$ejabberd_cert"
if [ -n "\$RENEWED_LINEAGE" ] && [ "\$(basename "\$RENEWED_LINEAGE")" = "\$XMPP_DOMAIN" ] && [ -n "\$EJABBERD_CERT" ]; then
    cat "\$RENEWED_LINEAGE/fullchain.pem" "\$RENEWED_LINEAGE/privkey.pem" > "\$EJABBERD_CERT"
    chmod 644 "\$EJABBERD_CERT"
    cid=\$(docker ps --filter name=xmpp --format '{{.Names}}' 2>/dev/null | head -1)
    [ -n "\$cid" ] && docker exec "\$cid" ejabberdctl reload_config 2>/dev/null || true
fi
HOOK
    chmod +x "$hook"
    log "Installed certbot renewal deploy hook: $hook"
}

if [ "$SSL_METHOD" == "certbot" ]; then
    log "Using Certbot to obtain Let's Encrypt certificates..."
    if [ "${HOSTED_APPS_ENABLED:-false}" == "true" ] && [ -n "${HOSTED_APPS_ROOT_DOMAIN:-}" ] && [ "${HOSTED_APPS_ROOT_DOMAIN:-}" != "null" ]; then
        warn "Hosted app wildcard HTTPS is enabled, but certbot standalone does not provision wildcard certificates in this script."
        warn "Use ssl.hosted_apps_cert_path + ssl.hosted_apps_key_path with a wildcard certificate for *.${HOSTED_APPS_ROOT_DOMAIN}."
    fi
    
    # Stop Nginx temporarily for standalone mode.
    # Certbot needs port 80, but a failed issuance must NEVER leave the site down:
    # every exit path below (including `exit 1` on failure) has to bring nginx back.
    NGINX_WAS_ACTIVE="$(systemctl is-active nginx 2>/dev/null || true)"
    restore_nginx_if_stopped() {
        [ "${NGINX_WAS_ACTIVE:-}" = "active" ] || return 0
        [ "$(systemctl is-active nginx 2>/dev/null || true)" = "active" ] && return 0
        warn "Restarting nginx (it was running before certbot took port 80)."
        systemctl start nginx 2>/dev/null \
            || warn "Could not restart nginx - run: sudo nginx -t && sudo systemctl start nginx"
    }
    trap restore_nginx_if_stopped EXIT
    systemctl stop nginx 2>/dev/null || true
    
    # Domains to get certificates for
    # Production default uses nginx TLS for XMPP on 443 (xmpp.<domain>), so include XMPP_DOMAIN here too.
    DOMAINS=("$API_DOMAIN" "$WEB_DOMAIN" "$FILES_DOMAIN" "$XMPP_DOMAIN")
    if [ -n "${PLAYGROUND_DOMAIN:-}" ] && [ "${PLAYGROUND_DOMAIN:-}" != "null" ]; then
        DOMAINS+=("$PLAYGROUND_DOMAIN")
    fi
    if [ -n "${WIDGET_DOMAIN:-}" ] && [ "${WIDGET_DOMAIN:-}" != "null" ]; then
        DOMAINS+=("$WIDGET_DOMAIN")
    fi
    if [ "${MCP_ENABLED:-false}" == "true" ] && [ -n "${MCP_DOMAIN:-}" ] && [ "${MCP_DOMAIN:-}" != "null" ]; then
        DOMAINS+=("$MCP_DOMAIN")
    fi
    if [ -n "${SECURE_FILES_DOMAIN:-}" ] && [ "${SECURE_FILES_DOMAIN:-}" != "null" ]; then
        DOMAINS+=("$SECURE_FILES_DOMAIN")
    fi
    if [ -n "${UPTIME_DOMAIN:-}" ] && [ "${UPTIME_DOMAIN:-}" != "null" ]; then
        DOMAINS+=("$UPTIME_DOMAIN")
    fi
    if [ "${LEGACY_DOMAINS_ENABLED:-false}" == "true" ]; then
        if [ -n "${LEGACY_WEB_DOMAIN:-}" ] && [ "${LEGACY_WEB_DOMAIN:-}" != "null" ]; then
            DOMAINS+=("$LEGACY_WEB_DOMAIN")
        fi
        if [ -n "${LEGACY_FILES_DOMAIN:-}" ] && [ "${LEGACY_FILES_DOMAIN:-}" != "null" ]; then
            DOMAINS+=("$LEGACY_FILES_DOMAIN")
        fi
    fi
    
    # Self-signed stand-in for a cert certbot could not issue. Keeps nginx loadable
    # (see the call site); the PLACEHOLDER file marks it so it is obvious in an audit
    # and so we never mistake it for a real certificate.
    write_placeholder_cert() {
        local domain="$1" dir="/etc/letsencrypt/live/$1"
        [ -f "$dir/fullchain.pem" ] && return 0
        mkdir -p "$dir" || return 0
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
            -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" >/dev/null 2>&1 || return 0
        cp "$dir/fullchain.pem" "$dir/chain.pem" 2>/dev/null || true
        cp "$dir/fullchain.pem" "$dir/cert.pem" 2>/dev/null || true
        printf 'PLACEHOLDER self-signed certificate for %s, written by setup-ssl.sh because\ncertbot could not issue a real one (DNS/CAA/port 80). Browsers will reject it.\nFix the cause, then re-run: sudo %s/setup-ssl.sh\n' \
            "$domain" "$SCRIPT_DIR" > "$dir/PLACEHOLDER-SELF-SIGNED.txt" 2>/dev/null || true
        warn "Wrote a self-signed PLACEHOLDER cert for $domain so nginx can still start. HTTPS for $domain will NOT be trusted until a real cert is issued."
    }

    failed_count=0
    for domain in "${DOMAINS[@]}"; do
        if [ -z "$domain" ] || [ "$domain" == "null" ]; then
            continue
        fi
        
        log "Obtaining certificate for $domain..."
        
        # Check if certificate already exists
        if [ -d "/etc/letsencrypt/live/$domain" ]; then
            cert_file="/etc/letsencrypt/live/$domain/fullchain.pem"
            if [ -f "/etc/letsencrypt/live/$domain/PLACEHOLDER-SELF-SIGNED.txt" ]; then
                # A placeholder we wrote on an earlier failed run carries the right
                # CN, so the hostname check below would "skip" it forever. Always
                # retry a real issuance, and clear the directory first - certbot
                # will not write a lineage over a live dir it does not manage.
                warn "Existing certificate for $domain is a self-signed placeholder; requesting a real certificate"
                rm -rf "/etc/letsencrypt/live/$domain"
            elif cert_matches_domain "$domain" "$cert_file"; then
                log "Certificate for $domain already exists, skipping..."
                continue
            else
                warn "Existing certificate for $domain does not match the hostname; requesting a fresh certificate"
            fi
        fi

        # Obtain certificate
        certbot certonly \
            --standalone \
            --non-interactive \
            --agree-tos \
            --email "$SSL_EMAIL" \
            --cert-name "$domain" \
            --force-renewal \
            -d "$domain" || {
            warn "Failed to obtain certificate for $domain"
            failed_count=$((failed_count + 1))
            # nginx refuses to load its ENTIRE config if one ssl_certificate file is
            # missing, so a single un-issuable subdomain (new domain, missing DNS,
            # broken DNSSEC/CAA) would take the whole install offline. Drop in a
            # self-signed placeholder so nginx still loads; the next successful run
            # replaces it (see the placeholder branch above).
            write_placeholder_cert "$domain"
        }
    done

    if [ "${failed_count:-0}" -gt 0 ]; then
        echo "[ERROR] Failed to obtain ${failed_count} certificate(s) via certbot standalone." >&2
        echo "[ERROR] Most common causes: DNS not pointing to this server, or inbound port 80 blocked by firewall/security group." >&2
        echo "[ERROR] Fix DNS + open port 80, then re-run: sudo $SCRIPT_DIR/setup-ssl.sh" >&2
        exit 1
    fi
    
    # Start Nginx again
    systemctl start nginx 2>/dev/null || true
    
    # Setup auto-renewal
    log "Setting up certificate auto-renewal..."
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true

    # Make unattended renewal actually work with nginx up (see fn comments).
    configure_nginx_renewal
    install_renewal_deploy_hook

    copy_hosted_apps_cert_if_configured
    
elif [ "$SSL_METHOD" == "provided" ]; then
    log "Using provided SSL certificates..."
    
    # Get certificate paths from config
    if command -v yq &> /dev/null; then
        CERT_PATH=$(yq eval '.ssl.cert_path' "$DEPLOY_DIR/config/deploy.yml" 2>/dev/null || echo "")
        KEY_PATH=$(yq eval '.ssl.key_path' "$DEPLOY_DIR/config/deploy.yml" 2>/dev/null || echo "")
    else
        error "yq is required for provided certificate method"
    fi
    
    if [ -z "$CERT_PATH" ] || [ -z "$KEY_PATH" ]; then
        error "Certificate paths not specified in config. Set ssl.cert_path and ssl.key_path in deploy.yml"
    fi
    
    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
        error "Certificate files not found: $CERT_PATH or $KEY_PATH"
    fi
    
    copy_main_provided_certs "$CERT_PATH" "$KEY_PATH"

    if [ "${HOSTED_APPS_ENABLED:-false}" == "true" ] && [ -n "${HOSTED_APPS_ROOT_DOMAIN:-}" ] && [ "${HOSTED_APPS_ROOT_DOMAIN:-}" != "null" ]; then
        if [ -n "${HOSTED_APPS_CERT_PATH:-}" ] || [ -n "${HOSTED_APPS_KEY_PATH:-}" ]; then
            copy_hosted_apps_cert_if_configured
        else
            copy_cert_for_domain "$CERT_PATH" "$KEY_PATH" "$HOSTED_APPS_ROOT_DOMAIN"
        fi
    fi
else
    error "Invalid SSL method: $SSL_METHOD. Use 'certbot' or 'provided'"
fi

# Setup Ejabberd certificate (skip for localhost)
if [ "$XMPP_DOMAIN" != "localhost" ]; then
    log "Setting up Ejabberd SSL certificate..."
    
    XMPP_CERT_DIR="/etc/letsencrypt/live/$XMPP_DOMAIN"
    EJABBERD_CERT="$ROOT_DIR/ejabberd-docker/docker/sitecert.pem"
    
    if [ -d "$XMPP_CERT_DIR" ]; then
        # Combine certificate and key for Ejabberd
        cat "$XMPP_CERT_DIR/fullchain.pem" "$XMPP_CERT_DIR/privkey.pem" > "$EJABBERD_CERT"
        chmod 644 "$EJABBERD_CERT"
        log "Created Ejabberd certificate: $EJABBERD_CERT"
    else
        warn "XMPP certificate not found. Ejabberd may need manual certificate setup."
    fi
else
    log "Skipping Ejabberd SSL certificate setup (localhost mode - using default certificate)"
fi

log "SSL certificate setup completed"

