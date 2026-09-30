#!/bin/sh
# frontend-start.sh - entrypoint of the frontend service in the compose bundle.
#
# The ethora-frontend image renders /config.js and the CSP from the VITE_*
# variables in its environment. Export the frontend.env the config service
# rendered (plain KEY=value lines, taken literally, the same as the docker
# --env-file that deploy/scripts/frontend-from-image.sh produces), then run
# the image's own entrypoint.
set -eu

ENV_FILE="${ETHORA_FRONTEND_ENV_FILE:-/ethora/config/frontend/frontend.env}"
[ -r "$ENV_FILE" ] || { echo "[frontend] $ENV_FILE missing; the config service did not run" >&2; exit 1; }

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *'{{'*) continue ;;
    [A-Za-z_]*=*)
      key="${line%%=*}"
      case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
      export "$line"
      ;;
  esac
done < "$ENV_FILE"

# One-origin installs (PUBLIC_URL) carry __ETHORA_ORIGIN__ / __ETHORA_ORIGIN_WS__
# in their URLs. Render as `serve` would, then append a resolver to config.js
# that replaces them with the page's own origin, so the app works under
# whatever address it was opened by, then run nginx as `serve` does.
if [ "${1:-serve}" = "serve" ] && env | grep -q '^VITE_[A-Z_]*=.*__ETHORA_ORIGIN'; then
  html="${HTML_DIR:-/usr/share/nginx/html}"
  /usr/local/bin/ethora-frontend render "$html"
  cat >> "$html/config.js" <<'JS'
// compose bundle, one-origin install: URLs follow the address in the browser.
(function (c, l) {
  var o = l.origin, w = o.replace(/^http/, "ws");
  for (var k in c) {
    if (typeof c[k] === "string") {
      c[k] = c[k].split("__ETHORA_ORIGIN_WS__").join(w).split("__ETHORA_ORIGIN__").join(o);
    }
  }
})(window.__ETHORA_CONFIG__ = window.__ETHORA_CONFIG__ || {}, window.location);
JS
  exec nginx -g 'daemon off;'
fi

exec /usr/local/bin/ethora-frontend "$@"
