#!/bin/bash

# Environment File Generation Script
# Generates all .env files from templates based on deployment configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Repo root (monoserver root). Note: ENV_FILE may override ROOT_DIR to the *install base*.
REPO_ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
ROOT_DIR="$REPO_ROOT_DIR"

# Refresh domain/base app values in .deploy.env if deploy.yml changed.
REFRESH_SCRIPT="$DEPLOY_DIR/scripts/refresh-deploy-env.sh"
if [ -f "$REFRESH_SCRIPT" ]; then
    bash "$REFRESH_SCRIPT" || true
fi

# Source environment variables from install.sh
ENV_FILE="$DEPLOY_DIR/.deploy.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    error "Environment file not found: $ENV_FILE. Please run install.sh first."
fi

if [ -z "$API_DOMAIN" ]; then
    error "Environment variables not set. Please run install.sh first."
fi

# Build/version info: derive once from `git log -1` on the deploy source repo.
# These are surfaced to the frontend (VITE_BUILD_*) and backend (ETHORA_BUILD_*) so
# the auth-screen footer can show "frontend yy.mm.dd (branch @ shortSha)" etc.
# We try a few candidate source roots in order: SOURCE_ROOT (set by update.sh /
# install.sh), the repo root we computed above, then the deploy dir parent.
detect_build_info() {
    local candidate=""
    for cand in "${SOURCE_ROOT:-}" "$REPO_ROOT_DIR" "$DEPLOY_DIR/.."; do
        [ -z "$cand" ] && continue
        if git -C "$cand" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            candidate="$cand"
            break
        fi
    done

    if [ -n "$candidate" ]; then
        BUILD_VERSION="$(git -C "$candidate" log -1 --format=%cd --date=format:%y.%m.%d 2>/dev/null || echo '')"
        BUILD_BRANCH="$(git -C "$candidate" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
        BUILD_COMMIT="$(git -C "$candidate" rev-parse --short=7 HEAD 2>/dev/null || echo '')"
        BUILD_TIME="$(git -C "$candidate" log -1 --format=%cI 2>/dev/null || echo '')"
    fi

    # Fallbacks so .env files always have a non-empty value (avoids weird "undefined"
    # rendering in the footer on hand-installed boxes that may not be a git checkout).
    : "${BUILD_VERSION:=$(date -u +%y.%m.%d)}"
    : "${BUILD_BRANCH:=unknown}"
    : "${BUILD_COMMIT:=unknown}"
    : "${BUILD_TIME:=$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

    export BUILD_VERSION BUILD_BRANCH BUILD_COMMIT BUILD_TIME
}
detect_build_info

