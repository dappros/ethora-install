#!/usr/bin/env bash
# report-config-gaps.sh - end-of-deploy configuration gap reporter.
#
# Advisory only: ALWAYS exits 0 so it never blocks or fails a deploy. Its job
# is to collect, in one place at the very end of an install/update, the config
# the deploy expected but did not get - so the operator sees the whole list and
# can fix it next time instead of discovering gaps one crash at a time.
#
# It reports three tiers, most-actionable first:
#   [1] UNRESOLVED   template placeholders ({{X}} or X_PLACEHOLDER) that survived
#                    into a rendered .env - i.e. the deploy declared a value and
#                    never filled it.
#   [2] INSECURE     known insecure default secrets still present in a live file
#                    (e.g. the shared placeholder XMPP secret). Never prints the
#                    value - only the key name and file.
#   [3] CODE-REF     env keys hard-referenced in deployed code (no inline
#                    `||`/`??` default) that are absent from the matching .env.
#                    Many may be optional; this is a review list, not an error.
#
# Reads ROOT_DIR / DEPLOY_DIR from the environment (exported by install.sh /
# update.sh) and infers them if run standalone. Skips any file/dir not present.

set -uo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
ROOT_DIR="${ROOT_DIR:-$(cd "$DEPLOY_DIR/.." 2>/dev/null && pwd)}"
# Set REPORT_SKIP_CODE_SCAN=1 to skip tier 3 (the code reference sweep).
SKIP_CODE="${REPORT_SKIP_CODE_SCAN:-0}"

if [ -t 1 ]; then RED=$'\033[0;31m'; YEL=$'\033[1;33m'; GRN=$'\033[0;32m'; CYN=$'\033[0;36m'; BLD=$'\033[1m'; NC=$'\033[0m'
else RED=; YEL=; GRN=; CYN=; BLD=; NC=; fi

# label:rendered-env-path  (only those that exist are scanned)
ENV_MAP=(
  "backend:$ROOT_DIR/ethora-backend/services/api/.env"
  "frontend:$ROOT_DIR/ethora-app-reactjs/.env.production"
  "ai-service:$ROOT_DIR/ethora-backend/services/ai/ai-service/.env"
  "docs-parse:$ROOT_DIR/ethora-backend/services/ai/docs-parse/.env"
  "push:$ROOT_DIR/ethora-backend/services/push/.env"
  "crawler:$DEPLOY_DIR/generated/crawler/crawler.env"
  "uptime:$ROOT_DIR/ethora-uptime/.env"
  "widget:$ROOT_DIR/ethora-ai-chat-widget/.env.production"
)

# label:source-dir:kind  (kind=node -> process.env ; kind=vite -> import.meta.env)
CODE_MAP=(
  "backend:$ROOT_DIR/ethora-backend/services/api/src:node"
  "push:$ROOT_DIR/ethora-backend/services/push/src:node"
  "ai-service:$ROOT_DIR/ethora-backend/services/ai/ai-service/src:node"
  "frontend:$ROOT_DIR/ethora-app-reactjs/src:vite"
)

# Known insecure/default secret values that must never survive into a live file.
# Matched case-sensitively; only the KEY and file are ever printed, never the value.
INSECURE_RE='supersecretsupersecetABC|CHANGEME|change-me|REPLACE_ME|your-secret-here|password123|root123'

# Env names that are ambient/runtime, not deploy config - excluded from tier 3.
DENYLIST_RE='^(NODE_ENV|PORT|PATH|HOME|PWD|USER|SHELL|TZ|LANG|LC_|TERM|HOSTNAME|npm_|CI|TMPDIR|PM2_|VITE_CJS_|SSL_CERT|NODE_OPTIONS|NODE_TLS)'

placeholders=(); insecure=(); coderefs=()

scan_env() { # label path
  local label="$1" f="$2"; [ -f "$f" ] || return 0
  local m
  while IFS= read -r m; do [ -n "$m" ] && placeholders+=("$label|$m"); done < <(
    grep -noE '\{\{[A-Za-z0-9_]+\}\}|[A-Z][A-Z0-9_]*_PLACEHOLDER' "$f" 2>/dev/null | sort -u)
  # Insecure defaults: report only the KEY (text before '='), never the value.
  local line key
  while IFS= read -r line; do
    key="$(printf '%s' "$line" | sed -E 's/^[0-9]+:([A-Za-z0-9_]+)=.*/\1/;t;s/.*/(inline)/')"
    insecure+=("$label|$key")
  done < <(grep -nE "$INSECURE_RE" "$f" 2>/dev/null)
}

