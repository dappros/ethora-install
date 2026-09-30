#!/usr/bin/env bash
# build-template.sh - generate ethora-core.yaml, the Coolify one-click
# service template, from ethora-core.in.yaml and the bundle's scripts/ and
# templates/. A line
#   @content <path relative to deploy/compose>
# inside the skeleton is replaced by that file as a YAML block scalar
# (`content: |` follows the marker's indentation), so the template always
# carries the same scripts the bundle runs. Checked by
# deploy/scripts/tests/compose-bundle.test.sh (regenerate, expect no diff).
#   run: deploy/compose/platforms/coolify/build-template.sh [--check]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "$HERE/../.." && pwd)"
IN="$HERE/ethora-core.in.yaml"
OUT="$HERE/ethora-core.yaml"

render() {
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([[:space:]]*)@content[[:space:]]+([^[:space:]]+)$ ]]; then
      indent="${BASH_REMATCH[1]}"; f="$BUNDLE/${BASH_REMATCH[2]}"
      [ -f "$f" ] || { echo "[build-template] $f not found" >&2; exit 1; }
      printf '%scontent: |\n' "$indent"
      sed "s/^/$indent  /; s/[[:space:]]*$//" "$f"
    else
      printf '%s\n' "$line"
    fi
  done < "$IN"
}

if [ "${1:-}" = "--check" ]; then
  diff -u "$OUT" <(render) && echo "[build-template] $OUT is up to date"
else
  render > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
  echo "[build-template] wrote $OUT ($(wc -c < "$OUT") bytes)"
fi