# Persist a key/value back into .deploy.env (so subsequent scripts sourcing it
# see the updated value).
persist_env_var() {
    local key="$1"
    local value="$2"
    if [ -z "$key" ]; then
        return 0
    fi
    local escaped="${value//\"/\\\"}"
    local tmp
    tmp="$(mktemp 2>/dev/null || echo "$DEPLOY_DIR/.deploy.env.tmp.$$")"

    # Preserve existing file contents (and comments), but replace any existing assignment.
    # Support both: KEY=... and export KEY=...
    if [ -f "$ENV_FILE" ]; then
        grep -v -E "^(export[[:space:]]+)?${key}=" "$ENV_FILE" >"$tmp" 2>/dev/null || true
    fi
    echo "export ${key}=\"${escaped}\"" >>"$tmp"

    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    if [ -n "${SUDO_USER:-}" ] && [ "${EUID:-$(id -u)}" -eq 0 ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        chown "$SUDO_USER":"$SUDO_USER" "$ENV_FILE" 2>/dev/null || chown "$SUDO_USER" "$ENV_FILE" 2>/dev/null || true
    fi
}

# npm 11.13+ (the version bundled with Node 24) refuses to run dependency
# install/postinstall scripts unless each package is explicitly approved, and it
# only *warns* when it skips them -- so a build silently loses e.g. sharp's
# native-module fallback (services/api/scripts/postinstall-sharp.js) instead of
# failing loudly. Persist the opt-out so every npm invocation the deploy makes --
# including the ones run through `run_as_deploy_user`, which sources this file
# inside a fresh sudo shell that does not inherit our exports -- keeps the
# pre-Node-24 behaviour. Persisted rather than just exported so pre-existing
# installs pick it up via update.sh, which does not regenerate .deploy.env.
if [ -z "${NPM_CONFIG_DANGEROUSLY_ALLOW_ALL_SCRIPTS:-}" ] || [ "${NPM_CONFIG_DANGEROUSLY_ALLOW_ALL_SCRIPTS:-}" == "null" ]; then
    export NPM_CONFIG_DANGEROUSLY_ALLOW_ALL_SCRIPTS="true"
    persist_env_var "NPM_CONFIG_DANGEROUSLY_ALLOW_ALL_SCRIPTS" "true"
fi

# Optional: refresh playground settings from deploy.yml (useful for upgrades)
CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"

# Run modes for the API and the frontend (deploy.yml services.backend.mode /
# services.frontend.mode: source | image). Persisted so every later script
# (setup-node-services.sh, init-services.sh, health-check.sh) sees them
# without re-reading deploy.yml. See docs/CONTAINER_IMAGES.md.
BACKEND_MODE="$(yq eval '.services.backend.mode // "source"' "$CONFIG_FILE" 2>/dev/null || echo "source")"
[ "$BACKEND_MODE" = "null" ] && BACKEND_MODE="source"
ETHORA_API_IMAGE="$(yq eval '.services.backend.image // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
[ "$ETHORA_API_IMAGE" = "null" ] && ETHORA_API_IMAGE=""
FRONTEND_MODE="$(yq eval '.services.frontend.mode // "source"' "$CONFIG_FILE" 2>/dev/null || echo "source")"
[ "$FRONTEND_MODE" = "null" ] && FRONTEND_MODE="source"
ETHORA_FRONTEND_IMAGE="$(yq eval '.services.frontend.image // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
[ "$ETHORA_FRONTEND_IMAGE" = "null" ] && ETHORA_FRONTEND_IMAGE=""
export BACKEND_MODE ETHORA_API_IMAGE FRONTEND_MODE ETHORA_FRONTEND_IMAGE
persist_env_var "BACKEND_MODE" "$BACKEND_MODE"
persist_env_var "ETHORA_API_IMAGE" "$ETHORA_API_IMAGE"
persist_env_var "FRONTEND_MODE" "$FRONTEND_MODE"
persist_env_var "ETHORA_FRONTEND_IMAGE" "$ETHORA_FRONTEND_IMAGE"
# Same for the AI module (ai-service + docs-parse + widget), push, the SDK
# playground and the hosted MCP server.
_read_mode() { local v; v="$(yq eval "$1 // \"$2\"" "$CONFIG_FILE" 2>/dev/null || echo "$2")"; [ "$v" = "null" ] && v="$2"; printf '%s' "$v"; }
AI_MODE="$(_read_mode '.services.ai_service.mode' source)";          ETHORA_AI_IMAGE="$(_read_mode '.services.ai_service.image' "")"
PUSH_MODE="$(_read_mode '.services.push.mode' source)";              ETHORA_PUSH_IMAGE="$(_read_mode '.services.push.image' "")"
PLAYGROUND_MODE="$(_read_mode '.services.playground.mode' source)";  ETHORA_PLAYGROUND_IMAGE="$(_read_mode '.services.playground.image' "")"
MCP_MODE="$(_read_mode '.services.mcp.mode' source)";                ETHORA_MCP_IMAGE="$(_read_mode '.services.mcp.image' "")"
EJABBERD_MODE="$(_read_mode '.services.ejabberd.mode' source)";      ETHORA_XMPP_IMAGE="$(_read_mode '.services.ejabberd.image' "")"
export AI_MODE ETHORA_AI_IMAGE PUSH_MODE ETHORA_PUSH_IMAGE PLAYGROUND_MODE ETHORA_PLAYGROUND_IMAGE MCP_MODE ETHORA_MCP_IMAGE EJABBERD_MODE ETHORA_XMPP_IMAGE
for _k in AI_MODE ETHORA_AI_IMAGE PUSH_MODE ETHORA_PUSH_IMAGE PLAYGROUND_MODE ETHORA_PLAYGROUND_IMAGE MCP_MODE ETHORA_MCP_IMAGE EJABBERD_MODE ETHORA_XMPP_IMAGE; do
    persist_env_var "$_k" "${!_k}"
done
if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    if [ -z "${PLAYGROUND_DOMAIN:-}" ] || [ "${PLAYGROUND_DOMAIN:-}" == "null" ]; then
        PLAYGROUND_DOMAIN="$(yq eval '.domains.playground // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${WIDGET_DOMAIN:-}" ] || [ "${WIDGET_DOMAIN:-}" == "null" ]; then
        WIDGET_DOMAIN="$(yq eval '.domains.widget // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${HOSTED_APPS_ROOT_DOMAIN:-}" ] || [ "${HOSTED_APPS_ROOT_DOMAIN:-}" == "null" ]; then
        HOSTED_APPS_ROOT_DOMAIN="$(yq eval '.domains.hosted_apps_root // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${PLAYGROUND_ENABLED:-}" ] || [ "${PLAYGROUND_ENABLED:-}" == "null" ]; then
        PLAYGROUND_ENABLED="$(yq eval '.services.playground.enabled | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; PLAYGROUND_ENABLED="${PLAYGROUND_ENABLED:-true}"
    fi
    # Always re-read WIDGET_ENABLED from deploy.yml so toggling
    # services.widget.enabled (and the AI umbrella below) takes effect on
    # update. Previously a guard like `if [ -z ]` made the value sticky once
    # persisted to .deploy.env, which is exactly what makes update.sh appear
    # to "disregard" deploy.yml when operators flip widget/AI flags.
    #
    # When services.widget is missing/null (i.e. operator hasn't expressed an
    # opinion either way) we default to the AI feature umbrella. The AI
    # Widget tab in the admin panel needs widget hosting for the embed code
    # to point at a real assistant.js, so AI-on installs effectively need
    # widget hosting on by default. Operators who explicitly set
    # services.widget.enabled (true OR false) keep their explicit value.
    # Read the raw value WITHOUT a `// "false"` alternative — yq's `//`
    # also falls through on explicit false, so we'd lose the operator's
    # intent to disable widget hosting on AI-on installs.
    widget_enabled_raw="$(yq eval '.services.widget.enabled' "$CONFIG_FILE" 2>/dev/null)"
    if [ "$widget_enabled_raw" = "true" ] || [ "$widget_enabled_raw" = "false" ]; then
        WIDGET_ENABLED="$widget_enabled_raw"
    else
        ai_feature_for_widget="$(yq eval '.features.ai_service // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
        WIDGET_ENABLED="$ai_feature_for_widget"
    fi
    if [ -z "${HOSTED_APPS_ENABLED:-}" ] || [ "${HOSTED_APPS_ENABLED:-}" == "null" ]; then
        HOSTED_APPS_ENABLED="$(yq eval '.services.hosted_apps.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    fi
    if [ -z "${WIDGET_SCRIPT_VERSION:-}" ] || [ "${WIDGET_SCRIPT_VERSION:-}" == "null" ]; then
        WIDGET_SCRIPT_VERSION="$(yq eval '.services.widget.script_version // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${PLAYGROUND_PORT:-}" ] || [ "${PLAYGROUND_PORT:-}" == "null" ]; then
        PLAYGROUND_PORT="$(yq eval '.services.playground.port // 3020' "$CONFIG_FILE" 2>/dev/null || echo "3020")"
    fi
    # Hosted MCP server (optional). Always re-read the toggle so flipping
    # services.mcp.enabled in deploy.yml takes effect on update (same reason
    # as WIDGET_ENABLED above). Read raw: yq's `//` falls through on explicit false.
    mcp_enabled_raw="$(yq eval '.services.mcp.enabled' "$CONFIG_FILE" 2>/dev/null)"
    if [ "$mcp_enabled_raw" = "true" ] || [ "$mcp_enabled_raw" = "false" ]; then
        MCP_ENABLED="$mcp_enabled_raw"
    else
        MCP_ENABLED="false"
    fi
    if [ -z "${MCP_DOMAIN:-}" ] || [ "${MCP_DOMAIN:-}" == "null" ]; then
        MCP_DOMAIN="$(yq eval '.domains.mcp // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${MCP_PORT:-}" ] || [ "${MCP_PORT:-}" == "null" ]; then
        MCP_PORT="$(yq eval '.services.mcp.port // 3030' "$CONFIG_FILE" 2>/dev/null || echo "3030")"
    fi
    if [ -z "${MCP_OPENAI_APPS_CHALLENGE:-}" ] || [ "${MCP_OPENAI_APPS_CHALLENGE:-}" == "null" ]; then
        MCP_OPENAI_APPS_CHALLENGE="$(yq eval '.services.mcp.openai_apps_challenge // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
        [ "$MCP_OPENAI_APPS_CHALLENGE" == "null" ] && MCP_OPENAI_APPS_CHALLENGE=""
    fi
    if [ -z "${MCP_OAUTH_ISSUER_OVERRIDE:-}" ] || [ "${MCP_OAUTH_ISSUER_OVERRIDE:-}" == "null" ]; then
        MCP_OAUTH_ISSUER_OVERRIDE="$(yq eval '.services.mcp.oauth_issuer // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
        [ "$MCP_OAUTH_ISSUER_OVERRIDE" = "null" ] && MCP_OAUTH_ISSUER_OVERRIDE=""
    fi
    # Read raw: yq's `//` would turn an explicit false into the default.
    mcp_dangerous_raw="$(yq eval '.services.mcp.enable_dangerous_tools' "$CONFIG_FILE" 2>/dev/null)"
    if [ "$mcp_dangerous_raw" = "false" ]; then
        MCP_ENABLE_DANGEROUS_TOOLS="false"
    else
        MCP_ENABLE_DANGEROUS_TOOLS="true"
    fi
    if [ -z "${PLAYGROUND_APP_ID:-}" ] || [ "${PLAYGROUND_APP_ID:-}" == "null" ]; then
        PLAYGROUND_APP_ID="$(yq eval '.playground.app_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${PLAYGROUND_APP_SECRET:-}" ] || [ "${PLAYGROUND_APP_SECRET:-}" == "null" ]; then
        PLAYGROUND_APP_SECRET="$(yq eval '.playground.app_secret // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi

    # Postmark / analytics (may not be in .deploy.env yet)
    if [ -z "${POSTMARK_ENABLED:-}" ] || [ "${POSTMARK_ENABLED:-}" == "null" ]; then
        POSTMARK_ENABLED="$(yq eval '.features.postmark // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    fi
    if [ -z "${POSTMARK_TOKEN:-}" ] || [ "${POSTMARK_TOKEN:-}" == "null" ]; then
        POSTMARK_TOKEN="$(yq eval '.integrations.postmark.token // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${POSTMARK_FROM_EMAIL:-}" ] || [ "${POSTMARK_FROM_EMAIL:-}" == "null" ]; then
        POSTMARK_FROM_EMAIL="$(yq eval '.integrations.postmark.from_email // "noreply@ethoramail.com"' "$CONFIG_FILE" 2>/dev/null || echo "noreply@ethoramail.com")"
    fi
    if [ -z "${POSTMARK_FROM_NAME:-}" ] || [ "${POSTMARK_FROM_NAME:-}" == "null" ]; then
        POSTMARK_FROM_NAME="$(yq eval '.integrations.postmark.from_name // "Ethora Platform"' "$CONFIG_FILE" 2>/dev/null || echo "Ethora Platform")"
    fi
    if [ -z "${POSTMARK_SUBJECT_PREFIX:-}" ] || [ "${POSTMARK_SUBJECT_PREFIX:-}" == "null" ]; then
        POSTMARK_SUBJECT_PREFIX="$(yq eval '.integrations.postmark.subject_prefix // "Ethora"' "$CONFIG_FILE" 2>/dev/null || echo "Ethora")"
    fi
    if [ -z "${ANALYTICS_ENABLED:-}" ] || [ "${ANALYTICS_ENABLED:-}" == "null" ]; then
        ANALYTICS_ENABLED="$(yq eval '.features.analytics // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    fi
    if [ -z "${DAILY_REPORT_RECEIVERS:-}" ] || [ "${DAILY_REPORT_RECEIVERS:-}" == "null" ]; then
        DAILY_REPORT_RECEIVERS="$(yq eval '.integrations.analytics.daily_report_receivers // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${MONTHLY_REPORT_RECEIVERS:-}" ] || [ "${MONTHLY_REPORT_RECEIVERS:-}" == "null" ]; then
        MONTHLY_REPORT_RECEIVERS="$(yq eval '.integrations.analytics.monthly_report_receivers // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${REPORT_DAILY_SCHEDULE:-}" ] || [ "${REPORT_DAILY_SCHEDULE:-}" == "null" ]; then
        REPORT_DAILY_SCHEDULE="$(yq eval '.integrations.analytics.daily_schedule // "30 8 * * *"' "$CONFIG_FILE" 2>/dev/null || echo "30 8 * * *")"
    fi
    if [ -z "${REPORT_WEEKLY_SCHEDULE:-}" ] || [ "${REPORT_WEEKLY_SCHEDULE:-}" == "null" ]; then
        REPORT_WEEKLY_SCHEDULE="$(yq eval '.integrations.analytics.weekly_schedule // "30 8 * * 1"' "$CONFIG_FILE" 2>/dev/null || echo "30 8 * * 1")"
    fi
    if [ -z "${REPORT_MONTHLY_SCHEDULE:-}" ] || [ "${REPORT_MONTHLY_SCHEDULE:-}" == "null" ]; then
        REPORT_MONTHLY_SCHEDULE="$(yq eval '.integrations.analytics.monthly_schedule // "30 8 1 * *"' "$CONFIG_FILE" 2>/dev/null || echo "30 8 1 * *")"
    fi
    if [ -z "${REPORT_TIMEZONE:-}" ] || [ "${REPORT_TIMEZONE:-}" == "null" ]; then
        REPORT_TIMEZONE="$(yq eval '.integrations.analytics.timezone // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${DEFAULT_ROOMS_INACTIVE_DAYS:-}" ] || [ "${DEFAULT_ROOMS_INACTIVE_DAYS:-}" == "null" ]; then
        DEFAULT_ROOMS_INACTIVE_DAYS="$(yq eval '.features.default_rooms_inactive_days // "0"' "$CONFIG_FILE" 2>/dev/null || echo "0")"
    fi
    if [ -z "${LEGAL_CONTACT_EMAIL:-}" ] || [ "${LEGAL_CONTACT_EMAIL:-}" == "null" ]; then
        LEGAL_CONTACT_EMAIL="$(yq eval '.integrations.analytics.legal_email // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${ALERT_RECIPIENTS:-}" ] || [ "${ALERT_RECIPIENTS:-}" == "null" ]; then
        ALERT_RECIPIENTS="$(yq eval '.integrations.analytics.alert_email // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi

    # Feedback channel (POST /v2/feedback). Both destinations are optional: with
    # neither set the backend stores submissions and sends nothing.
    if [ -z "${FEEDBACK_EMAIL_TO:-}" ] || [ "${FEEDBACK_EMAIL_TO:-}" == "null" ]; then
        FEEDBACK_EMAIL_TO="$(yq eval '.feedback.email_to // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${FEEDBACK_SLACK_WEBHOOK_URL:-}" ] || [ "${FEEDBACK_SLACK_WEBHOOK_URL:-}" == "null" ]; then
        FEEDBACK_SLACK_WEBHOOK_URL="$(yq eval '.feedback.slack_webhook_url // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    # Read raw: `retention_days: 0` is meaningful (keep forever) and yq's `//`
    # would swallow it the same way it swallows an explicit `false`.
    if [ -z "${FEEDBACK_RETENTION_DAYS:-}" ] || [ "${FEEDBACK_RETENTION_DAYS:-}" == "null" ]; then
        feedback_retention_raw="$(yq eval '.feedback.retention_days' "$CONFIG_FILE" 2>/dev/null || echo "")"
        if [[ "$feedback_retention_raw" =~ ^[0-9]+$ ]]; then
            FEEDBACK_RETENTION_DAYS="$feedback_retention_raw"
        else
            FEEDBACK_RETENTION_DAYS="180"
        fi
    fi
    # Email delivery rides on Postmark; warn rather than fail, so a misconfigured
    # destination never blocks a deploy - it just silently sends nothing.
    if [ -n "${FEEDBACK_EMAIL_TO}" ] && [ "${POSTMARK_ENABLED:-false}" != "true" ]; then
        warn "feedback.email_to is set but features.postmark is false; feedback email delivery will be skipped (submissions are still stored)."
    fi

    # HubSpot (CRM/Slack notifications via Forms API). Mirrors install/update reads so the
    # values are present even when setup-env.sh is invoked outside of update.sh.
    if [ -z "${HUBSPOT_ENABLED:-}" ] || [ "${HUBSPOT_ENABLED:-}" == "null" ]; then
        HUBSPOT_ENABLED="$(yq eval '.integrations.hubspot.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    fi
    if [ -z "${HUBSPOT_PORTAL_ID:-}" ] || [ "${HUBSPOT_PORTAL_ID:-}" == "null" ]; then
        HUBSPOT_PORTAL_ID="$(yq eval '.integrations.hubspot.portal_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${HUBSPOT_FORM_ID_APP_CREATE:-}" ] || [ "${HUBSPOT_FORM_ID_APP_CREATE:-}" == "null" ]; then
        HUBSPOT_FORM_ID_APP_CREATE="$(yq eval '.integrations.hubspot.form_id_app_create // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${HUBSPOT_FORM_ID_SIGNUP:-}" ] || [ "${HUBSPOT_FORM_ID_SIGNUP:-}" == "null" ]; then
        HUBSPOT_FORM_ID_SIGNUP="$(yq eval '.integrations.hubspot.form_id_signup // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${HUBSPOT_FORM_ID_TUTORIAL:-}" ] || [ "${HUBSPOT_FORM_ID_TUTORIAL:-}" == "null" ]; then
        HUBSPOT_FORM_ID_TUTORIAL="$(yq eval '.integrations.hubspot.form_id_tutorial // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
    if [ -z "${HUBSPOT_REGION:-}" ] || [ "${HUBSPOT_REGION:-}" == "null" ]; then
        HUBSPOT_REGION="$(yq eval '.integrations.hubspot.region // "na1"' "$CONFIG_FILE" 2>/dev/null || echo "na1")"
    fi

    # Immutable audit logs (tamper-evident log export to S3).
    #
    # Always re-read from deploy.yml (no `[ -z ]` guard) so flipping
    # features.immutable_logs off actually clears the credentials on the next
    # update instead of leaving them sticky in .deploy.env. When the flag is
    # off every value is forced empty, which is what keeps a flag-off install
    # from ever reaching S3.
    IMMUTABLE_LOGS_ENABLED="$(yq eval '.features.immutable_logs // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    if [ "${IMMUTABLE_LOGS_ENABLED}" = "true" ]; then
        IMMUTABLE_LOGS_INTERVAL_HOURS="$(yq eval '.integrations.immutable_logs.interval_hours // 6' "$CONFIG_FILE" 2>/dev/null || echo "6")"
        IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID="$(yq eval '.integrations.immutable_logs.aws_access_key_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
        IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY="$(yq eval '.integrations.immutable_logs.aws_secret_access_key // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
        IMMUTABLE_LOGS_AWS_REGION="$(yq eval '.integrations.immutable_logs.aws_region // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
        IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME="$(yq eval '.integrations.immutable_logs.aws_s3_bucket_name // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
        [ "${IMMUTABLE_LOGS_INTERVAL_HOURS}" = "null" ] && IMMUTABLE_LOGS_INTERVAL_HOURS="6"
    else
        IMMUTABLE_LOGS_ENABLED="false"
        IMMUTABLE_LOGS_INTERVAL_HOURS=""
        IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID=""
        IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY=""
        IMMUTABLE_LOGS_AWS_REGION=""
        IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME=""
    fi
    export IMMUTABLE_LOGS_ENABLED IMMUTABLE_LOGS_INTERVAL_HOURS \
           IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY \
           IMMUTABLE_LOGS_AWS_REGION IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME

    # License (deploy.yml `license:`, see docs/LICENSING.md). Always re-read
    # so removing the key from deploy.yml removes it from the env on the next
    # update. `key_file` wins over `key` when both are set. Whitespace inside
    # the key is stripped (keys get pasted from emails with line breaks).
    ETHORA_LICENSE_KEY="$(yq eval '.license.key // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    [ "${ETHORA_LICENSE_KEY}" = "null" ] && ETHORA_LICENSE_KEY=""
    _license_key_file="$(yq eval '.license.key_file // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    [ "${_license_key_file}" = "null" ] && _license_key_file=""
    if [ -n "${_license_key_file}" ]; then
        if [ -f "${_license_key_file}" ]; then
            ETHORA_LICENSE_KEY="$(tr -d '[:space:]' < "${_license_key_file}")"
        else
            warn "license.key_file is set to '${_license_key_file}' but the file does not exist; continuing without a license key."
        fi
    fi
    ETHORA_LICENSE_KEY="$(printf '%s' "${ETHORA_LICENSE_KEY}" | tr -d '[:space:]')"
    ETHORA_LICENSE_CALL_HOME="$(yq eval '.license.call_home | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; ETHORA_LICENSE_CALL_HOME="${ETHORA_LICENSE_CALL_HOME:-true}"
    [ "${ETHORA_LICENSE_CALL_HOME}" = "null" ] && ETHORA_LICENSE_CALL_HOME="true"
    ETHORA_LICENSE_SERVER_URL="$(yq eval '.license.server_url // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    [ "${ETHORA_LICENSE_SERVER_URL}" = "null" ] && ETHORA_LICENSE_SERVER_URL=""
    ETHORA_LICENSE_GRACE_DAYS="$(yq eval '.license.grace_days // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    [ "${ETHORA_LICENSE_GRACE_DAYS}" = "null" ] && ETHORA_LICENSE_GRACE_DAYS=""
    export ETHORA_LICENSE_KEY ETHORA_LICENSE_CALL_HOME ETHORA_LICENSE_SERVER_URL ETHORA_LICENSE_GRACE_DAYS

    # Email TLD validation policy.
    # Default to "off" - safer for self-hosted/enterprise installs that ingest
    # real-world user lists with uncommon TLDs (e.g. .health, .son, .example).
    if [ -z "${EMAIL_TLD_VALIDATION:-}" ] || [ "${EMAIL_TLD_VALIDATION:-}" == "null" ]; then
        EMAIL_TLD_VALIDATION="$(yq eval '.services.backend.email_tld_validation // "off"' "$CONFIG_FILE" 2>/dev/null || echo "off")"
    fi
    if [ -z "${EMAIL_TLD_ALLOWLIST:-}" ] || [ "${EMAIL_TLD_ALLOWLIST:-}" == "null" ]; then
        EMAIL_TLD_ALLOWLIST="$(yq eval '.services.backend.email_tld_allowlist // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    fi
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

