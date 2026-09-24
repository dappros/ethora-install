#!/bin/sh
# Ethora AI module image entrypoint.
#
#   ethora-ai ai-service            agent runtime (PORT from /app/ai-service/.env or env)
#   ethora-ai docs-parse            document parsing service
#   ethora-ai widget-export [/out]  render the AI chat widget bundle for this
#                                   install into /out (host nginx serves it)
#   ethora-ai widget-render [dir]   same, in place
#
# The widget bundle is built once with placeholders; rendering substitutes
# the VITE_WIDGET_* values from the environment (the rendered
# ethora-ai-chat-widget/.env.production.local, passed as --env-file) and
# writes the assistant.js / assistant<version>.js copies the platform serves.
set -eu

WIDGET_DIR="${WIDGET_DIR:-/app/widget}"

render_widget() {
  dir="$1"
  for key in VITE_WIDGET_API_URL VITE_WIDGET_XMPP_DOMAIN VITE_WIDGET_XMPP_WS_URL VITE_WIDGET_XMPP_CONFERENCE VITE_WIDGET_QR_URL; do
    eval "val=\${$key:-}"
    # '|' is safe as a delimiter: URLs and hostnames never contain it.
    find "$dir" -type f \( -name '*.js' -o -name '*.map' -o -name '*.html' \) -exec sed -i "s|__ETHORA_${key#VITE_}__|$val|g" {} +
  done
  if grep -rq "__ETHORA_WIDGET_" "$dir" 2>/dev/null; then
    echo "[ethora-ai] warning: unreplaced widget placeholders remain" >&2
  fi
  if [ -f "$dir/ethora_assistant.js" ]; then
    cp -f "$dir/ethora_assistant.js" "$dir/assistant.js"
    [ -n "${WIDGET_SCRIPT_VERSION:-}" ] && cp -f "$dir/ethora_assistant.js" "$dir/assistant${WIDGET_SCRIPT_VERSION}.js"
    if [ -f "$dir/ethora_assistant.js.map" ]; then
      cp -f "$dir/ethora_assistant.js.map" "$dir/assistant.js.map"
      [ -n "${WIDGET_SCRIPT_VERSION:-}" ] && cp -f "$dir/ethora_assistant.js.map" "$dir/assistant${WIDGET_SCRIPT_VERSION}.js.map"
    fi
  fi
  echo "[ethora-ai] widget rendered into $dir (api=${VITE_WIDGET_API_URL:-unset}, version=${WIDGET_SCRIPT_VERSION:-none})"
}

cmd="${1:-ai-service}"
case "$cmd" in
  ai-service)
    exec node /app/loader.js /app/ai-service ./dist/server ;;
  docs-parse)
    exec node /app/loader.js /app/docs-parse ./index ;;
  widget-export)
    out="${2:-/out}"; mkdir -p "$out"; cp -R "$WIDGET_DIR"/. "$out"/; render_widget "$out" ;;
  widget-render)
    render_widget "${2:-$WIDGET_DIR}" ;;
  *)
    exec "$@" ;;
esac
