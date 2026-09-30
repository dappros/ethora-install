#!/bin/bash
# api-entrypoint.sh - entrypoint for every container of the ethora-api image
# in the compose bundle (api, jobs, init).
#
# Loads the backend.env the config service rendered, parsed by the dotenv
# package the API itself uses (so quoting and escaping behave exactly as on a
# host install), without overriding anything already in the environment.
# Then hands over to the image's own start.js:
#
#   api-entrypoint.sh api | jobs | bc-worker | script <path> [args...]
#   api-entrypoint.sh init            first-boot steps (scripts/init.sh)
#   api-entrypoint.sh verify          end-to-end check (scripts/verify.js)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ETHORA_BACKEND_ENV_FILE:-/ethora/config/api/backend.env}"
[ -r "$ENV_FILE" ] || { echo "[api] $ENV_FILE is missing or unreadable; the config service did not run" >&2; exit 1; }

exports="$(node -e '
  const fs = require("fs")
  const parsed = require("/app/node_modules/dotenv").parse(fs.readFileSync(process.argv[1]))
  const q = v => "\x27" + String(v).replace(/\x27/g, "\x27\\\x27\x27") + "\x27"
  for (const [k, v] of Object.entries(parsed)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) continue
    // dotenv.config() semantics: the process environment wins, and an empty
    // value never masks one baked into the image (ETHORA_BUILD_* etc.).
    if (process.env[k] !== undefined && (v === "" || process.env[k] !== "")) continue
    process.stdout.write("export " + k + "=" + q(v) + "\n")
  }
' "$ENV_FILE")"
eval "$exports"

if [ "${1:-}" = "init" ]; then
  shift
  exec bash "$HERE/init.sh" "$@"
fi
if [ "${1:-}" = "verify" ]; then
  shift
  exec node "$HERE/verify.js" "$@"
fi
exec node /app/dist/start.js "$@"