# Simple template replacement function
replace_template() {
    local template_file="$1"
    local output_file="$2"
    local output_dir=""
    
    if [ ! -f "$template_file" ]; then
        error "Template file not found: $template_file"
    fi

    output_dir="$(dirname "$output_file")"
    if [ ! -d "$output_dir" ]; then
        mkdir -p "$output_dir" 2>/dev/null || {
            if [ -n "${SUDO_USER:-}" ] && [ "${EUID:-$(id -u)}" -eq 0 ]; then
                mkdir -p "$output_dir" || error "Failed to create output directory: $output_dir"
            else
                error "Output directory is missing or not writable: $output_dir"
            fi
        }
    fi
    if [ -n "${SUDO_USER:-}" ] && [ "${EUID:-$(id -u)}" -eq 0 ] && id "$SUDO_USER" >/dev/null 2>&1; then
        chown "$SUDO_USER":"$SUDO_USER" "$output_dir" 2>/dev/null || chown "$SUDO_USER" "$output_dir" 2>/dev/null || true
        [ -e "$output_file" ] && (chown "$SUDO_USER":"$SUDO_USER" "$output_file" 2>/dev/null || chown "$SUDO_USER" "$output_file" 2>/dev/null || true)
    fi
    
    # Read template and replace variables
    local content
    content="$(cat "$template_file")"

    # Safe literal replacement (avoids sed escaping issues with random secrets).
    # Usage: replace_literal "SEARCH" "REPLACE"
    replace_literal() {
        local search="$1"
        local replace="$2"
        content="${content//${search}/${replace}}"
    }
    
    # Detect localhost mode
    local is_localhost=false
    if [ "$API_DOMAIN" == "localhost" ]; then
        is_localhost=true
    fi
    
    # Replace all {{VAR}} with $VAR values
    replace_literal "{{NODE_ENV}}" "${NODE_ENV:-production}"
    replace_literal "{{IS_LOCALHOST}}" "${is_localhost}"
    replace_literal "{{BACKEND_PORT}}" "${BACKEND_PORT}"
    replace_literal "{{JWT_SECRET}}" "${JWT_SECRET}"
    replace_literal "{{REFRESH_SECRET}}" "${REFRESH_SECRET}"
    # XMPP SASL JWT secret (shared with ejabberd's jwt_key). Generate + persist if
    # missing so updates and pre-existing installs get a stable value.
    if [ -z "${XMPP_JWT_SECRET:-}" ] || [ "${XMPP_JWT_SECRET:-}" == "null" ]; then
        export XMPP_JWT_SECRET="$(openssl rand -base64 64 | tr -d '\n')"
        persist_env_var "XMPP_JWT_SECRET" "$XMPP_JWT_SECRET"
    fi
    replace_literal "{{XMPP_JWT_SECRET}}" "${XMPP_JWT_SECRET}"
    replace_literal "{{CRYPTOPAIR_SECRET}}" "${CRYPTOPAIR_SECRET:-}"
    replace_literal "{{SECRET_FOR_DB_ENCRYPTION}}" "${SECRET_FOR_DB_ENCRYPTION:-}"
    replace_literal "{{SECRET_FOR_FILES_ENCRYPTION}}" "${SECRET_FOR_FILES_ENCRYPTION:-}"
    replace_literal "{{API_DOMAIN}}" "${API_DOMAIN}"
    replace_literal "{{WEB_DOMAIN}}" "${WEB_DOMAIN}"
    replace_literal "{{XMPP_DOMAIN}}" "${XMPP_DOMAIN}"
    replace_literal "{{FILES_DOMAIN}}" "${FILES_DOMAIN}"
    replace_literal "{{MINIO_SECURE_BUCKET}}" "${MINIO_SECURE_BUCKET:-secure-media}"
    replace_literal "{{ADMIN_EMAIL}}" "${ADMIN_EMAIL}"
    replace_literal "{{ADMIN_PASSWORD}}" "${ADMIN_PASSWORD}"
    replace_literal "{{XMPP_ADMIN_PASSWORD}}" "${XMPP_ADMIN_PASSWORD}"
    replace_literal "{{MONGO_PORT}}" "${MONGO_PORT}"
    replace_literal "{{MONGO_DB}}" "${MONGO_DB}"
    replace_literal "{{REDIS_PORT}}" "${REDIS_PORT}"
    # MySQL port comes from databases.mysql.port in deploy.yml (default 3306).
    # MYSQL_ROOT_PASSWORD is already exported by install.sh / .deploy.env.
    # Both are consumed by the backend's MAM_MYSQL_* env vars (mod_mam archive
    # reader for the admin AI Widget conversation viewer).
    _mysql_port="${MYSQL_PORT:-}"
    if [ -z "${_mysql_port}" ] && command -v yq >/dev/null 2>&1 && [ -f "${CONFIG_FILE:-}" ]; then
        _mysql_port="$(yq eval '.databases.mysql.port // "3306"' "${CONFIG_FILE}" 2>/dev/null)"
    fi
    [ -z "${_mysql_port}" ] || [ "${_mysql_port}" = "null" ] && _mysql_port="3306"
    replace_literal "{{MYSQL_PORT}}" "${_mysql_port}"
    replace_literal "{{MYSQL_ROOT_PASSWORD}}" "${MYSQL_ROOT_PASSWORD:-}"
    replace_literal "{{MINIO_ROOT_USER}}" "${MINIO_ROOT_USER}"
    replace_literal "{{MINIO_ROOT_PASSWORD}}" "${MINIO_ROOT_PASSWORD}"
    replace_literal "{{BLOCKCHAIN_ENABLED}}" "${BLOCKCHAIN_ENABLED:-false}"
    replace_literal "{{AI_SERVICE_ENABLED}}" "${AI_SERVICE_ENABLED:-false}"
    replace_literal "{{DOCS_PARSE_ENABLED}}" "${DOCS_PARSE_ENABLED:-false}"
    replace_literal "{{CRAWLER_ENABLED}}" "${CRAWLER_ENABLED:-false}"
    replace_literal "{{CRAWLER_URL}}" "${CRAWLER_URL:-}"
    replace_literal "{{CRAWLER_CALLBACK_URL}}" "${CRAWLER_CALLBACK_URL:-}"
    replace_literal "{{CRAWLER_CALLBACK_SECRET}}" "${CRAWLER_CALLBACK_SECRET:-}"
    replace_literal "{{BASE_APP_DISPLAY_NAME}}" "${BASE_APP_DISPLAY_NAME:-Ethora}"
    replace_literal "{{BASE_APP_DOMAIN_NAME}}" "${BASE_APP_DOMAIN_NAME:-ethora}"
    replace_literal "{{BASE_APP_OWNER_EMAIL}}" "${BASE_APP_OWNER_EMAIL:-${ADMIN_EMAIL}}"
    replace_literal "{{BASE_APP_OWNER_PASSWORD}}" "${BASE_APP_OWNER_PASSWORD:-${ADMIN_PASSWORD}}"
    replace_literal "{{BASE_APP_START_BALANCE}}" "${BASE_APP_START_BALANCE:-1000000}"
    replace_literal "{{AI_SERVICE_PORT}}" "${AI_SERVICE_PORT:-8013}"
    replace_literal "{{AI_SERVICE_SECRET}}" "${AI_SERVICE_SECRET:-}"
    replace_literal "{{DOCS_PARSE_PORT}}" "${DOCS_PARSE_PORT:-8201}"
    replace_literal "{{DOCS_PARSE_SECRET}}" "${DOCS_PARSE_SECRET:-}"
    replace_literal "{{POSTMARK_TOKEN}}" "${POSTMARK_TOKEN:-}"
    replace_literal "{{POSTMARK_ENABLED}}" "${POSTMARK_ENABLED:-false}"
    replace_literal "{{POSTMARK_FROM_EMAIL}}" "${POSTMARK_FROM_EMAIL:-noreply@ethoramail.com}"
    replace_literal "{{POSTMARK_FROM_NAME}}" "${POSTMARK_FROM_NAME:-Ethora Platform}"
    replace_literal "{{POSTMARK_SUBJECT_PREFIX}}" "${POSTMARK_SUBJECT_PREFIX:-Ethora}"

    # Analytics email reports
    replace_literal "{{ANALYTICS_ENABLED}}" "${ANALYTICS_ENABLED:-false}"
    replace_literal "{{DAILY_REPORT_RECEIVERS}}" "${DAILY_REPORT_RECEIVERS:-}"
    replace_literal "{{MONTHLY_REPORT_RECEIVERS}}" "${MONTHLY_REPORT_RECEIVERS:-}"
    replace_literal "{{REPORT_DAILY_SCHEDULE}}" "${REPORT_DAILY_SCHEDULE:-30 8 * * *}"
    replace_literal "{{REPORT_WEEKLY_SCHEDULE}}" "${REPORT_WEEKLY_SCHEDULE:-30 8 * * 1}"
    replace_literal "{{REPORT_MONTHLY_SCHEDULE}}" "${REPORT_MONTHLY_SCHEDULE:-30 8 1 * *}"
    replace_literal "{{REPORT_TIMEZONE}}" "${REPORT_TIMEZONE:-}"
    replace_literal "{{DEFAULT_ROOMS_INACTIVE_DAYS}}" "${DEFAULT_ROOMS_INACTIVE_DAYS:-0}"
    replace_literal "{{LEGAL_CONTACT_EMAIL}}" "${LEGAL_CONTACT_EMAIL:-}"
    replace_literal "{{ALERT_RECIPIENTS}}" "${ALERT_RECIPIENTS:-}"

    # Feedback channel
    replace_literal "{{FEEDBACK_EMAIL_TO}}" "${FEEDBACK_EMAIL_TO:-}"
    replace_literal "{{FEEDBACK_SLACK_WEBHOOK_URL}}" "${FEEDBACK_SLACK_WEBHOOK_URL:-}"
    replace_literal "{{FEEDBACK_RETENTION_DAYS}}" "${FEEDBACK_RETENTION_DAYS:-180}"
    # No placeholder fallback: an unset secret renders empty, and the backend
    # rejects an empty XMPP_SECRET (fail closed). install.sh auto-generates one.
    replace_literal "{{XMPP_SECRET}}" "${XMPP_SECRET:-}"

    # Build/version info (frontend.env.template + backend.env.template footer/ping endpoints).
    replace_literal "{{BUILD_VERSION}}" "${BUILD_VERSION:-unknown}"
    replace_literal "{{BUILD_BRANCH}}" "${BUILD_BRANCH:-unknown}"
    replace_literal "{{BUILD_COMMIT}}" "${BUILD_COMMIT:-unknown}"
    replace_literal "{{BUILD_TIME}}" "${BUILD_TIME:-}"

    # Handle localhost-specific replacements
    if [ "$is_localhost" == "true" ]; then
        # Backend replacements
        replace_literal "ROOT_DOMAIN_PLACEHOLDER" "ROOT_DOMAIN=${ROOT_DOMAIN:-localhost:${BACKEND_PORT}}"
        replace_literal "DEFAULT_APP_URL_PLACEHOLDER" "DEFAULT_APP_URL=http://${WEB_DOMAIN}:${BACKEND_PORT}"
        replace_literal "VERIFY_EMAIL_WEB_URL_PLACEHOLDER" "VERIFY_EMAIL_WEB_URL=http://${WEB_DOMAIN}:${BACKEND_PORT}/verifyEmail"
        replace_literal "TEMP_PASSSORD_WEB_URL_PLACEHOLDER" "TEMP_PASSSORD_WEB_URL=http://${WEB_DOMAIN}:${BACKEND_PORT}/tempPassword"
        replace_literal "XMPP_PATH_PLACEHOLDER" "XMPP_PATH=http://${XMPP_DOMAIN}:5443/api"
        # IMPORTANT: process AI_SERVICE_XMPP_SERVICE_PLACEHOLDER BEFORE the
        # shorter XMPP_SERVICE_PLACEHOLDER. Otherwise the shorter pattern
        # matches inside the longer one (literal-string replacement, no
        # word boundaries) and corrupts the ai-service substitution.
        replace_literal "AI_SERVICE_XMPP_SERVICE_PLACEHOLDER" "XMPP_SERVICE=ws://${XMPP_DOMAIN}:5443/ws"
        replace_literal "XMPP_SERVICE_PLACEHOLDER" "XMPP_SERVICE=ws://${XMPP_DOMAIN}:5443/ws"
        replace_literal "MINIO_URL_PLACEHOLDER" "MINIO_URL=http://${FILES_DOMAIN}:9000"
        # Secure attachments feature is off on localhost (no secure subdomain / cookie domain).
        replace_literal "MINIO_SECURE_URL_PLACEHOLDER" "MINIO_SECURE_URL="
        replace_literal "AUTH_COOKIE_DOMAIN_PLACEHOLDER" "AUTH_COOKIE_DOMAIN="
        # Frontend replacements
        replace_literal "VITE_API_PLACEHOLDER" "VITE_API=http://${API_DOMAIN}:${BACKEND_PORT}/v1"
        replace_literal "VITE_API_V2_PLACEHOLDER" "VITE_API_V2=http://${API_DOMAIN}:${BACKEND_PORT}/v2"
        replace_literal "VITE_APP_XMPP_SERVICE_PLACEHOLDER" "VITE_APP_XMPP_SERVICE=ws://${XMPP_DOMAIN}:5443/ws"
        replace_literal "VITE_APP_CENTRIFUGE_SERVICE_PLACEHOLDER" "VITE_APP_CENTRIFUGE_SERVICE=ws://${WEB_DOMAIN}:8001/connection/websocket"
    else
        # Backend replacements
        replace_literal "ROOT_DOMAIN_PLACEHOLDER" "ROOT_DOMAIN=${ROOT_DOMAIN:-$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')}"
        replace_literal "DEFAULT_APP_URL_PLACEHOLDER" "DEFAULT_APP_URL=https://${WEB_DOMAIN}"
        replace_literal "VERIFY_EMAIL_WEB_URL_PLACEHOLDER" "VERIFY_EMAIL_WEB_URL=https://${WEB_DOMAIN}/verifyEmail"
        replace_literal "TEMP_PASSSORD_WEB_URL_PLACEHOLDER" "TEMP_PASSSORD_WEB_URL=https://${WEB_DOMAIN}/tempPassword"
        # Production default: XMPP clients connect via Nginx on standard 443 (wss://xmpp.domain/ws).
        # Backend talks to Ejabberd locally (no need to expose 5443 publicly).
        #
        # IMPORTANT: use 127.0.0.1 instead of localhost to avoid IPv6 (::1) resolution issues on some hosts,
        # which can cause XMPP admin API calls to fail (and then users/apps won't be provisioned in ejabberd).
        replace_literal "XMPP_PATH_PLACEHOLDER" "XMPP_PATH=http://127.0.0.1:5280/api"
        # ai-service-specific: connect to ejabberd's loopback HTTP/WS port
        # directly instead of going through nginx + the public TLS proxy.
        # Each bot in ai-service maintains a persistent WebSocket connection;
        # at fleet sizes of even a few hundred bots, those would otherwise
        # consume nginx worker_connection slots that should be reserved for
        # external user traffic. ejabberd listens on 5280 by default for
        # cleartext HTTP (matches the existing XMPP_PATH which also uses
        # 127.0.0.1:5280 for the admin API).
        #
        # IMPORTANT: process AI_SERVICE_XMPP_SERVICE_PLACEHOLDER BEFORE the
        # shorter XMPP_SERVICE_PLACEHOLDER. Otherwise the shorter pattern
        # matches inside the longer one (literal-string replacement, no
        # word boundaries) and corrupts the ai-service substitution.
        replace_literal "AI_SERVICE_XMPP_SERVICE_PLACEHOLDER" "XMPP_SERVICE=ws://127.0.0.1:5280/ws"
        replace_literal "XMPP_SERVICE_PLACEHOLDER" "XMPP_SERVICE=wss://${XMPP_DOMAIN}/ws"
        replace_literal "MINIO_URL_PLACEHOLDER" "MINIO_URL=https://${FILES_DOMAIN}"
        # Secure attachments: URL only when the secure subdomain is configured (else feature off).
        replace_literal "MINIO_SECURE_URL_PLACEHOLDER" "MINIO_SECURE_URL=${SECURE_FILES_DOMAIN:+https://${SECURE_FILES_DOMAIN}}"
        # Auth cookie domain = the parent (so the fileToken cookie reaches the secure files subdomain).
        replace_literal "AUTH_COOKIE_DOMAIN_PLACEHOLDER" "AUTH_COOKIE_DOMAIN=.${ROOT_DOMAIN:-$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')}"
        # Frontend replacements
        replace_literal "VITE_API_PLACEHOLDER" "VITE_API=https://${API_DOMAIN}/v1"
        replace_literal "VITE_API_V2_PLACEHOLDER" "VITE_API_V2=https://${API_DOMAIN}/v2"
        replace_literal "VITE_APP_XMPP_SERVICE_PLACEHOLDER" "VITE_APP_XMPP_SERVICE=wss://${XMPP_DOMAIN}/ws"
        replace_literal "VITE_APP_CENTRIFUGE_SERVICE_PLACEHOLDER" "VITE_APP_CENTRIFUGE_SERVICE=wss://${WEB_DOMAIN}/connection/websocket"
    fi
    
    replace_literal "{{ROOT_DOMAIN}}" "${ROOT_DOMAIN:-$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')}"
    replace_literal "{{HOSTED_APPS_ROOT_DOMAIN}}" "${HOSTED_APPS_ROOT_DOMAIN:-${ROOT_DOMAIN:-$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')}}"
    
    # Replace XMPP domain placeholders
    replace_literal "{{XMPP_DOMAIN}}" "${XMPP_DOMAIN}"
    
    # Ensure XMPP variables are set in frontend .env (add if missing)
    if [[ "$output_file" == *"/ethora-app-reactjs/.env" ]]; then
        # Check if XMPP variables exist, if not add them
        if ! echo "$content" | grep -q "VITE_APP_XMPP_SERVICE="; then
            if [ "$is_localhost" == "true" ]; then
                content=$(echo "$content"; echo "VITE_APP_XMPP_SERVICE=ws://${XMPP_DOMAIN}:5443/ws")
            else
                # Production: xmpp is proxied by nginx on 443
                content=$(echo "$content"; echo "VITE_APP_XMPP_SERVICE=wss://${XMPP_DOMAIN}/ws")
            fi
        fi
        if ! echo "$content" | grep -q "VITE_APP_CENTRIFUGE_SERVICE="; then
            if [ "$is_localhost" == "true" ]; then
                content=$(echo "$content"; echo "VITE_APP_CENTRIFUGE_SERVICE=ws://${WEB_DOMAIN}:8001/connection/websocket")
            else
                # Production: Centrifugo is proxied by nginx on 443
                content=$(echo "$content"; echo "VITE_APP_CENTRIFUGE_SERVICE=wss://${WEB_DOMAIN}/connection/websocket")
            fi
        fi
        if ! echo "$content" | grep -q "VITE_XMPP_SERVICE="; then
            content=$(echo "$content"; echo "VITE_XMPP_SERVICE=conference.${XMPP_DOMAIN}")
        fi
        if ! echo "$content" | grep -q "VITE_XMPP_HOST="; then
            content=$(echo "$content"; echo "VITE_XMPP_HOST=${XMPP_DOMAIN}")
        fi
    fi
    
    # Set VITE_DOMAIN_NAME - use BASE_APP_DOMAIN_NAME if available (must match the app created by initEthoraApp.js).
    # Fallback: localhost -> ethora, production -> web subdomain.
    if [ -n "${BASE_APP_DOMAIN_NAME:-}" ]; then
        DOMAIN_NAME_VALUE="${BASE_APP_DOMAIN_NAME}"
    elif [ "$WEB_DOMAIN" == "localhost" ]; then
        DOMAIN_NAME_VALUE="ethora"
    else
        # Extract subdomain from WEB_DOMAIN (e.g., app.example.com -> app)
        DOMAIN_NAME_VALUE=$(echo "$WEB_DOMAIN" | cut -d'.' -f1)
    fi
    replace_literal "{{DOMAIN_NAME}}" "${DOMAIN_NAME_VALUE}"
    
    # Replace Turnstile keys (use empty string if not set)
    replace_literal "{{TURNSTILE_SITE_KEY}}" "${TURNSTILE_SITE_KEY:-}"
    replace_literal "{{TURNSTILE_SECRET_KEY}}" "${TURNSTILE_SECRET_KEY:-}"

    # Swagger toggles (recommended: off in production)
    replace_literal "{{ENABLE_SWAGGER}}" "${ENABLE_SWAGGER:-false}"
    replace_literal "{{ENABLE_SWAGGER_INTERNAL}}" "${ENABLE_SWAGGER_INTERNAL:-false}"

    # Email TLD validation policy (controls Joi `string().email()` strictness).
    # Default "off" matches the helper default and avoids breaking installs that
    # ingest real-world user lists with uncommon TLDs.
    replace_literal "{{EMAIL_TLD_VALIDATION}}" "${EMAIL_TLD_VALIDATION:-off}"
    replace_literal "{{EMAIL_TLD_ALLOWLIST}}" "${EMAIL_TLD_ALLOWLIST:-}"

    # Uptime journey API base (used in uptime.env.template)
    # - localhost: uptime runs in docker; use host.docker.internal to reach API on host
    # - production: use public API domain
    if [ "$is_localhost" == "true" ]; then
        replace_literal "UPTIME_API_BASE_PLACEHOLDER" "http://host.docker.internal:${BACKEND_PORT}"
    else
        replace_literal "UPTIME_API_BASE_PLACEHOLDER" "https://${API_DOMAIN}"
    fi
    
    # Replace frontend service flags (default to 'false' if not set)
    replace_literal "{{DISABLE_FIREBASE}}" "${DISABLE_FIREBASE:-false}"
    replace_literal "{{DISABLE_GA}}" "${DISABLE_GA:-false}"
    replace_literal "{{DISABLE_CLARITY}}" "${DISABLE_CLARITY:-false}"

    # Tracking + integrations (optional)
    replace_literal "{{GA_ID}}" "${GA_ID:-}"
    replace_literal "{{GTM_ID}}" "${GTM_ID:-}"
    replace_literal "{{CLARITY_ID}}" "${CLARITY_ID:-}"
    replace_literal "{{POSTHOG_KEY}}" "${POSTHOG_KEY:-}"
    replace_literal "{{POSTHOG_HOST}}" "${POSTHOG_HOST:-}"
    replace_literal "{{HUBSPOT_ENABLED}}" "${HUBSPOT_ENABLED:-false}"
    replace_literal "{{HUBSPOT_PORTAL_ID}}" "${HUBSPOT_PORTAL_ID:-}"
    replace_literal "{{HUBSPOT_FORM_ID_APP_CREATE}}" "${HUBSPOT_FORM_ID_APP_CREATE:-}"
    replace_literal "{{HUBSPOT_FORM_ID_SIGNUP}}" "${HUBSPOT_FORM_ID_SIGNUP:-}"
    replace_literal "{{HUBSPOT_FORM_ID_TUTORIAL}}" "${HUBSPOT_FORM_ID_TUTORIAL:-}"
    replace_literal "{{HUBSPOT_REGION}}" "${HUBSPOT_REGION:-na1}"
    # Video calls: WEBRTC_* are gated on features.video_calls by
    # refresh-deploy-env.sh (empty when disabled), so the backend call
    # endpoints stay inert unless the feature is enabled.
    replace_literal "{{WEBRTC_HOST}}" "${WEBRTC_HOST:-}"
    replace_literal "{{WEBRTC_API_KEY}}" "${WEBRTC_API_KEY:-}"
    replace_literal "{{WEBRTC_API_SECRET}}" "${WEBRTC_API_SECRET:-}"
    # Immutable audit logs: gated on features.immutable_logs. Everything is
    # rendered empty when the flag is off so no service can reach S3.
    replace_literal "{{IMMUTABLE_LOGS_ENABLED}}" "${IMMUTABLE_LOGS_ENABLED:-false}"
    replace_literal "{{IMMUTABLE_LOGS_INTERVAL_HOURS}}" "${IMMUTABLE_LOGS_INTERVAL_HOURS:-}"
    replace_literal "{{IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID}}" "${IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID:-}"
    replace_literal "{{IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY}}" "${IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY:-}"
    replace_literal "{{IMMUTABLE_LOGS_AWS_REGION}}" "${IMMUTABLE_LOGS_AWS_REGION:-}"
    replace_literal "{{IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME}}" "${IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME:-}"
    # License: rendered from deploy.yml `license:` (see docs/LICENSING.md).
    replace_literal "{{ETHORA_LICENSE_KEY}}" "${ETHORA_LICENSE_KEY:-}"
    replace_literal "{{ETHORA_LICENSE_CALL_HOME}}" "${ETHORA_LICENSE_CALL_HOME:-true}"
    replace_literal "{{ETHORA_LICENSE_SERVER_URL}}" "${ETHORA_LICENSE_SERVER_URL:-}"
    replace_literal "{{ETHORA_LICENSE_GRACE_DAYS}}" "${ETHORA_LICENSE_GRACE_DAYS:-}"
    replace_literal "{{STRIPE_ENABLED}}" "${STRIPE_ENABLED:-false}"
    replace_literal "{{STRIPE_SECRET}}" "${STRIPE_SECRET:-}"
    replace_literal "{{STRIPE_PUBLIC}}" "${STRIPE_PUBLIC:-}"
    replace_literal "{{STRIPE_PLAN}}" "${STRIPE_PLAN:-}"

    # Optional: IAP + Firebase
    replace_literal "{{IAP_ENABLED}}" "${IAP_ENABLED:-false}"
    replace_literal "{{FIREBASE_ENABLED}}" "${FIREBASE_ENABLED:-false}"
    replace_literal "{{FIREBASE_PROJECT_NAME}}" "${FIREBASE_PROJECT_NAME:-}"
    replace_literal "{{FIREBASE_SERVICE_ACCOUNT_PATH}}" "${FIREBASE_SERVICE_ACCOUNT_PATH:-}"
    replace_literal "{{FIREBASE_WEB_API_KEY}}" "${FIREBASE_WEB_API_KEY:-}"
    replace_literal "{{FIREBASE_WEB_AUTH_DOMAIN}}" "${FIREBASE_WEB_AUTH_DOMAIN:-}"
    replace_literal "{{FIREBASE_WEB_PROJECT_ID}}" "${FIREBASE_WEB_PROJECT_ID:-}"
    replace_literal "{{FIREBASE_WEB_STORAGE_BUCKET}}" "${FIREBASE_WEB_STORAGE_BUCKET:-}"
    replace_literal "{{FIREBASE_WEB_MESSAGING_SENDER_ID}}" "${FIREBASE_WEB_MESSAGING_SENDER_ID:-}"
    replace_literal "{{FIREBASE_WEB_APP_ID}}" "${FIREBASE_WEB_APP_ID:-}"
    replace_literal "{{FIREBASE_WEB_MEASUREMENT_ID}}" "${FIREBASE_WEB_MEASUREMENT_ID:-}"
    replace_literal "{{FIREBASE_WEB_VAPID_PUBLIC_KEY}}" "${FIREBASE_WEB_VAPID_PUBLIC_KEY:-}"

    # Push notifications microservice (FCM) + internal requests secret
    replace_literal "{{PUSH_PORT}}" "${PUSH_PORT:-8098}"
    replace_literal "{{B2B_PUSH_SECRET}}" "${B2B_PUSH_SECRET:-}"
    replace_literal "{{INTERNAL_REQUESTS_SECRET}}" "${INTERNAL_REQUESTS_SECRET:-}"
    replace_literal "{{PUSH_UPLOADS_DIR}}" "${PUSH_UPLOADS_DIR:-}"
    # Platform-key delivery + gateway (services.push.* in deploy.yml). Rendered
    # into the push service .env so a redeploy never drops them again.
    replace_literal "{{PUSH_PLATFORM_PROJECT_ID}}" "${PUSH_PLATFORM_PROJECT_ID:-}"
    replace_literal "{{PUSH_PLATFORM_DAILY_QUOTA}}" "${PUSH_PLATFORM_DAILY_QUOTA:-1000}"
    replace_literal "{{PUSH_GATEWAY_URL}}" "${PUSH_GATEWAY_URL:-}"
    replace_literal "{{PUSH_GATEWAY_TOKEN}}" "${PUSH_GATEWAY_TOKEN:-}"

    # Centrifugo (per-deployment, non-critical real-time stats).
    # Placeholders are shared between backend.env.template and centrifugo-config.json.template
    # so a single render keeps backend signer + centrifugo verifier in sync.
    replace_literal "{{CENTRIFUGO_ENABLED}}" "${CENTRIFUGO_ENABLED:-true}"
    replace_literal "{{CENTRIFUGO_PORT}}" "${CENTRIFUGO_PORT:-8001}"
    replace_literal "{{CENTRIFUGO_TIMEOUT_MS}}" "${CENTRIFUGO_TIMEOUT_MS:-2000}"
    replace_literal "{{CENTRIFUGO_API_KEY}}" "${CENTRIFUGO_API_KEY:-}"
    replace_literal "{{CENTRIFUGO_HMAC_SECRET}}" "${CENTRIFUGO_HMAC_SECRET:-}"
    replace_literal "{{CENTRIFUGO_ADMIN_PASSWORD}}" "${CENTRIFUGO_ADMIN_PASSWORD:-}"
    replace_literal "{{CENTRIFUGO_ADMIN_SECRET}}" "${CENTRIFUGO_ADMIN_SECRET:-}"

    # AI providers
    replace_literal "{{AI_API_URL}}" "${AI_API_URL:-https://api.openai.com/v1}"
    replace_literal "{{AI_API_KEY}}" "${AI_API_KEY:-}"
    replace_literal "{{PLATFORM_API_URL}}" "http://localhost:${BACKEND_PORT}"
    replace_literal "{{AI_CHAT_MODEL}}" "${AI_CHAT_MODEL:-gpt-5.6-luna}"
    replace_literal "{{AI_EMBEDDING_MODEL}}" "${AI_EMBEDDING_MODEL:-text-embedding-3-small}"
    replace_literal "{{AI_PG_URL}}" "${AI_PG_URL:-}"

    # Blockchain providers (placeholders; relevant only when BLOCKCHAIN_ENABLED=true)
    replace_literal "{{COINBASE_PRIVATE}}" "${COINBASE_PRIVATE:-}"
    replace_literal "{{EXTERNAL_BC_NETWORKNAME}}" "${EXTERNAL_BC_NETWORKNAME:-}"
    replace_literal "{{EXTERNAL_BC_WS}}" "${EXTERNAL_BC_WS:-}"
    replace_literal "{{ALCHEMY}}" "${ALCHEMY:-}"
    replace_literal "{{USDC_CONTRACT_ADDRESS}}" "${USDC_CONTRACT_ADDRESS:-}"

    # Uptime monitoring service
    replace_literal "{{UPTIME_PORT}}" "${UPTIME_PORT:-8099}"
    replace_literal "{{UPTIME_DATABASE_URL}}" "${UPTIME_DATABASE_URL:-}"
    # Uptime instance tiles (local/public/ethora)
    replace_literal "{{UPTIME_PUBLIC_ENABLED}}" "${UPTIME_PUBLIC_ENABLED:-true}"
    replace_literal "{{UPTIME_ETHORA_ENABLED}}" "${UPTIME_ETHORA_ENABLED:-false}"
    replace_literal "{{PLAYGROUND_APP_ID}}" "${PLAYGROUND_APP_ID:-}"
    replace_literal "{{PLAYGROUND_APP_SECRET}}" "${PLAYGROUND_APP_SECRET:-}"
    # Hosted MCP server
    replace_literal "{{MCP_DOMAIN}}" "${MCP_DOMAIN:-}"
    # Uptime tiles for the MCP service: the local /healthz check follows the
    # service toggle; the public discovery + cert checks additionally need a
    # domain. The domain placeholder falls back to a syntactically valid host so
    # a disabled check never carries an invalid https:/// URL.
    local uptime_mcp_enabled="false"
    local uptime_mcp_public_enabled="false"
    if [ "${MCP_ENABLED:-false}" == "true" ]; then
        uptime_mcp_enabled="true"
        if [ -n "${MCP_DOMAIN:-}" ] && [ "${MCP_DOMAIN:-}" != "null" ] && [ "${API_DOMAIN:-}" != "localhost" ]; then
            uptime_mcp_public_enabled="true"
        fi
    fi
    replace_literal "{{UPTIME_MCP_ENABLED}}" "$uptime_mcp_enabled"
    replace_literal "{{UPTIME_MCP_PUBLIC_ENABLED}}" "$uptime_mcp_public_enabled"
    replace_literal "{{UPTIME_MCP_DOMAIN}}" "${MCP_DOMAIN:-mcp.localhost}"
    replace_literal "{{MCP_PORT}}" "${MCP_PORT:-3030}"
    replace_literal "{{MCP_PUBLIC_URL}}" "${MCP_PUBLIC_URL:-}"
    replace_literal "{{MCP_ENABLE_DANGEROUS_TOOLS}}" "${MCP_ENABLE_DANGEROUS_TOOLS:-true}"
    replace_literal "{{MCP_OPENAI_APPS_CHALLENGE}}" "${MCP_OPENAI_APPS_CHALLENGE:-}"
    replace_literal "{{OAUTH_ISSUER}}" "${OAUTH_ISSUER:-}"
    replace_literal "{{WIDGET_SCRIPT_VERSION}}" "${WIDGET_SCRIPT_VERSION:-}"
    replace_literal "{{WIDGET_URL}}" "${WIDGET_URL:-}"
    replace_literal "{{WIDGET_VERSIONED_URL}}" "${WIDGET_VERSIONED_URL:-}"
    replace_literal "{{AI_FEATURE_ENABLED}}" "${AI_FEATURE_ENABLED:-false}"
    replace_literal "{{VIDEO_CALLS_ENABLED}}" "${VIDEO_CALLS_ENABLED:-false}"
    replace_literal "{{E2EE_ENABLED}}" "${E2EE_ENABLED:-false}"
    replace_literal "{{RATE_LIMIT_DISABLED}}" "${RATE_LIMIT_DISABLED:-false}"
    replace_literal "{{RATE_LIMIT_AUTH_LOGIN_MAX}}" "${RATE_LIMIT_AUTH_LOGIN_MAX:-}"
    replace_literal "{{RATE_LIMIT_AUTH_SIGNUP_MAX}}" "${RATE_LIMIT_AUTH_SIGNUP_MAX:-}"
    replace_literal "{{RATE_LIMIT_AUTH_PASSWORD_MAX}}" "${RATE_LIMIT_AUTH_PASSWORD_MAX:-}"
    replace_literal "{{RATE_LIMIT_AUTH_REFRESH_MAX}}" "${RATE_LIMIT_AUTH_REFRESH_MAX:-}"
    replace_literal "{{RATE_LIMIT_FEEDBACK_MAX}}" "${RATE_LIMIT_FEEDBACK_MAX:-}"
    replace_literal "{{RATE_LIMIT_FEEDBACK_ANON_MAX}}" "${RATE_LIMIT_FEEDBACK_ANON_MAX:-}"
    replace_literal "{{REFRESH_TOKEN_TTL_DAYS}}" "${REFRESH_TOKEN_TTL_DAYS:-7}"
    replace_literal "{{REFRESH_REUSE_POLICY}}" "${REFRESH_REUSE_POLICY:-log_only}"
    replace_literal "{{XMPP_JWT_TTL}}" "${XMPP_JWT_TTL:-10m}"
    replace_literal "{{XMPP_JWT_WIDGET_TTL}}" "${XMPP_JWT_WIDGET_TTL:-100d}"
    replace_literal "{{TRANSLATE_LANGUAGES}}" "${TRANSLATE_LANGUAGES:-}"
    replace_literal "{{LIVEKIT_URL}}" "${LIVEKIT_URL:-}"
    replace_literal "{{WIDGET_API_URL}}" "${WIDGET_API_URL:-}"
    replace_literal "{{WIDGET_XMPP_DOMAIN}}" "${WIDGET_XMPP_DOMAIN:-}"
    replace_literal "{{WIDGET_XMPP_WS_URL}}" "${WIDGET_XMPP_WS_URL:-}"
    replace_literal "{{WIDGET_XMPP_CONFERENCE}}" "${WIDGET_XMPP_CONFERENCE:-}"
    replace_literal "{{WIDGET_QR_URL}}" "${WIDGET_QR_URL:-}"

    # Build / version identity (for API /ping and /version-style endpoints)
    replace_literal "{{ETHORA_BUILD_COMMIT}}" "${ETHORA_BUILD_COMMIT:-}"
    replace_literal "{{ETHORA_BUILD_TIME}}" "${ETHORA_BUILD_TIME:-}"
    replace_literal "{{ETHORA_BUILD_VERSION}}" "${ETHORA_BUILD_VERSION:-}"
    
    # Note: we don't use {{#if ...}} blocks in env templates anymore (simple replacement only).
    
    # Write output file
    echo "$content" > "$output_file" || error "Failed to write generated file: $output_file"
    log "Generated: $output_file"
}

