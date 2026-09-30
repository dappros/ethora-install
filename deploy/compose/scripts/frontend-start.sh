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
# in their URLs: after the image renders the bundle, a resolver is appended to
# config.js that replaces them with the page's own origin, so the app works
# under whatever address it was opened by.
render_bundle() { # render_bundle <html dir>
  /usr/local/bin/ethora-frontend render "$1"
  env | grep -q '^VITE_[A-Z_]*=.*__ETHORA_ORIGIN' || return 0
  cat >> "$1/config.js" <<'JS'
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
}

case "${1:-serve}" in
  # `render <dir>`: render a copy of the bundle and exit (hosts that serve
  # the files themselves, e.g. the Cloudron package).
  render)
    render_bundle "${2:?render needs a directory}"
    exit 0
    ;;
  serve)
    if env | grep -q '^VITE_[A-Z_]*=.*__ETHORA_ORIGIN'; then
      render_bundle "${HTML_DIR:-/usr/share/nginx/html}"
      exec nginx -g 'daemon off;'
    fi
    ;;
esac

exec /usr/local/bin/ethora-frontend "$@"
