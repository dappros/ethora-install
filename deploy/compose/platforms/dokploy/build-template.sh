#!/usr/bin/env bash
# build-template.sh - generate the Dokploy blueprint of Ethora Core
# (docker-compose.yml and template.toml in this directory) from the bundle.
#
#   docker-compose.yml  the bundle's deploy/compose/docker-compose.yml without
#                       the bundled proxy (Dokploy's Traefik routes the four
#                       hosts, see template.toml) and with ./scripts and
#                       ./templates read from ../files/, where Dokploy writes
#                       a template's mounts.
#   template.toml       template.in.toml with every line
#                         @content <path relative to deploy/compose>
#                       replaced by that file as a TOML literal string
#                       (content = '''...'''), so the template carries the
#                       same scripts the bundle runs. Literal strings keep
#                       backslashes; Dokploy still replaces its own ${helper}
#                       names inside mount content, so no script may contain
#                       ${domain}, ${password}, ${username} and the like.
#
# Checked by deploy/scripts/tests/compose-bundle.test.sh (regenerate, expect
# no diff).
#   run: deploy/compose/platforms/dokploy/build-template.sh [--check]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "$HERE/../.." && pwd)"
IN="$HERE/template.in.toml"
OUT_TOML="$HERE/template.toml"
OUT_YML="$HERE/docker-compose.yml"

render_compose() {
  cat <<'HDR'
# Ethora Core as a Dokploy template. GENERATED FILE: edit the bundle's
# deploy/compose/docker-compose.yml and run build-template.sh.
#
# Same services and start order as the bundle (config -> databases -> xmpp ->
# api, jobs -> init -> frontend), without the bundled Caddy: Dokploy's Traefik
# routes the four public hosts declared in template.toml. The scripts and
# templates are the template's mounts, which Dokploy writes under ../files/.
# Every variable comes from the .env Dokploy writes next to this file
# (template.toml, [config] env). See README.md in this directory.

HDR
  sed -n '/^x-logging:/,$p' "$BUNDLE/docker-compose.yml" \
    | sed -e '/^  # -* caddy --$/,/^volumes:$/{/^volumes:$/!d}' \
          -e '/^  caddy-data:/d' -e '/^  caddy-config:/d' -e '/^      - \.\/Caddyfile:/d' \
          -e 's#\./scripts:#../files/scripts:#g; s#\./templates:#../files/templates:#g'
}

render_toml() {
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^@content[[:space:]]+([^[:space:]]+)$ ]]; then
      f="$BUNDLE/${BASH_REMATCH[1]}"
      [ -f "$f" ] || { echo "[build-template] $f not found" >&2; exit 1; }
      grep -q "'''" "$f" && { echo "[build-template] $f contains ''' and cannot be a TOML literal string" >&2; exit 1; }
      if grep -qE '\$\{(domain|base64|password|hash|uuid|randomPort|timestamp|timestampms|timestamps|jwt|email|username)(:[^}]*)?\}' "$f"; then
        echo "[build-template] $f contains a Dokploy helper name (\${domain}, \${password}, ...); it would be replaced at deploy time" >&2; exit 1
      fi
      printf "content = '''\n"
      cat "$f"
      [ -n "$(tail -c 1 "$f")" ] && echo
      printf "'''\n"
    else
      printf '%s\n' "$line"
    fi
  done < "$IN"
}

if [ "${1:-}" = "--check" ]; then
  diff -u "$OUT_YML" <(render_compose) && diff -u "$OUT_TOML" <(render_toml) && echo "[build-template] $OUT_YML and $OUT_TOML are up to date"
else
  render_compose > "$OUT_YML.tmp" && mv "$OUT_YML.tmp" "$OUT_YML"
  render_toml > "$OUT_TOML.tmp" && mv "$OUT_TOML.tmp" "$OUT_TOML"
  echo "[build-template] wrote $OUT_YML ($(wc -c < "$OUT_YML") bytes) and $OUT_TOML ($(wc -c < "$OUT_TOML") bytes)"
fi