log "Generating environment files..."

# Get paths from environment or use defaults
BACKEND_DIR="${BACKEND_DIR:-$ROOT_DIR/ethora-backend}"
FRONTEND_DIR="${FRONTEND_DIR:-$ROOT_DIR/ethora-app-reactjs}"
PLAYGROUND_DIR="${PLAYGROUND_DIR:-$ROOT_DIR/ethora-sdk-playground}"
MCP_DIR="${MCP_DIR:-$ROOT_DIR/ethora-mcp-server}"

# Stateful data paths (Layer 3 of the rm-rf-safety work).
#
# Pick a clean location for Mongo / MinIO / MySQL state, instead of the
# legacy nested-under-submodule paths (deploy/ethora-backend/infra/docker/data/...,
# deploy/ejabberd-docker/docker-data/my-sql) that look like leftover code
# and have actually been lost to an `rm -rf` in the past.
#
# Resolution priority per service (e.g. MONGO_DATA_DIR):
#   1. Explicit env / .deploy.env override (highest - operator set this on purpose)
#   2. Legacy BACKEND_DATA_DIR / EJABBERD_DIR if its derived path has data on
#      disk (preserves running installs - don't move data out from under them)
#   3. Legacy default literal path if it has data (same reason)
#   4. New default $ROOT_DIR/data/<svc> (fresh installs land here from day one)
#
# migrate-data-paths.sh is the way to move from (2)/(3) to (4) on an existing
# install: stops stack, rsyncs old -> new, sets explicit override, restarts.
LEGACY_BACKEND_DATA_DIR="${BACKEND_DATA_DIR:-$ROOT_DIR/ethora-backend/infra/docker/data}"
LEGACY_EJABBERD_DATA_DIR="${EJABBERD_DIR:-$ROOT_DIR/ejabberd-docker}/docker-data"
# Persistent data lives OUTSIDE both the source and target trees so no git or
# rsync operation can touch it. Default $HOME/ethora-data (invoking user's home,
# even under sudo). Must match preflight-paths.sh, which guards these paths.
_deploy_home() { getent passwd "${SUDO_USER:-$USER}" 2>/dev/null | cut -d: -f6 | grep . || echo "${HOME:-/root}"; }
NEW_DATA_ROOT="${DATA_DIR:-$(_deploy_home)/ethora-data}"