scan_code() { # label dir kind
  local label="$1" dir="$2" kind="$3"; [ -d "$dir" ] || return 0
  local envf="" pair
  for pair in "${ENV_MAP[@]}"; do [ "${pair%%:*}" = "$label" ] && envf="${pair#*:}"; done
  [ -f "$envf" ] || return 0
  local present; present="$(grep -oE '^[A-Za-z0-9_]+=' "$envf" 2>/dev/null | tr -d '=' | sort -u)"
  local refs
  if [ "$kind" = vite ]; then
    # import.meta.env.VITE_X  (Vite inlines at build; still useful to flag gaps)
    refs="$(grep -rhoE 'import\.meta\.env\.[A-Za-z0-9_]+' "$dir" 2>/dev/null | sed -E 's/.*env\.//' | sort -u)"
  else
    # process.env.X or process.env['X'] on lines WITHOUT an inline ||/?? default
    refs="$(grep -rhE "process\.env" "$dir" 2>/dev/null | grep -vE '\|\||\?\?' \
      | grep -oE "process\.env(\.[A-Za-z0-9_]+|\[['\"][A-Za-z0-9_]+['\"]\])" \
      | sed -E "s/.*env\.//; s/.*\[['\"]//; s/['\"]\].*//" | sort -u)"
  fi
  local k
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    printf '%s\n' "$k" | grep -qE "$DENYLIST_RE" && continue
    printf '%s\n' "$present" | grep -qxF "$k" && continue
    coderefs+=("$label|$k")
  done <<< "$refs"
}

for pair in "${ENV_MAP[@]}"; do scan_env "${pair%%:*}" "${pair#*:}"; done
[ "$SKIP_CODE" = 1 ] || for t in "${CODE_MAP[@]}"; do IFS=: read -r l d k <<< "$t"; scan_code "$l" "$d" "$k"; done

total=$(( ${#placeholders[@]} + ${#insecure[@]} + ${#coderefs[@]} ))

echo
echo "${BLD}========================================================${NC}"
echo "${BLD} Configuration gap report${NC}"
echo "${BLD}========================================================${NC}"
if [ "$total" -eq 0 ]; then
  echo "${GRN}No configuration gaps detected.${NC}"
  echo "${BLD}========================================================${NC}"
  exit 0
fi

if [ "${#placeholders[@]}" -gt 0 ]; then
  echo "${RED}[1] UNRESOLVED placeholders (${#placeholders[@]}) - a declared value was never filled; the service will misbehave:${NC}"
  printf '%s\n' "${placeholders[@]}" | sort -u | sed -E 's/^([^|]+)\|[0-9]+:(.*)/    \1: \2/'
  echo
fi
if [ "${#insecure[@]}" -gt 0 ]; then
  echo "${RED}[2] INSECURE default secrets still in place (${#insecure[@]}) - rotate before/at this deploy:${NC}"
  printf '%s\n' "${insecure[@]}" | sort -u | sed -E 's/^([^|]+)\|(.*)/    \1: \2 (value hidden)/'
  echo
fi
if [ "${#coderefs[@]}" -gt 0 ]; then
  echo "${YEL}[3] Referenced in code, not set in .env (${#coderefs[@]}) - review; many are optional or have code defaults:${NC}"
  printf '%s\n' "${coderefs[@]}" | sort -u | sed -E 's/^([^|]+)\|(.*)/    \1: \2/' | head -60
  [ "${#coderefs[@]}" -gt 60 ] && echo "    ... (${#coderefs[@]} total; showing first 60)"
  echo
fi
echo "${CYN}Fix in deploy/config/deploy.yml, then re-run setup-env.sh (or the installer/updater).${NC}"
echo "${CYN}Tiers [1] and [2] are actionable now; [2] is a security issue. Re-run to confirm clean.${NC}"
echo "${BLD}========================================================${NC}"
exit 0
