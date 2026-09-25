#!/bin/bash
#
# Refresh selected .deploy.env values from config/deploy.yml.
# This keeps runtime env in sync with updated domains/base app settings
# without overwriting secrets or empty fields.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="$DEPLOY_DIR/.deploy.env"
CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"

if [ ! -f "$ENV_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
  exit 0
fi

if ! command -v yq >/dev/null 2>&1; then
  exit 0
fi

read_config() {
  local key="$1"
  local value=""
  value="$(yq eval "$key" "$CONFIG_FILE" 2>/dev/null || echo "")"
  if [ "$value" == "null" ]; then
    value=""
  fi
  echo "$value"
}

escape_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  echo "$value"
}

update_env_var() {
  local key="$1"
  local value="$2"
  if [ -z "$key" ] || [ -z "$value" ]; then
    return 0
  fi

  force_update_env_var "$key" "$value"
}

# Same as update_env_var but writes empty values too. Use this where an empty
# value is meaningful (e.g. clearing credentials after a feature flag was turned
# off) rather than "operator left the field blank, keep what we have".
force_update_env_var() {
  local key="$1"
  local value="$2"
  if [ -z "$key" ]; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  grep -v "^export ${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
  printf 'export %s="%s"\n' "$key" "$(escape_env_value "$value")" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  if [ -n "${SUDO_USER:-}" ] && [ "${EUID:-$(id -u)}" -eq 0 ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown "$SUDO_USER":"$SUDO_USER" "$ENV_FILE" 2>/dev/null || chown "$SUDO_USER" "$ENV_FILE" 2>/dev/null || true
  fi
}

# Domains
api_domain="$(read_config '.domains.api')"
web_domain="$(read_config '.domains.web')"
xmpp_domain="$(read_config '.domains.xmpp')"
files_domain="$(read_config '.domains.files')"
playground_domain="$(read_config '.domains.playground // ""')"
widget_domain="$(read_config '.domains.widget // ""')"
mcp_domain="$(read_config '.domains.mcp // ""')"
hosted_apps_root_domain="$(read_config '.domains.hosted_apps_root // ""')"
uptime_domain="$(read_config '.domains.uptime // ""')"
legacy_domains_enabled="$(read_config '.legacy_domains.enabled // "false"')"
legacy_web_domain="$(read_config '.legacy_domains.web // ""')"
legacy_web_mode="$(read_config '.legacy_domains.web_mode // "redirect"')"
legacy_files_domain="$(read_config '.legacy_domains.files // ""')"
legacy_files_mode="$(read_config '.legacy_domains.files_mode // "redirect"')"

update_env_var "API_DOMAIN" "$api_domain"
update_env_var "WEB_DOMAIN" "$web_domain"
update_env_var "XMPP_DOMAIN" "$xmpp_domain"
update_env_var "FILES_DOMAIN" "$files_domain"
update_env_var "PLAYGROUND_DOMAIN" "$playground_domain"
update_env_var "WIDGET_DOMAIN" "$widget_domain"
update_env_var "MCP_DOMAIN" "$mcp_domain"
update_env_var "HOSTED_APPS_ROOT_DOMAIN" "$hosted_apps_root_domain"
update_env_var "UPTIME_DOMAIN" "$uptime_domain"
update_env_var "LEGACY_DOMAINS_ENABLED" "$legacy_domains_enabled"
update_env_var "LEGACY_WEB_DOMAIN" "$legacy_web_domain"
update_env_var "LEGACY_WEB_MODE" "$legacy_web_mode"
update_env_var "LEGACY_FILES_DOMAIN" "$legacy_files_domain"
update_env_var "LEGACY_FILES_MODE" "$legacy_files_mode"

# Frontend flags / analytics IDs
disable_firebase="$(read_config '.frontend.disable_firebase // "false"')"
disable_ga="$(read_config '.frontend.disable_ga // "false"')"
disable_clarity="$(read_config '.frontend.disable_clarity // "false"')"
ga_id="$(read_config '.frontend.ga_id // ""')"
gtm_id="$(read_config '.frontend.gtm_id // ""')"
clarity_id="$(read_config '.frontend.clarity_id // ""')"
posthog_key="$(read_config '.frontend.posthog_key // ""')"
posthog_host="$(read_config '.frontend.posthog_host // ""')"

update_env_var "DISABLE_FIREBASE" "$disable_firebase"
update_env_var "DISABLE_GA" "$disable_ga"
update_env_var "DISABLE_CLARITY" "$disable_clarity"
update_env_var "GA_ID" "$ga_id"
update_env_var "GTM_ID" "$gtm_id"
update_env_var "CLARITY_ID" "$clarity_id"
update_env_var "POSTHOG_KEY" "$posthog_key"
update_env_var "POSTHOG_HOST" "$posthog_host"

# HubSpot integration (CRM/Slack notifications via Forms API).
# Persist so that any process sourcing .deploy.env (incl. setup-env.sh invoked outside update.sh)
# sees the latest values from deploy.yml.
hubspot_enabled="$(read_config '.integrations.hubspot.enabled // "false"')"
hubspot_portal_id="$(read_config '.integrations.hubspot.portal_id // ""')"
hubspot_form_id_app_create="$(read_config '.integrations.hubspot.form_id_app_create // ""')"
hubspot_form_id_signup="$(read_config '.integrations.hubspot.form_id_signup // ""')"
hubspot_form_id_tutorial="$(read_config '.integrations.hubspot.form_id_tutorial // ""')"
hubspot_region="$(read_config '.integrations.hubspot.region // "na1"')"

update_env_var "HUBSPOT_ENABLED" "$hubspot_enabled"
update_env_var "HUBSPOT_PORTAL_ID" "$hubspot_portal_id"
update_env_var "HUBSPOT_FORM_ID_APP_CREATE" "$hubspot_form_id_app_create"
update_env_var "HUBSPOT_FORM_ID_SIGNUP" "$hubspot_form_id_signup"
update_env_var "HUBSPOT_FORM_ID_TUTORIAL" "$hubspot_form_id_tutorial"
update_env_var "HUBSPOT_REGION" "$hubspot_region"

# Postmark + analytics email reports (same rationale as HubSpot above).
postmark_enabled="$(read_config '.features.postmark // "false"')"
postmark_token="$(read_config '.integrations.postmark.token // ""')"
postmark_from_email="$(read_config '.integrations.postmark.from_email // "noreply@ethoramail.com"')"
postmark_from_name="$(read_config '.integrations.postmark.from_name // "Ethora Platform"')"
postmark_subject_prefix="$(read_config '.integrations.postmark.subject_prefix // "Ethora"')"
analytics_enabled="$(read_config '.features.analytics // "false"')"
video_calls_enabled="$(read_config '.features.video_calls // "false"')"
e2ee_enabled="$(read_config '.features.e2ee // "false"')"
rate_limit_disabled="$(read_config '.features.rate_limit_disabled // "false"')"
refresh_token_ttl_days="$(read_config '.features.refresh_token_ttl_days // 7')"
refresh_reuse_policy="$(read_config '.features.refresh_reuse_policy // "log_only"')"
xmpp_jwt_ttl="$(read_config '.features.xmpp_jwt_ttl // "10m"')"
xmpp_widget_jwt_ttl="$(read_config '.features.xmpp_widget_jwt_ttl // "100d"')"
livekit_url="$(read_config '.integrations.livekit.url // ""')"
livekit_api_key="$(read_config '.integrations.livekit.api_key // ""')"
livekit_api_secret="$(read_config '.integrations.livekit.api_secret // ""')"
daily_report_receivers="$(read_config '.integrations.analytics.daily_report_receivers // ""')"
monthly_report_receivers="$(read_config '.integrations.analytics.monthly_report_receivers // ""')"
report_daily_schedule="$(read_config '.integrations.analytics.daily_schedule // "30 8 * * *"')"
report_weekly_schedule="$(read_config '.integrations.analytics.weekly_schedule // "30 8 * * 1"')"
report_monthly_schedule="$(read_config '.integrations.analytics.monthly_schedule // "30 8 1 * *"')"
report_timezone="$(read_config '.integrations.analytics.timezone // ""')"
legal_contact_email="$(read_config '.integrations.analytics.legal_email // ""')"
alert_recipients="$(read_config '.integrations.analytics.alert_email // ""')"
translate_languages="$(read_config '.translate.languages // ""')"

update_env_var "POSTMARK_ENABLED" "$postmark_enabled"
update_env_var "POSTMARK_TOKEN" "$postmark_token"
update_env_var "POSTMARK_FROM_EMAIL" "$postmark_from_email"
update_env_var "POSTMARK_FROM_NAME" "$postmark_from_name"
update_env_var "POSTMARK_SUBJECT_PREFIX" "$postmark_subject_prefix"
update_env_var "ANALYTICS_ENABLED" "$analytics_enabled"
update_env_var "VIDEO_CALLS_ENABLED" "$video_calls_enabled"
update_env_var "E2EE_ENABLED" "$e2ee_enabled"
# Load-testing kill switch: disables all auth rate limiters when true. Default
# false (safe for prod). Set features.rate_limit_disabled: true only on a QA/load box.
update_env_var "RATE_LIMIT_DISABLED" "$rate_limit_disabled"
# Refresh-token rotation. reuse_policy stays log_only until every client refreshes
# through a single lock; see backend.env.template for what each value does.
update_env_var "REFRESH_TOKEN_TTL_DAYS" "$refresh_token_ttl_days"
update_env_var "REFRESH_REUSE_POLICY" "$refresh_reuse_policy"
# XMPP JWT lifetimes (jsonwebtoken duration syntax, e.g. 10m / 30m / 1h).
update_env_var "XMPP_JWT_TTL" "$xmpp_jwt_ttl"
update_env_var "XMPP_JWT_WIDGET_TTL" "$xmpp_widget_jwt_ttl"
# What the separately-installed translation server can translate into
# (deploy.yml `translate.languages`). force_ so clearing the list in deploy.yml
# actually clears it here - an emptied list must reach the database, otherwise
# get-config keeps advertising a translator the operator has removed.
# The API does not read this at request time: init-services.sh syncs it into
# Mongo, which is where get-config reads it from.
force_update_env_var "TRANSLATE_LANGUAGES" "$translate_languages"
update_env_var "LIVEKIT_URL" "$livekit_url"
# Video calls: only hand the backend its LiveKit credentials when the feature
# is enabled, so the call endpoints stay inert otherwise (chat.call.ts lazy-
# inits the RoomServiceClient from these WEBRTC_* vars; empty -> disabled).
if [ "$video_calls_enabled" = "true" ]; then
  update_env_var "WEBRTC_HOST" "$livekit_url"
  update_env_var "WEBRTC_API_KEY" "$livekit_api_key"
  update_env_var "WEBRTC_API_SECRET" "$livekit_api_secret"
else
  update_env_var "WEBRTC_HOST" ""
  update_env_var "WEBRTC_API_KEY" ""
  update_env_var "WEBRTC_API_SECRET" ""
fi

# Immutable audit logs -> S3 export job (features.immutable_logs).
# Force-written (empty included) so turning the flag off actually strips the
# AWS credentials from .deploy.env on the next update instead of leaving the
# previously persisted values behind for the next render to pick up.
immutable_logs_enabled="$(read_config '.features.immutable_logs // "false"')"
if [ "$immutable_logs_enabled" = "true" ]; then
  immutable_logs_interval_hours="$(read_config '.integrations.immutable_logs.interval_hours // 6')"
  immutable_logs_access_key_id="$(read_config '.integrations.immutable_logs.aws_access_key_id // ""')"
  immutable_logs_secret_access_key="$(read_config '.integrations.immutable_logs.aws_secret_access_key // ""')"
  immutable_logs_region="$(read_config '.integrations.immutable_logs.aws_region // ""')"
  immutable_logs_bucket="$(read_config '.integrations.immutable_logs.aws_s3_bucket_name // ""')"
else
  immutable_logs_enabled="false"
  immutable_logs_interval_hours=""
  immutable_logs_access_key_id=""
  immutable_logs_secret_access_key=""
  immutable_logs_region=""
  immutable_logs_bucket=""
fi
force_update_env_var "IMMUTABLE_LOGS_ENABLED" "$immutable_logs_enabled"
force_update_env_var "IMMUTABLE_LOGS_INTERVAL_HOURS" "$immutable_logs_interval_hours"
force_update_env_var "IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID" "$immutable_logs_access_key_id"
force_update_env_var "IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY" "$immutable_logs_secret_access_key"
force_update_env_var "IMMUTABLE_LOGS_AWS_REGION" "$immutable_logs_region"
force_update_env_var "IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME" "$immutable_logs_bucket"

# License (deploy.yml `license:`). Force-written so removing the key from
# deploy.yml clears it on the next update. key_file wins over key.
license_key="$(read_config '.license.key // ""')"
license_key_file="$(read_config '.license.key_file // ""')"
if [ -n "$license_key_file" ] && [ -f "$license_key_file" ]; then
  license_key="$(tr -d '[:space:]' < "$license_key_file")"
fi
license_key="$(printf '%s' "$license_key" | tr -d '[:space:]')"
license_call_home="$(read_config '.license.call_home | select(. != null)')"; license_call_home="${license_call_home:-true}"
license_server_url="$(read_config '.license.server_url // ""')"
license_grace_days="$(read_config '.license.grace_days // ""')"
force_update_env_var "ETHORA_LICENSE_KEY" "$license_key"
force_update_env_var "ETHORA_LICENSE_CALL_HOME" "$license_call_home"
force_update_env_var "ETHORA_LICENSE_SERVER_URL" "$license_server_url"
force_update_env_var "ETHORA_LICENSE_GRACE_DAYS" "$license_grace_days"

update_env_var "DAILY_REPORT_RECEIVERS" "$daily_report_receivers"
update_env_var "MONTHLY_REPORT_RECEIVERS" "$monthly_report_receivers"
update_env_var "REPORT_DAILY_SCHEDULE" "$report_daily_schedule"
update_env_var "REPORT_WEEKLY_SCHEDULE" "$report_weekly_schedule"
update_env_var "REPORT_MONTHLY_SCHEDULE" "$report_monthly_schedule"
update_env_var "REPORT_TIMEZONE" "$report_timezone"
update_env_var "LEGAL_CONTACT_EMAIL" "$legal_contact_email"
update_env_var "ALERT_RECIPIENTS" "$alert_recipients"

# Swagger feature flags (used by setup-env.sh -> backend .env)
# Default: swagger ON (public), swagger_internal OFF.
enable_swagger="$(read_config '.features.swagger | select(. != null)')"; enable_swagger="${enable_swagger:-true}"
enable_swagger_internal="$(read_config '.features.swagger_internal // "false"')"

update_env_var "ENABLE_SWAGGER" "$enable_swagger"
update_env_var "ENABLE_SWAGGER_INTERNAL" "$enable_swagger_internal"

# Email TLD validation policy.
# update_env_var skips empty values, which would mean an operator could never
# clear the allowlist back to empty via deploy.yml. We use a sentinel + direct
# write here so an explicit "" in deploy.yml is honoured. The validation mode
# itself defaults to "off" (matches helper default and install.sh default).
email_tld_validation="$(read_config '.services.backend.email_tld_validation // "off"')"
email_tld_allowlist="$(read_config '.services.backend.email_tld_allowlist // ""')"

update_env_var "EMAIL_TLD_VALIDATION" "$email_tld_validation"
# Force-write the allowlist (incl. empty) so the .env always reflects deploy.yml.
{
    tmp_email_env="$(mktemp)"
    grep -v "^export EMAIL_TLD_ALLOWLIST=" "$ENV_FILE" > "$tmp_email_env" 2>/dev/null || true
    printf 'export EMAIL_TLD_ALLOWLIST="%s"\n' "$(escape_env_value "$email_tld_allowlist")" >> "$tmp_email_env"
    cat "$tmp_email_env" > "$ENV_FILE"
    rm -f "$tmp_email_env"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    if [ -n "${SUDO_USER:-}" ] && [ "${EUID:-$(id -u)}" -eq 0 ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        chown "$SUDO_USER":"$SUDO_USER" "$ENV_FILE" 2>/dev/null || chown "$SUDO_USER" "$ENV_FILE" 2>/dev/null || true
    fi
}

# SSL
ssl_method="$(read_config '.ssl.method')"
ssl_email="$(read_config '.ssl.email')"
update_env_var "SSL_METHOD" "$ssl_method"
update_env_var "SSL_EMAIL" "$ssl_email"

# Ports / services
backend_port="$(read_config '.services.backend.port')"
node_env="$(read_config '.services.backend.node_env // "production"')"
api_client_max_body_size="$(read_config '.services.backend.client_max_body_size // "50M"')"
playground_enabled="$(read_config '.services.playground.enabled | select(. != null)')"; playground_enabled="${playground_enabled:-true}"
playground_port="$(read_config '.services.playground.port // 3020')"
# Widget enabled: respect explicit value; otherwise default to features.ai_service
# so the admin panel's AI Widget tab gets a usable embed URL whenever AI is on.
# Read raw (no `//`) since yq's alternative also falls through on explicit false,
# which would lose the operator's intent to disable widget on an AI-on install.
widget_enabled_raw="$(read_config '.services.widget.enabled')"
ai_feature_for_widget="$(read_config '.features.ai_service // "false"')"
if [ "$widget_enabled_raw" = "true" ] || [ "$widget_enabled_raw" = "false" ]; then
    widget_enabled="$widget_enabled_raw"
else
    widget_enabled="$ai_feature_for_widget"
fi
widget_script_version="$(read_config '.services.widget.script_version // ""')"
# Hosted MCP server: explicit true/false wins; missing block means off.
mcp_enabled_raw="$(read_config '.services.mcp.enabled')"
if [ "$mcp_enabled_raw" = "true" ] || [ "$mcp_enabled_raw" = "false" ]; then
    mcp_enabled="$mcp_enabled_raw"
else
    mcp_enabled="false"
fi
mcp_port="$(read_config '.services.mcp.port // 3030')"
mcp_oauth_issuer_override="$(read_config '.services.mcp.oauth_issuer // ""')"
[ "$mcp_oauth_issuer_override" = "null" ] && mcp_oauth_issuer_override=""
mcp_dangerous_raw="$(read_config '.services.mcp.enable_dangerous_tools')"
if [ "$mcp_dangerous_raw" = "false" ]; then
    mcp_enable_dangerous_tools="false"
else
    mcp_enable_dangerous_tools="true"
fi
hosted_apps_enabled="$(read_config '.services.hosted_apps.enabled // "false"')"
uptime_enabled="$(read_config '.services.uptime.enabled')"
uptime_port="$(read_config '.services.uptime.port // 8099')"
uptime_postgres_port="$(read_config '.services.uptime.postgres_port // 5433')"
uptime_public_enabled="$(read_config '.services.uptime.public_enabled | select(. != null)')"; uptime_public_enabled="${uptime_public_enabled:-true}"
uptime_ethora_enabled="$(read_config '.services.uptime.ethora_enabled // "false"')"
push_enabled="$(read_config '.services.push.enabled | select(. != null)')"; push_enabled="${push_enabled:-true}"
push_port="$(read_config '.services.push.port // 8098')"
push_common_post_url="$(read_config '.services.push.common_post_url // ""')"
push_voip_post_url="$(read_config '.services.push.voip_post_url // ""')"
push_platform_project_id="$(read_config '.services.push.platform_project_id // ""')"
push_platform_daily_quota="$(read_config '.services.push.platform_daily_quota // 1000')"
push_gateway_url="$(read_config '.services.push.gateway_url // ""')"
push_gateway_token="$(read_config '.services.push.gateway_token // ""')"
# Centrifugo non-secret settings refresh from deploy.yml on every update.
# Secrets (api_key/hmac_secret/admin_*) are intentionally NOT refreshed when blank in
# deploy.yml so auto-generated values persisted in .deploy.env are preserved across updates.
centrifugo_enabled="$(read_config '.services.centrifugo.enabled | select(. != null)')"; centrifugo_enabled="${centrifugo_enabled:-true}"
centrifugo_port="$(read_config '.services.centrifugo.port // 8001')"
centrifugo_timeout_ms="$(read_config '.services.centrifugo.timeout_ms // 2000')"
centrifugo_api_key="$(read_config '.services.centrifugo.api_key // ""')"
centrifugo_hmac_secret="$(read_config '.services.centrifugo.hmac_secret // ""')"
centrifugo_admin_password="$(read_config '.services.centrifugo.admin_password // ""')"
centrifugo_admin_secret="$(read_config '.services.centrifugo.admin_secret // ""')"
ai_service_enabled="$(read_config '.services.ai_service.enabled // "false"')"
ai_service_port="$(read_config '.services.ai_service.port // 8013')"
docs_parse_enabled="$(read_config '.services.docs_parse_service.enabled // "false"')"
docs_parse_port="$(read_config '.services.docs_parse_service.port // 8201')"
ai_postgres_port="$(read_config '.services.ai_service.postgres_port // 5434')"
ai_postgres_db="$(read_config '.services.ai_service.postgres_database // "ai_service_embeddings_db"')"
ai_postgres_user="$(read_config '.services.ai_service.postgres_user // "ai_embeddings"')"
ai_postgres_password="$(read_config '.services.ai_service.postgres_password // ""')"
ai_pg_url_override="$(read_config '.services.ai_service.pg_url // ""')"

update_env_var "BACKEND_PORT" "$backend_port"
update_env_var "NODE_ENV" "$node_env"
update_env_var "API_CLIENT_MAX_BODY_SIZE" "$api_client_max_body_size"
update_env_var "PLAYGROUND_ENABLED" "$playground_enabled"
update_env_var "PLAYGROUND_PORT" "$playground_port"
update_env_var "WIDGET_ENABLED" "$widget_enabled"
update_env_var "WIDGET_SCRIPT_VERSION" "$widget_script_version"
update_env_var "MCP_ENABLED" "$mcp_enabled"
update_env_var "MCP_PORT" "$mcp_port"
update_env_var "MCP_OPENAI_APPS_CHALLENGE" "$(yq eval '.services.mcp.openai_apps_challenge // ""' "$CONFIG_FILE" 2>/dev/null | sed 's/^null$//')"
update_env_var "MCP_ENABLE_DANGEROUS_TOOLS" "$mcp_enable_dangerous_tools"
# OAuth 2.1 issuer (public API base) for the backend AS and the MCP resource
# metadata: derived when the hosted MCP server is on, overridable per config.
if [ -n "$mcp_oauth_issuer_override" ]; then
    oauth_issuer="${mcp_oauth_issuer_override%/}"
elif [ "$mcp_enabled" = "true" ] && [ "$api_domain" = "localhost" ]; then
    oauth_issuer="http://localhost:${backend_port}"
elif [ "$mcp_enabled" = "true" ] && [ -n "$api_domain" ]; then
    oauth_issuer="https://${api_domain}"
else
    oauth_issuer=""
fi
update_env_var "OAUTH_ISSUER" "$oauth_issuer"
# Per-IP auth limiter ceilings: explicit positive integers pass through; blank
# falls back to raised login/signup ceilings when the hosted MCP server is on
# (shared vendor egress IPs), else to the backend defaults (empty).
read_rate_limit() {
    local raw
    raw="$(read_config "$1")"
    if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then echo "$raw"; else echo "$2"; fi
}
rate_limit_auth_login_max="$(read_rate_limit '.rate_limits.auth_login_max' "$([ "$mcp_enabled" = "true" ] && echo 120 || echo "")")"
rate_limit_auth_signup_max="$(read_rate_limit '.rate_limits.auth_signup_max' "$([ "$mcp_enabled" = "true" ] && echo 30 || echo "")")"
rate_limit_auth_password_max="$(read_rate_limit '.rate_limits.auth_password_max' "")"
rate_limit_auth_refresh_max="$(read_rate_limit '.rate_limits.auth_refresh_max' "")"
update_env_var "RATE_LIMIT_AUTH_LOGIN_MAX" "$rate_limit_auth_login_max"
update_env_var "RATE_LIMIT_AUTH_SIGNUP_MAX" "$rate_limit_auth_signup_max"
update_env_var "RATE_LIMIT_AUTH_PASSWORD_MAX" "$rate_limit_auth_password_max"
update_env_var "RATE_LIMIT_AUTH_REFRESH_MAX" "$rate_limit_auth_refresh_max"
# Feedback channel: destinations are optional (blank = store only), and the
# retention is read raw because `0` (keep forever) is a meaningful value that
# yq's `//` default would swallow.
feedback_retention_raw="$(read_config '.feedback.retention_days')"
if [[ "$feedback_retention_raw" =~ ^[0-9]+$ ]]; then
    feedback_retention_days="$feedback_retention_raw"
else
    feedback_retention_days="180"
fi
update_env_var "FEEDBACK_EMAIL_TO" "$(read_config '.feedback.email_to')"
update_env_var "FEEDBACK_SLACK_WEBHOOK_URL" "$(read_config '.feedback.slack_webhook_url')"
update_env_var "FEEDBACK_RETENTION_DAYS" "$feedback_retention_days"
update_env_var "RATE_LIMIT_FEEDBACK_MAX" "$(read_rate_limit '.rate_limits.feedback_max' "")"
update_env_var "RATE_LIMIT_FEEDBACK_ANON_MAX" "$(read_rate_limit '.rate_limits.feedback_anon_max' "")"
update_env_var "HOSTED_APPS_ENABLED" "$hosted_apps_enabled"
update_env_var "UPTIME_ENABLED" "$uptime_enabled"
update_env_var "UPTIME_PORT" "$uptime_port"
update_env_var "UPTIME_POSTGRES_PORT" "$uptime_postgres_port"
update_env_var "UPTIME_PUBLIC_ENABLED" "$uptime_public_enabled"
update_env_var "UPTIME_ETHORA_ENABLED" "$uptime_ethora_enabled"
update_env_var "PUSH_ENABLED" "$push_enabled"
update_env_var "PUSH_PORT" "$push_port"
update_env_var "PUSH_COMMON_POST_URL" "$push_common_post_url"
update_env_var "PUSH_VOIP_POST_URL" "$push_voip_post_url"
update_env_var "PUSH_PLATFORM_PROJECT_ID" "$push_platform_project_id"
update_env_var "PUSH_PLATFORM_DAILY_QUOTA" "$push_platform_daily_quota"
update_env_var "PUSH_GATEWAY_URL" "$push_gateway_url"
update_env_var "PUSH_GATEWAY_TOKEN" "$push_gateway_token"
update_env_var "CENTRIFUGO_ENABLED" "$centrifugo_enabled"
update_env_var "CENTRIFUGO_PORT" "$centrifugo_port"
update_env_var "CENTRIFUGO_TIMEOUT_MS" "$centrifugo_timeout_ms"
# update_env_var skips empty values, so blank YAML entries do NOT overwrite persisted secrets.
update_env_var "CENTRIFUGO_API_KEY" "$centrifugo_api_key"
update_env_var "CENTRIFUGO_HMAC_SECRET" "$centrifugo_hmac_secret"
update_env_var "CENTRIFUGO_ADMIN_PASSWORD" "$centrifugo_admin_password"
update_env_var "CENTRIFUGO_ADMIN_SECRET" "$centrifugo_admin_secret"
update_env_var "AI_SERVICE_ENABLED" "$ai_service_enabled"
update_env_var "AI_SERVICE_PORT" "$ai_service_port"
update_env_var "DOCS_PARSE_ENABLED" "$docs_parse_enabled"
update_env_var "DOCS_PARSE_PORT" "$docs_parse_port"
update_env_var "AI_POSTGRES_PORT" "$ai_postgres_port"
update_env_var "AI_POSTGRES_DB" "$ai_postgres_db"
update_env_var "AI_POSTGRES_USER" "$ai_postgres_user"
update_env_var "AI_POSTGRES_PASSWORD" "$ai_postgres_password"
update_env_var "AI_PG_URL" "$ai_pg_url_override"

# AI provider settings
ai_api_url="$(read_config '.ai.ai_api_url // "https://api.openai.com/v1"')"
ai_api_key="$(read_config '.ai.ai_api_key // ""')"
ai_chat_model="$(read_config '.ai.chat_model // "gpt-4.1-mini"')"
ai_embedding_model="$(read_config '.ai.embedding_model // "text-embedding-3-small"')"
if [ -z "$ai_api_key" ]; then
  ai_api_key="$(read_config '.ai.openai_api_key // ""')"
fi
update_env_var "AI_API_URL" "$ai_api_url"
update_env_var "AI_API_KEY" "$ai_api_key"
update_env_var "AI_CHAT_MODEL" "$ai_chat_model"
update_env_var "AI_EMBEDDING_MODEL" "$ai_embedding_model"

# Firebase web config for base app social login
firebase_web_api_key="$(read_config '.integrations.firebase.web.api_key // ""')"
firebase_web_auth_domain="$(read_config '.integrations.firebase.web.auth_domain // ""')"
firebase_web_project_id="$(read_config '.integrations.firebase.web.project_id // ""')"
firebase_web_storage_bucket="$(read_config '.integrations.firebase.web.storage_bucket // ""')"
firebase_web_messaging_sender_id="$(read_config '.integrations.firebase.web.messaging_sender_id // ""')"
firebase_web_app_id="$(read_config '.integrations.firebase.web.app_id // ""')"
firebase_web_measurement_id="$(read_config '.integrations.firebase.web.measurement_id // ""')"
firebase_web_vapid_public_key="$(read_config '.integrations.firebase.web.vapid_public_key // ""')"
update_env_var "FIREBASE_WEB_API_KEY" "$firebase_web_api_key"
update_env_var "FIREBASE_WEB_AUTH_DOMAIN" "$firebase_web_auth_domain"
update_env_var "FIREBASE_WEB_PROJECT_ID" "$firebase_web_project_id"
update_env_var "FIREBASE_WEB_STORAGE_BUCKET" "$firebase_web_storage_bucket"
update_env_var "FIREBASE_WEB_MESSAGING_SENDER_ID" "$firebase_web_messaging_sender_id"
update_env_var "FIREBASE_WEB_APP_ID" "$firebase_web_app_id"
update_env_var "FIREBASE_WEB_MEASUREMENT_ID" "$firebase_web_measurement_id"
update_env_var "FIREBASE_WEB_VAPID_PUBLIC_KEY" "$firebase_web_vapid_public_key"

# Base app
base_app_display_name="$(read_config '.base_app.display_name // "Ethora"')"
base_app_domain_name="$(read_config '.base_app.domain_name // ""')"
if [ -z "$base_app_domain_name" ]; then
  if [ "$web_domain" == "localhost" ] || [ -z "$web_domain" ]; then
    base_app_domain_name="ethora"
  else
    base_app_domain_name="$(echo "$web_domain" | cut -d'.' -f1)"
  fi
fi

update_env_var "BASE_APP_DISPLAY_NAME" "$base_app_display_name"
update_env_var "BASE_APP_DOMAIN_NAME" "$base_app_domain_name"

# Ejabberd tracking URLs (derive if not provided)
track_member_url="$(read_config '.services.ejabberd.track_member_url // ""')"
track_last_message_url="$(read_config '.services.ejabberd.track_last_message_url // ""')"
track_message_url="$(read_config '.services.ejabberd.track_message_url // ""')"
history_access_url="$(read_config '.services.ejabberd.history_access_url // ""')"
message_audit_url="$(read_config '.services.ejabberd.message_audit_url // ""')"
# Optional mod_translate endpoint. Unlike the track URLs it is NOT derived from the
# domain (translate service isn't present on every install); empty keeps the repo default.
translate_url="$(read_config '.services.ejabberd.translate_url // ""')"
# localhost branches below use host.docker.internal, not localhost: ejabberd runs
# in a container, where "localhost" is the container itself, so a plain localhost
# URL is unreachable from the module. Matches what install.sh derives, so a
# refresh on a local install doesn't rewrite a working URL into a dead one.
if [ -z "$track_member_url" ] && [ -n "$api_domain" ]; then
  if [ "$api_domain" == "localhost" ]; then
    track_member_url="http://host.docker.internal:${backend_port:-8080}/v1/chats/track-member"
  else
    track_member_url="https://${api_domain}/v1/chats/track-member"
  fi
fi
if [ -z "$track_last_message_url" ] && [ -n "$api_domain" ]; then
  if [ "$api_domain" == "localhost" ]; then
    track_last_message_url="http://host.docker.internal:${backend_port:-8080}/v1/chats/track-last-message"
  else
    track_last_message_url="https://${api_domain}/v1/chats/track-last-message"
  fi
fi
if [ -z "$track_message_url" ] && [ -n "$api_domain" ]; then
  if [ "$api_domain" == "localhost" ]; then
    track_message_url="http://host.docker.internal:${backend_port:-8080}/v1/chats/archive-message"
  else
    track_message_url="https://${api_domain}/v1/chats/archive-message"
  fi
fi
if [ -z "$history_access_url" ] && [ -n "$api_domain" ]; then
  if [ "$api_domain" == "localhost" ]; then
    history_access_url="http://host.docker.internal:${backend_port:-8080}/v1/chats/history-access"
  else
    history_access_url="https://${api_domain}/v1/chats/history-access"
  fi
fi
if [ -z "$message_audit_url" ] && [ -n "$api_domain" ]; then
  if [ "$api_domain" == "localhost" ]; then
    message_audit_url="http://host.docker.internal:${backend_port:-8080}/v1/chats/message-audit"
  else
    message_audit_url="https://${api_domain}/v1/chats/message-audit"
  fi
fi
update_env_var "TRACK_MEMBER_URL" "$track_member_url"
update_env_var "TRACK_LAST_MESSAGE_URL" "$track_last_message_url"
update_env_var "TRACK_MESSAGE_URL" "$track_message_url"
update_env_var "HISTORY_ACCESS_URL" "$history_access_url"
update_env_var "MESSAGE_AUDIT_URL" "$message_audit_url"
update_env_var "TRANSLATE_URL" "$translate_url"

# Ejabberd config file selection (for docker compose mount).
if [ -n "$xmpp_domain" ] && [ "$xmpp_domain" != "localhost" ]; then
  update_env_var "EJABBERD_CONFIG_NAME" "ejabberd-prod.yml"
else
  update_env_var "EJABBERD_CONFIG_NAME" "ejabberd-local.yml"
fi