# Returns the resolved data dir on stdout. Args: <SERVICE_NAME> <legacy_path> <new_path>
resolve_data_dir() {
  local svc_var="$1"
  local legacy_path="$2"
  local new_path="$3"
  local current
  eval "current=\${$svc_var:-}"

  # (1) Explicit override - honor it.
  if [ -n "$current" ]; then
    echo "$current"
    return 0
  fi

  # No silent legacy adoption: if data exists at a legacy path but not the
  # configured one, preflight-paths.sh stops the run so the operator migrates on
  # purpose (see migrate-data-paths.sh). Otherwise use the new default.
  echo "$new_path"
}

MONGO_DATA_DIR="$(resolve_data_dir MONGO_DATA_DIR "$LEGACY_BACKEND_DATA_DIR/mongo" "$NEW_DATA_ROOT/mongo")"
MINIO_DATA_DIR="$(resolve_data_dir MINIO_DATA_DIR "$LEGACY_BACKEND_DATA_DIR/minio" "$NEW_DATA_ROOT/minio")"
MYSQL_DATA_DIR="$(resolve_data_dir MYSQL_DATA_DIR "$LEGACY_EJABBERD_DATA_DIR/my-sql" "$NEW_DATA_ROOT/mysql")"
REDIS_DATA_DIR="$(resolve_data_dir REDIS_DATA_DIR "$LEGACY_BACKEND_DATA_DIR/redis" "$NEW_DATA_ROOT/redis")"

export MONGO_DATA_DIR MINIO_DATA_DIR MYSQL_DATA_DIR REDIS_DATA_DIR

# Persist so docker-compose / restart paths pick the same values on every
# run, and migrate-data-paths.sh has a single place to update.
MINIO_IMAGE="${MINIO_IMAGE:-$(yq eval '.databases.minio.image // ""' "$CONFIG_FILE" 2>/dev/null || echo "")}"
[ "$MINIO_IMAGE" = "null" ] && MINIO_IMAGE=""
MINIO_IMAGE="${MINIO_IMAGE:-docker.io/dappros/minio:RELEASE.2025-09-07T16-13-09Z}"
export MINIO_IMAGE
persist_env_var "MINIO_IMAGE" "$MINIO_IMAGE"
persist_env_var "MONGO_DATA_DIR" "$MONGO_DATA_DIR"
persist_env_var "MINIO_DATA_DIR" "$MINIO_DATA_DIR"
persist_env_var "MYSQL_DATA_DIR" "$MYSQL_DATA_DIR"
persist_env_var "REDIS_DATA_DIR" "$REDIS_DATA_DIR"

log "Data directories:"
log "  Mongo: $MONGO_DATA_DIR"
log "  MinIO: $MINIO_DATA_DIR"
log "  MySQL: $MYSQL_DATA_DIR"
log "  Redis: $REDIS_DATA_DIR"
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
# Uptime module lives in the repo (deploy runs from repo), even if ROOT_DIR points to a custom install base.
UPTIME_DIR="${UPTIME_DIR:-$REPO_ROOT_DIR/ethora-uptime}"

# Build / version identity (for /ping and Swagger info.version)
#
# Important:
# - `setup-node-services.sh` sources .deploy.env (NOT backend/.env) before running `npm run build` and `pm2 start`.
# - So we must persist build identity into .deploy.env on every deploy/update, otherwise old values linger.
#
# Prefer the git checkout that update.sh is using (SRC_ROOT) when available, because the runtime deploy dir
# in rsync mode points at the install target (no .git).
BUILD_REPO_DIR="$REPO_ROOT_DIR"
if command -v git >/dev/null 2>&1; then
    if [ -n "${SRC_ROOT:-}" ] && git -C "$SRC_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        BUILD_REPO_DIR="$SRC_ROOT"
    elif git -C "$REPO_ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        BUILD_REPO_DIR="$REPO_ROOT_DIR"
    fi
fi

export ETHORA_BUILD_TIME="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
export ETHORA_BUILD_VERSION="$(date -u +'%y.%m.%d')"
export ETHORA_BUILD_COMMIT=""
if command -v git >/dev/null 2>&1 && git -C "$BUILD_REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ETHORA_BUILD_COMMIT="$(git -C "$BUILD_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo "")"
    export ETHORA_BUILD_COMMIT
fi

# Persist build identity so `setup-node-services.sh` and PM2 see updated values.
persist_env_var "ETHORA_BUILD_TIME" "${ETHORA_BUILD_TIME:-}"
persist_env_var "ETHORA_BUILD_VERSION" "${ETHORA_BUILD_VERSION:-}"
persist_env_var "ETHORA_BUILD_COMMIT" "${ETHORA_BUILD_COMMIT:-}"

if [ -z "${ROOT_DOMAIN:-}" ] || [ "${ROOT_DOMAIN:-}" == "null" ]; then
    if [ "$WEB_DOMAIN" == "localhost" ]; then
        export ROOT_DOMAIN="localhost:${BACKEND_PORT}"
    else
        export ROOT_DOMAIN="$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')"
    fi
fi
persist_env_var "ROOT_DOMAIN" "${ROOT_DOMAIN:-}"

if [ -z "${HOSTED_APPS_ROOT_DOMAIN:-}" ] || [ "${HOSTED_APPS_ROOT_DOMAIN:-}" == "null" ]; then
    export HOSTED_APPS_ROOT_DOMAIN="${ROOT_DOMAIN:-}"
fi
persist_env_var "HOSTED_APPS_ROOT_DOMAIN" "${HOSTED_APPS_ROOT_DOMAIN:-}"
persist_env_var "HOSTED_APPS_ENABLED" "${HOSTED_APPS_ENABLED:-false}"
# Persist the (re-read) widget toggle so update.sh / install.sh see fresh
# values from deploy.yml on the next source of .deploy.env.
persist_env_var "WIDGET_ENABLED" "${WIDGET_ENABLED:-false}"

if [ -z "${WIDGET_SCRIPT_VERSION:-}" ] || [ "${WIDGET_SCRIPT_VERSION:-}" == "null" ]; then
    export WIDGET_SCRIPT_VERSION="$(date -u +'%y%m')"
fi
persist_env_var "WIDGET_SCRIPT_VERSION" "${WIDGET_SCRIPT_VERSION:-}"

if [ "${API_DOMAIN}" == "localhost" ]; then
    export WIDGET_API_URL="http://localhost:${BACKEND_PORT}/v1"
    export WIDGET_XMPP_WS_URL="ws://${XMPP_DOMAIN}:5443/ws"
    export WIDGET_QR_URL="http://${WEB_DOMAIN}:${FRONTEND_PORT:-5173}/app/chat/?qrChatId="
else
    export WIDGET_API_URL="https://${API_DOMAIN}/v1"
    export WIDGET_XMPP_WS_URL="wss://${XMPP_DOMAIN}/ws"
    export WIDGET_QR_URL="https://${WEB_DOMAIN}/app/chat/?qrChatId="
fi
export WIDGET_XMPP_DOMAIN="${XMPP_DOMAIN}"
export WIDGET_XMPP_CONFERENCE="conference.${XMPP_DOMAIN}"
# When widget hosting is enabled but `domains.widget` is empty, derive the
# domain from `domains.web` by replacing the first label with "widget"
# (e.g. app.chat.example.com -> widget.chat.example.com). Removes the
# redundancy of configuring two parallel domain hierarchies for operators
# who follow the standard subdomain pattern, and ensures the AI Widget
# embed code in the admin panel always renders a usable URL when widget
# hosting is on. Operators wanting a non-standard widget host can still
# set `domains.widget` explicitly.
if [ "${WIDGET_ENABLED:-false}" == "true" ] && \
   { [ -z "${WIDGET_DOMAIN:-}" ] || [ "${WIDGET_DOMAIN:-}" == "null" ]; } && \
   [ -n "${WEB_DOMAIN:-}" ] && [ "$WEB_DOMAIN" != "localhost" ] && \
   [[ "$WEB_DOMAIN" == *.* ]]; then
    WIDGET_DOMAIN="widget.$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')"
    log "Auto-derived widget domain from web domain: ${WEB_DOMAIN} -> ${WIDGET_DOMAIN}"
    export WIDGET_DOMAIN
fi
persist_env_var "WIDGET_DOMAIN" "${WIDGET_DOMAIN:-}"
if [ -n "${WIDGET_DOMAIN:-}" ] && [ "${WIDGET_DOMAIN:-}" != "null" ]; then
    export WIDGET_URL="https://${WIDGET_DOMAIN}/assistant.js"
    export WIDGET_VERSIONED_URL="https://${WIDGET_DOMAIN}/assistant${WIDGET_SCRIPT_VERSION}.js"
else
    export WIDGET_URL=""
    export WIDGET_VERSIONED_URL=""
fi
persist_env_var "WIDGET_API_URL" "${WIDGET_API_URL:-}"
persist_env_var "WIDGET_XMPP_DOMAIN" "${WIDGET_XMPP_DOMAIN:-}"
persist_env_var "WIDGET_XMPP_WS_URL" "${WIDGET_XMPP_WS_URL:-}"
persist_env_var "WIDGET_XMPP_CONFERENCE" "${WIDGET_XMPP_CONFERENCE:-}"
persist_env_var "WIDGET_QR_URL" "${WIDGET_QR_URL:-}"
persist_env_var "WIDGET_URL" "${WIDGET_URL:-}"
persist_env_var "WIDGET_VERSIONED_URL" "${WIDGET_VERSIONED_URL:-}"
persist_env_var "WIDGET_DIR" "${WIDGET_DIR:-}"

# Hosted MCP server (optional). When enabled but `domains.mcp` is empty, derive
# the host from `domains.web` by replacing the first label with "mcp"
# (app.chat.example.com -> mcp.chat.example.com), same rule as the widget.
if [ "${MCP_ENABLED:-false}" == "true" ] && \
   { [ -z "${MCP_DOMAIN:-}" ] || [ "${MCP_DOMAIN:-}" == "null" ]; } && \
   [ -n "${WEB_DOMAIN:-}" ] && [ "$WEB_DOMAIN" != "localhost" ] && \
   [[ "$WEB_DOMAIN" == *.* ]]; then
    MCP_DOMAIN="mcp.$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')"
    log "Auto-derived MCP domain from web domain: ${WEB_DOMAIN} -> ${MCP_DOMAIN}"
    export MCP_DOMAIN
fi
if [ "${API_DOMAIN}" == "localhost" ]; then
    export MCP_PUBLIC_URL="http://localhost:${MCP_PORT:-3030}/mcp"
elif [ -n "${MCP_DOMAIN:-}" ] && [ "${MCP_DOMAIN:-}" != "null" ]; then
    export MCP_PUBLIC_URL="https://${MCP_DOMAIN}/mcp"
else
    export MCP_PUBLIC_URL=""
fi
# OAuth 2.1 authorization server (backend) + resource metadata (MCP server).
# Issuer = public API base URL. Derived only when the hosted MCP server is on;
# `services.mcp.oauth_issuer` overrides (no trailing slash).
if [ -n "${MCP_OAUTH_ISSUER_OVERRIDE:-}" ]; then
    export OAUTH_ISSUER="${MCP_OAUTH_ISSUER_OVERRIDE%/}"
elif [ "${MCP_ENABLED:-false}" == "true" ] && [ "${API_DOMAIN:-}" == "localhost" ]; then
    export OAUTH_ISSUER="http://localhost:${BACKEND_PORT:-8080}"
elif [ "${MCP_ENABLED:-false}" == "true" ] && [ -n "${API_DOMAIN:-}" ]; then
    export OAUTH_ISSUER="https://${API_DOMAIN}"
else
    export OAUTH_ISSUER=""
fi
persist_env_var "OAUTH_ISSUER" "${OAUTH_ISSUER:-}"
persist_env_var "MCP_ENABLED" "${MCP_ENABLED:-false}"
persist_env_var "MCP_DOMAIN" "${MCP_DOMAIN:-}"
persist_env_var "MCP_PORT" "${MCP_PORT:-3030}"
persist_env_var "MCP_OPENAI_APPS_CHALLENGE" "${MCP_OPENAI_APPS_CHALLENGE:-}"
persist_env_var "MCP_PUBLIC_URL" "${MCP_PUBLIC_URL:-}"
persist_env_var "MCP_ENABLE_DANGEROUS_TOOLS" "${MCP_ENABLE_DANGEROUS_TOOLS:-true}"
persist_env_var "MCP_DIR" "${MCP_DIR:-}"

# Read one `rate_limits.*` key from deploy.yml: a positive integer passes through,
# blank/null/anything else yields the given fallback (blank = backend default).
read_rate_limit() {
    local key="$1"
    local fallback="$2"
    local raw=""
    raw="$(yq eval "$key" "$CONFIG_FILE" 2>/dev/null || echo "")"
    if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
        echo "$raw"
    else
        echo "$fallback"
    fi
}

# AI service/runtime config
if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    # AI feature umbrella (mirrors install.sh): when features.ai_service is
    # off, all AI-related sub-services are forced off so update.sh / templates
    # don't accidentally re-enable AI for customers whose contract excludes it.
    export AI_FEATURE_ENABLED="$(yq eval '.features.ai_service // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    export VIDEO_CALLS_ENABLED="$(yq eval '.features.video_calls // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    # End-to-end encryption (OMEMO 2) in the chat client. Frontend-only
    # switch: the server holds no keys either way.
    export E2EE_ENABLED="$(yq eval '.features.e2ee // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    # Load-testing kill switch for auth rate limiters. Default false (safe for
    # prod); set features.rate_limit_disabled: true only on a QA/load box.
    export RATE_LIMIT_DISABLED="$(yq eval '.features.rate_limit_disabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    # Per-IP auth limiter ceilings (requests/min). Blank = backend defaults.
    # When the hosted MCP server is enabled and a value is blank, raise login
    # and signup: hosted AI assistants (Claude, ChatGPT) reach the API from a
    # handful of vendor egress IPs shared by all their users, so the default
    # per-IP buckets would throttle everyone at once. Per-email limits stay.
    export RATE_LIMIT_AUTH_LOGIN_MAX="$(read_rate_limit '.rate_limits.auth_login_max' "$([ "${MCP_ENABLED:-false}" == "true" ] && echo 120 || echo "")")"
    export RATE_LIMIT_AUTH_SIGNUP_MAX="$(read_rate_limit '.rate_limits.auth_signup_max' "$([ "${MCP_ENABLED:-false}" == "true" ] && echo 30 || echo "")")"
    export RATE_LIMIT_AUTH_PASSWORD_MAX="$(read_rate_limit '.rate_limits.auth_password_max' "")"
    export RATE_LIMIT_AUTH_REFRESH_MAX="$(read_rate_limit '.rate_limits.auth_refresh_max' "")"
    # Feedback ceilings: authenticated is per minute, anonymous per hour.
    export RATE_LIMIT_FEEDBACK_MAX="$(read_rate_limit '.rate_limits.feedback_max' "")"
    export RATE_LIMIT_FEEDBACK_ANON_MAX="$(read_rate_limit '.rate_limits.feedback_anon_max' "")"
    # Refresh-token rotation. reuse_policy stays log_only until every client refreshes
    # through a single lock; see backend.env.template for what each value does.
    export REFRESH_TOKEN_TTL_DAYS="$(yq eval '.features.refresh_token_ttl_days // 7' "$CONFIG_FILE" 2>/dev/null || echo "7")"
    export REFRESH_REUSE_POLICY="$(yq eval '.features.refresh_reuse_policy // "log_only"' "$CONFIG_FILE" 2>/dev/null || echo "log_only")"
    # XMPP JWT lifetimes (jsonwebtoken duration syntax). Widget stays long until
    # the widget learns to re-provision a session on SASL failure.
    export XMPP_JWT_TTL="$(yq eval '.features.xmpp_jwt_ttl // "10m"' "$CONFIG_FILE" 2>/dev/null || echo "10m")"
    export XMPP_JWT_WIDGET_TTL="$(yq eval '.features.xmpp_widget_jwt_ttl // "100d"' "$CONFIG_FILE" 2>/dev/null || echo "100d")"
    # The install's language list (deploy.yml `translate.languages`): what the
    # separately-installed translation server can translate into. This is the
    # only language list the API serves - it feeds both client pickers and
    # gates user language writes. Empty is a real configuration ("no
    # translation server"), so DO NOT substitute a default here.
    # init-services.sh pushes this into Mongo, where get-config reads it.
    export TRANSLATE_LANGUAGES="$(yq eval '.translate.languages // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    [ "${TRANSLATE_LANGUAGES}" = "null" ] && TRANSLATE_LANGUAGES=""
    export AI_SERVICE_ENABLED="$(yq eval '.services.ai_service.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    export AI_SERVICE_PORT="$(yq eval '.services.ai_service.port // 8013' "$CONFIG_FILE" 2>/dev/null || echo "8013")"
    export DOCS_PARSE_ENABLED="$(yq eval '.services.docs_parse_service.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    export DOCS_PARSE_PORT="$(yq eval '.services.docs_parse_service.port // 8201' "$CONFIG_FILE" 2>/dev/null || echo "8201")"
    export CRAWLER_ENABLED="$(yq eval '.services.crawler.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    export CRAWLER_PORT="$(yq eval '.services.crawler.port // 8000' "$CONFIG_FILE" 2>/dev/null || echo "8000")"
    export CRAWLER_CALLBACK_URL_OVERRIDE="$(yq eval '.services.crawler.callback_url // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    [ "${CRAWLER_CALLBACK_URL_OVERRIDE}" = "null" ] && CRAWLER_CALLBACK_URL_OVERRIDE=""
    export AI_POSTGRES_PORT="$(yq eval '.services.ai_service.postgres_port // 5434' "$CONFIG_FILE" 2>/dev/null || echo "5434")"
    export AI_POSTGRES_DB="$(yq eval '.services.ai_service.postgres_database // "ai_service_embeddings_db"' "$CONFIG_FILE" 2>/dev/null || echo "ai_service_embeddings_db")"
    export AI_POSTGRES_USER="$(yq eval '.services.ai_service.postgres_user // "ai_embeddings"' "$CONFIG_FILE" 2>/dev/null || echo "ai_embeddings")"

    ai_postgres_password_config="$(yq eval '.services.ai_service.postgres_password // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    ai_pg_url_override="$(yq eval '.services.ai_service.pg_url // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
    [ "$ai_postgres_password_config" = "null" ] && ai_postgres_password_config=""
    [ "$ai_pg_url_override" = "null" ] && ai_pg_url_override=""
    if [ -n "$ai_postgres_password_config" ]; then
        export AI_POSTGRES_PASSWORD="$ai_postgres_password_config"
    fi
    export AI_PG_URL="$ai_pg_url_override"

    if [ "${AI_FEATURE_ENABLED:-false}" != "true" ]; then
        # Umbrella off -> force all AI sub-services off, regardless of whether
        # individual flags or .deploy.env still say enabled. This keeps
        # update.sh / docker-compose / PM2 from spinning up AI bits for
        # customers without an AI contract.
        export AI_SERVICE_ENABLED="false"
        export DOCS_PARSE_ENABLED="false"
        export CRAWLER_ENABLED="false"
    fi
fi

if [ -z "${AI_SERVICE_PORT:-}" ] || [ "${AI_SERVICE_PORT:-}" == "null" ]; then
    export AI_SERVICE_PORT="8013"
fi
if [ -z "${DOCS_PARSE_PORT:-}" ] || [ "${DOCS_PARSE_PORT:-}" == "null" ]; then
    export DOCS_PARSE_PORT="8201"
fi
if [ -z "${AI_POSTGRES_PORT:-}" ] || [ "${AI_POSTGRES_PORT:-}" == "null" ]; then
    export AI_POSTGRES_PORT="5434"
fi
if [ -z "${AI_POSTGRES_DB:-}" ] || [ "${AI_POSTGRES_DB:-}" == "null" ]; then
    export AI_POSTGRES_DB="ai_service_embeddings_db"
fi
if [ -z "${AI_POSTGRES_USER:-}" ] || [ "${AI_POSTGRES_USER:-}" == "null" ]; then
    export AI_POSTGRES_USER="ai_embeddings"
fi
if [ -z "${CRAWLER_PORT:-}" ] || [ "${CRAWLER_PORT:-}" == "null" ]; then
    export CRAWLER_PORT="8000"
fi

if [ "${CRAWLER_ENABLED:-false}" == "true" ]; then
    export CRAWLER_URL="http://localhost:${CRAWLER_PORT}/crawl"
else
    export CRAWLER_URL=""
fi

# Crawler -> backend callback (DAPPROS_URL inside the crawler container).
#
# The crawler's deep-crawl pass runs in a background thread and POSTs its
# result to this URL with "/<appId>" appended. Without it, main.py's
# os.getenv('DAPPROS_URL') is None and the POST target becomes the literal
# "None/<appId>", so everything past the first synchronous page batch is lost.
#
# Default target is the host-published backend port via host.docker.internal
# (compose gives the crawler an extra_hosts entry for it, as it does for
# uptime/monitoring). Deliberately NOT the public API domain: the receiving
# route POST /v1/sources/site-crawl/internal-for-crawler/:appId has no auth
# middleware, so keep it off the internet-facing path.
if [ "${CRAWLER_ENABLED:-false}" == "true" ]; then
    if [ -n "${CRAWLER_CALLBACK_URL_OVERRIDE:-}" ]; then
        export CRAWLER_CALLBACK_URL="${CRAWLER_CALLBACK_URL_OVERRIDE}"
    else
        export CRAWLER_CALLBACK_URL="http://host.docker.internal:${BACKEND_PORT:-8080}/v1/sources/site-crawl/internal-for-crawler"
    fi
    # An appId in the configured value would produce ".../<appId>/<appId>".
    case "$CRAWLER_CALLBACK_URL" in
        */internal-for-crawler|*/internal-for-crawler/) : ;;
        *) warn "services.crawler.callback_url does not end in /internal-for-crawler - the crawler appends /<appId> to it: $CRAWLER_CALLBACK_URL" ;;
    esac
else
    export CRAWLER_CALLBACK_URL=""
fi

if [ "${AI_SERVICE_ENABLED:-false}" == "true" ]; then
    if [ -n "${AI_PG_URL:-}" ] && [ "${AI_PG_URL:-}" != "null" ]; then
        export AI_POSTGRES_MANAGED="false"
    else
        if [ -z "${AI_POSTGRES_PASSWORD:-}" ] || [ "${AI_POSTGRES_PASSWORD:-}" == "null" ]; then
            export AI_POSTGRES_PASSWORD="$(openssl rand -hex 24)"
        fi
        export AI_POSTGRES_MANAGED="true"
        export AI_PG_URL="postgresql://${AI_POSTGRES_USER}:${AI_POSTGRES_PASSWORD}@127.0.0.1:${AI_POSTGRES_PORT}/${AI_POSTGRES_DB}"
    fi
else
    export AI_POSTGRES_MANAGED="false"
fi

# Immutable audit logs: enforce the gate one more time here, unconditionally.
# The read above lives inside an `if command -v yq` block, so on a host without
# yq the values would otherwise survive from a previously-sourced .deploy.env
# and leak credentials into the rendered .env after the flag was turned off.
if [ "${IMMUTABLE_LOGS_ENABLED:-false}" != "true" ]; then
    export IMMUTABLE_LOGS_ENABLED="false"
    export IMMUTABLE_LOGS_INTERVAL_HOURS=""
    export IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID=""
    export IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY=""
    export IMMUTABLE_LOGS_AWS_REGION=""
    export IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME=""
fi
persist_env_var "IMMUTABLE_LOGS_ENABLED" "${IMMUTABLE_LOGS_ENABLED:-false}"
persist_env_var "IMMUTABLE_LOGS_INTERVAL_HOURS" "${IMMUTABLE_LOGS_INTERVAL_HOURS:-}"
persist_env_var "IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID" "${IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID:-}"
persist_env_var "IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY" "${IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY:-}"
persist_env_var "IMMUTABLE_LOGS_AWS_REGION" "${IMMUTABLE_LOGS_AWS_REGION:-}"
persist_env_var "IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME" "${IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME:-}"

persist_env_var "AI_FEATURE_ENABLED" "${AI_FEATURE_ENABLED:-false}"
persist_env_var "VIDEO_CALLS_ENABLED" "${VIDEO_CALLS_ENABLED:-false}"
persist_env_var "E2EE_ENABLED" "${E2EE_ENABLED:-false}"
persist_env_var "RATE_LIMIT_DISABLED" "${RATE_LIMIT_DISABLED:-false}"
persist_env_var "RATE_LIMIT_AUTH_LOGIN_MAX" "${RATE_LIMIT_AUTH_LOGIN_MAX:-}"
persist_env_var "RATE_LIMIT_AUTH_SIGNUP_MAX" "${RATE_LIMIT_AUTH_SIGNUP_MAX:-}"
persist_env_var "RATE_LIMIT_AUTH_PASSWORD_MAX" "${RATE_LIMIT_AUTH_PASSWORD_MAX:-}"
persist_env_var "RATE_LIMIT_AUTH_REFRESH_MAX" "${RATE_LIMIT_AUTH_REFRESH_MAX:-}"
persist_env_var "RATE_LIMIT_FEEDBACK_MAX" "${RATE_LIMIT_FEEDBACK_MAX:-}"
persist_env_var "RATE_LIMIT_FEEDBACK_ANON_MAX" "${RATE_LIMIT_FEEDBACK_ANON_MAX:-}"
persist_env_var "FEEDBACK_EMAIL_TO" "${FEEDBACK_EMAIL_TO:-}"
persist_env_var "FEEDBACK_SLACK_WEBHOOK_URL" "${FEEDBACK_SLACK_WEBHOOK_URL:-}"
persist_env_var "FEEDBACK_RETENTION_DAYS" "${FEEDBACK_RETENTION_DAYS:-180}"
persist_env_var "REFRESH_TOKEN_TTL_DAYS" "${REFRESH_TOKEN_TTL_DAYS:-7}"
persist_env_var "REFRESH_REUSE_POLICY" "${REFRESH_REUSE_POLICY:-log_only}"
persist_env_var "XMPP_JWT_TTL" "${XMPP_JWT_TTL:-10m}"
persist_env_var "XMPP_JWT_WIDGET_TTL" "${XMPP_JWT_WIDGET_TTL:-100d}"
persist_env_var "TRANSLATE_LANGUAGES" "${TRANSLATE_LANGUAGES:-}"
persist_env_var "AI_SERVICE_ENABLED" "${AI_SERVICE_ENABLED:-false}"
persist_env_var "AI_SERVICE_PORT" "${AI_SERVICE_PORT:-8013}"
persist_env_var "DOCS_PARSE_ENABLED" "${DOCS_PARSE_ENABLED:-false}"
persist_env_var "DOCS_PARSE_PORT" "${DOCS_PARSE_PORT:-8201}"
persist_env_var "AI_POSTGRES_PORT" "${AI_POSTGRES_PORT:-5434}"
persist_env_var "AI_POSTGRES_DB" "${AI_POSTGRES_DB:-ai_service_embeddings_db}"
persist_env_var "AI_POSTGRES_USER" "${AI_POSTGRES_USER:-ai_embeddings}"
persist_env_var "AI_POSTGRES_PASSWORD" "${AI_POSTGRES_PASSWORD:-}"
persist_env_var "AI_POSTGRES_MANAGED" "${AI_POSTGRES_MANAGED:-false}"
persist_env_var "AI_PG_URL" "${AI_PG_URL:-}"
persist_env_var "CRAWLER_ENABLED" "${CRAWLER_ENABLED:-false}"
persist_env_var "CRAWLER_PORT" "${CRAWLER_PORT:-8000}"
persist_env_var "CRAWLER_URL" "${CRAWLER_URL:-}"
persist_env_var "CRAWLER_CALLBACK_URL" "${CRAWLER_CALLBACK_URL:-}"

# Push service / internal auth secrets (stable across upgrades)
if [ -z "${PUSH_PORT:-}" ] || [ "${PUSH_PORT:-}" == "null" ]; then
    export PUSH_PORT="8098"
fi
persist_env_var "PUSH_PORT" "${PUSH_PORT:-}"

if [ -z "${B2B_PUSH_SECRET:-}" ] || [ "${B2B_PUSH_SECRET:-}" == "null" ]; then
    export B2B_PUSH_SECRET="$(openssl rand -base64 32)"
fi
persist_env_var "B2B_PUSH_SECRET" "${B2B_PUSH_SECRET:-}"

if [ -z "${INTERNAL_REQUESTS_SECRET:-}" ] || [ "${INTERNAL_REQUESTS_SECRET:-}" == "null" ]; then
    export INTERNAL_REQUESTS_SECRET="$(openssl rand -base64 32)"
fi
persist_env_var "INTERNAL_REQUESTS_SECRET" "${INTERNAL_REQUESTS_SECRET:-}"

# Centrifugo secrets must remain stable across updates (HMAC secret is shared
# between the backend's wsToken signer and the centrifugo container's verifier;
# the API key gates the backend -> centrifugo /publish HTTP call).
# We generate them here too so existing installs (which never had these in
# .deploy.env) get values populated on the first update without needing reinstall.
if [ -z "${CENTRIFUGO_ENABLED:-}" ] || [ "${CENTRIFUGO_ENABLED:-}" == "null" ]; then
    if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
        export CENTRIFUGO_ENABLED="$(yq eval '.services.centrifugo.enabled | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; export CENTRIFUGO_ENABLED="${CENTRIFUGO_ENABLED:-true}"
    else
        export CENTRIFUGO_ENABLED="true"
    fi
fi
if [ -z "${CENTRIFUGO_PORT:-}" ] || [ "${CENTRIFUGO_PORT:-}" == "null" ]; then
    if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
        export CENTRIFUGO_PORT="$(yq eval '.services.centrifugo.port // 8001' "$CONFIG_FILE" 2>/dev/null || echo "8001")"
    else
        export CENTRIFUGO_PORT="8001"
    fi
fi
if [ -z "${CENTRIFUGO_TIMEOUT_MS:-}" ] || [ "${CENTRIFUGO_TIMEOUT_MS:-}" == "null" ]; then
    if command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
        export CENTRIFUGO_TIMEOUT_MS="$(yq eval '.services.centrifugo.timeout_ms // 2000' "$CONFIG_FILE" 2>/dev/null || echo "2000")"
    else
        export CENTRIFUGO_TIMEOUT_MS="2000"
    fi
fi
if [ -z "${CENTRIFUGO_API_KEY:-}" ] || [ "${CENTRIFUGO_API_KEY:-}" == "null" ]; then
    export CENTRIFUGO_API_KEY="$(openssl rand -hex 32)"
    log "Generated Centrifugo API key (first run on this install)"
fi
if [ -z "${CENTRIFUGO_HMAC_SECRET:-}" ] || [ "${CENTRIFUGO_HMAC_SECRET:-}" == "null" ]; then
    export CENTRIFUGO_HMAC_SECRET="$(openssl rand -hex 32)"
    log "Generated Centrifugo HMAC secret (first run on this install)"
fi
if [ -z "${CENTRIFUGO_ADMIN_PASSWORD:-}" ] || [ "${CENTRIFUGO_ADMIN_PASSWORD:-}" == "null" ]; then
    export CENTRIFUGO_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    log "Generated Centrifugo admin password (first run on this install)"
fi
if [ -z "${CENTRIFUGO_ADMIN_SECRET:-}" ] || [ "${CENTRIFUGO_ADMIN_SECRET:-}" == "null" ]; then
    export CENTRIFUGO_ADMIN_SECRET="$(openssl rand -hex 32)"
    log "Generated Centrifugo admin secret (first run on this install)"
fi
persist_env_var "CENTRIFUGO_ENABLED" "${CENTRIFUGO_ENABLED:-true}"
persist_env_var "CENTRIFUGO_PORT" "${CENTRIFUGO_PORT:-8001}"
persist_env_var "CENTRIFUGO_TIMEOUT_MS" "${CENTRIFUGO_TIMEOUT_MS:-2000}"
persist_env_var "CENTRIFUGO_API_KEY" "${CENTRIFUGO_API_KEY:-}"
persist_env_var "CENTRIFUGO_HMAC_SECRET" "${CENTRIFUGO_HMAC_SECRET:-}"
persist_env_var "CENTRIFUGO_ADMIN_PASSWORD" "${CENTRIFUGO_ADMIN_PASSWORD:-}"
persist_env_var "CENTRIFUGO_ADMIN_SECRET" "${CENTRIFUGO_ADMIN_SECRET:-}"

# Persistent uploads dir for push service account JSON files
if [ -z "${PUSH_UPLOADS_DIR:-}" ] || [ "${PUSH_UPLOADS_DIR:-}" == "null" ]; then
    export PUSH_UPLOADS_DIR="$BACKEND_DIR/services/push/uploads"
fi
persist_env_var "PUSH_UPLOADS_DIR" "${PUSH_UPLOADS_DIR:-}"

# AI/docs internal auth secrets must remain stable across updates.
# Backend .env includes them even when those services are optional, so rotating them every run
# forces unnecessary backend rebuilds and can break service-to-service auth.
if [ -z "${AI_SERVICE_SECRET:-}" ] || [ "${AI_SERVICE_SECRET:-}" == "null" ]; then
    export AI_SERVICE_SECRET="$(openssl rand -base64 32)"
fi
persist_env_var "AI_SERVICE_SECRET" "${AI_SERVICE_SECRET:-}"

if [ -z "${DOCS_PARSE_SECRET:-}" ] || [ "${DOCS_PARSE_SECRET:-}" == "null" ]; then
    export DOCS_PARSE_SECRET="$(openssl rand -base64 32)"
fi
persist_env_var "DOCS_PARSE_SECRET" "${DOCS_PARSE_SECRET:-}"

# Shared secret the crawler presents on its result callback, and the backend
# checks. Both sides read it from their own rendered env, so it must be
# generated before either template below is rendered.
#
# Hex rather than base64 (as used above): the value travels as an HTTP header,
# and hex avoids any question of padding or special characters surviving the
# env-file -> container -> header round trip.
#
# Generated even when the crawler is off, and kept stable across updates, for
# the same reason as the secrets above: the backend .env carries it either way,
# and rotating it every run would force needless backend rebuilds. It is not a
# capability on its own - it only authenticates writes to a route that does
# nothing unless a crawl was requested.
if [ -z "${CRAWLER_CALLBACK_SECRET:-}" ] || [ "${CRAWLER_CALLBACK_SECRET:-}" == "null" ]; then
    export CRAWLER_CALLBACK_SECRET="$(openssl rand -hex 32)"
fi
persist_env_var "CRAWLER_CALLBACK_SECRET" "${CRAWLER_CALLBACK_SECRET:-}"

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

# At-rest encryption secrets (wallet private keys, custom object fields, the
# legacy encrypted upload path). Per install, never shipped in the template:
# a value already persisted wins, then the value of the install's current
# .env (installs from before these were generated keep decrypting their
# data), then a fresh one. Rotating an existing install is a separate step
# (the re-encrypt tool), never done here.
ensure_encryption_secret() {
    local key="$1" kind="$2" current val
    eval "current=\${$key:-}"
    if [ -n "$current" ] && [ "$current" != "null" ]; then
        return 0
    fi
    val="$(grep -E "^${key}=" "$BACKEND_API_DIR/.env" 2>/dev/null | head -n 1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//')"
    if [ -z "$val" ] || [ "$val" = "{{$key}}" ]; then
        if [ "$kind" = "keyiv" ]; then
            val="$(openssl rand -hex 32):$(openssl rand -hex 16)"
        else
            val="$(openssl rand -base64 36 | tr -d '\n')"
        fi
        log "Generated $key"
    fi
    export "$key=$val"
    persist_env_var "$key" "$val"
}
ensure_encryption_secret CRYPTOPAIR_SECRET passphrase
ensure_encryption_secret SECRET_FOR_DB_ENCRYPTION keyiv
ensure_encryption_secret SECRET_FOR_FILES_ENCRYPTION keyiv

# Generate backend .env
replace_template \
    "$DEPLOY_DIR/templates/backend.env.template" \
    "$BACKEND_API_DIR/.env"
# In image mode the build identity is baked into the image (2610.4 and the
# commit it was built from); the date-based values rendered here would
# override it through env_file, so drop them.
if [ "${BACKEND_MODE:-source}" = "image" ]; then
    sed -i '/^ETHORA_BUILD_\(VERSION\|COMMIT\|TIME\|BRANCH\)=/d' "$BACKEND_API_DIR/.env"
fi

# Generate centrifugo container config (mounted by docker-compose.enterprise.yml).
# The file path here MUST match the volume mount in deploy/docker-compose.enterprise.yml
# (currently `${BACKEND_DIR:-./ethora-backend}/centrifugo-config.json`).
# We always regenerate it so any rotated secret is propagated to the centrifugo container
# the next time it is recreated/restarted by update.sh / install.sh.
if [ -f "$DEPLOY_DIR/templates/centrifugo-config.json.template" ]; then
    replace_template \
        "$DEPLOY_DIR/templates/centrifugo-config.json.template" \
        "$BACKEND_DIR/centrifugo-config.json"
fi

# Generate push service .env (optional; service lives under backend repo)
PUSH_DIR="$BACKEND_DIR/services/push"
if [ -d "$PUSH_DIR" ] && [ "${PUSH_ENABLED:-true}" == "true" ]; then
    replace_template \
        "$DEPLOY_DIR/templates/push.env.template" \
        "$PUSH_DIR/.env"
fi

# Generate AI service .env
if [ "${AI_SERVICE_ENABLED}" == "true" ]; then
    replace_template \
        "$DEPLOY_DIR/templates/ai-service.env.template" \
        "$AI_SERVICE_DIR/.env"
fi

# Generate docs parse service .env
if [ "${DOCS_PARSE_ENABLED}" == "true" ]; then
    replace_template \
        "$DEPLOY_DIR/templates/docs-parse.env.template" \
        "$DOCS_PARSE_DIR/.env"
fi

# Generate crawler .env.
#
# Rendered to deploy/generated/ rather than into the backend submodule: the
# crawler container mounts only main.py, so the env has to come in through
# `env_file` in docker-compose.enterprise.yml (the path there must stay in
# sync with the one below).
#
# Generated unconditionally, NOT gated on CRAWLER_ENABLED: compose validates
# every `env_file` when it loads docker-compose.enterprise.yml, before profiles
# filter services out, so a missing file would break `up` on every install that
# has the crawler disabled. With the crawler off the rendered DAPPROS_URL is
# empty and nothing reads it.
mkdir -p "$DEPLOY_DIR/generated/crawler" 2>/dev/null || true
replace_template \
    "$DEPLOY_DIR/templates/crawler.env.template" \
    "$DEPLOY_DIR/generated/crawler/crawler.env"

# Generate uptime service .env + config (optional)
if [ "${UPTIME_ENABLED:-false}" == "true" ]; then
    if [ ! -f "$UPTIME_DIR/package.json" ]; then
        warn "Uptime sources not found at $UPTIME_DIR (submodule not initialized?)"
        # Still generate config/env so health-check and docker-compose can work once the submodule is available.
    fi
    mkdir -p "$DEPLOY_DIR/generated/uptime" 2>/dev/null || true
    replace_template \
        "$DEPLOY_DIR/templates/uptime.env.template" \
        "$DEPLOY_DIR/generated/uptime/uptime.env"
    replace_template \
        "$DEPLOY_DIR/templates/uptime-config.yml.template" \
        "$DEPLOY_DIR/generated/uptime/uptime.yml"
fi

# Generate the immutable audit logs env (S3 export job).
#
# Rendered to deploy/generated/ rather than into a submodule because the
# consuming service does not exist yet (separate ticket) - this gives it a
# stable path to read from without this script needing to know its layout.
# When the feature is off we actively delete a previously generated file so an
# install that used to have S3 credentials doesn't keep them on disk.
IMMUTABLE_LOGS_ENV_FILE="$DEPLOY_DIR/generated/immutable-logs/immutable-logs.env"
if [ "${IMMUTABLE_LOGS_ENABLED:-false}" == "true" ]; then
    mkdir -p "$DEPLOY_DIR/generated/immutable-logs" 2>/dev/null || true
    replace_template \
        "$DEPLOY_DIR/templates/immutable-logs.env.template" \
        "$IMMUTABLE_LOGS_ENV_FILE"
    # Contains AWS credentials - keep it owner-readable only.
    chmod 600 "$IMMUTABLE_LOGS_ENV_FILE" 2>/dev/null || true
elif [ -f "$IMMUTABLE_LOGS_ENV_FILE" ]; then
    rm -f "$IMMUTABLE_LOGS_ENV_FILE"
    log "Removed stale $IMMUTABLE_LOGS_ENV_FILE (features.immutable_logs is off)"
fi

# Generate frontend .env
replace_template \
    "$DEPLOY_DIR/templates/frontend.env.template" \
    "$FRONTEND_DIR/.env"

# Generate widget .env.production.local (optional)
if [ "${WIDGET_ENABLED:-false}" == "true" ]; then
    # Deliberately checking the manifest, not the directory: an uninitialized
    # submodule leaves an empty directory, and writing the env file into it
    # would make that emptiness look like a real checkout to later steps.
    if [ ! -f "$WIDGET_DIR/package.json" ]; then
        warn "Widget sources not found at $WIDGET_DIR (submodule not initialized?)"
    else
        replace_template \
            "$DEPLOY_DIR/templates/widget.env.template" \
            "$WIDGET_DIR/.env.production.local"
    fi
fi

# Generate SDK playground .env.local (optional)
if [ "${PLAYGROUND_ENABLED:-false}" == "true" ]; then
    if [ ! -f "$PLAYGROUND_DIR/package.json" ]; then
        warn "SDK playground sources not found at $PLAYGROUND_DIR (submodule not initialized?)"
    else
        if [ "$API_DOMAIN" == "localhost" ]; then
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
ETHORA_CHAT_APP_ID=${PLAYGROUND_APP_ID:-}
ETHORA_CHAT_APP_SECRET=${PLAYGROUND_APP_SECRET:-}
NEXT_PUBLIC_BACKEND_URL=${PLAYGROUND_BACKEND_URL}
EOF
        log "Generated: $PLAYGROUND_DIR/.env.local"
    fi
fi

# Generate hosted MCP server .env (optional)
MCP_ENV_FILE="$MCP_DIR/.env"
if [ "${MCP_ENABLED:-false}" == "true" ]; then
    if [ ! -f "$MCP_DIR/package.json" ]; then
        warn "MCP server sources not found at $MCP_DIR (submodule not initialized?)"
    else
        replace_template \
            "$DEPLOY_DIR/templates/mcp.env.template" \
            "$MCP_ENV_FILE"
    fi
elif [ -f "$MCP_ENV_FILE" ]; then
    rm -f "$MCP_ENV_FILE"
    log "Removed stale $MCP_ENV_FILE (services.mcp.enabled is off)"
fi

log "Environment files generated successfully"

