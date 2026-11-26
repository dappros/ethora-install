#!/bin/bash
# Tests for the cloud image scripts: deploy/cloud/install.sh (dry run),
# deploy/cloud/provision.sh (syntax and step dispatch) and the setup page in
# compose mode (a dry-run install through its HTTP API). Needs bash and node.
# Run: bash deploy/scripts/tests/cloud-install.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${srvpid:-}" ] && kill "$srvpid" 2>/dev/null' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }

echo "# scripts parse"
for f in deploy/compose/get.sh deploy/cloud/install.sh deploy/cloud/provision.sh deploy/setup-web/install-setup-web.sh deploy/vultr/packer/ethora.sh deploy/linode/ethora-core.stackscript.sh; do
  bash -n "$ROOT/$f" && ok "bash -n $f" || fail "bash -n $f"
done
node --check "$ROOT/deploy/setup-web/server.js" && ok "server.js parses" || fail "server.js parses"

echo "# install.sh dry run"
# A copy of the bundle, so the dry run cannot touch the checkout's .env.
mkdir -p "$T/src/deploy"; cp -r "$ROOT/deploy/compose" "$T/src/deploy/compose"; cp -r "$ROOT/deploy/cloud" "$T/src/deploy/cloud"; rm -f "$T/src/deploy/compose/.env"
out="$(ETHORA_DONE_FILE="$T/done" bash "$T/src/deploy/cloud/install.sh" --domain Chat.Example.com --admin-email ops@example.com --display-name Acme --secure-files off --dry-run 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "dry run exits 0" || fail "dry run exit $rc" "$out"
echo "$out" | grep -q "root domain chat.example.com" && ok "domain normalised" || fail "domain normalised" "$out"
echo "$out" | grep -q "secure-files=off" && ok "--secure-files off passed through" || fail "secure-files off" "$out"
[ ! -f "$T/src/deploy/compose/.env" ] && [ ! -f "$T/done" ] && ok "dry run writes nothing" || fail "dry run wrote files"
out="$(bash "$T/src/deploy/cloud/install.sh" --admin-email ops@example.com --dry-run 2>&1)"; [ $? != 0 ] && echo "$out" | grep -q "root domain is required" && ok "domain required" || fail "domain required" "$out"
out="$(ETHORA_STEP=nope bash "$T/src/deploy/cloud/provision.sh" 2>&1)"; [ $? = 2 ] && ok "provision.sh refuses an unknown step" || fail "provision.sh unknown step" "$out"

echo "# setup page, compose mode (dry run through the API)"
port=$((20000 + RANDOM % 20000))
ETHORA_SOURCE_ROOT="$T/src" SETUP_MODE=compose SETUP_DRY_RUN=1 SETUP_PASSWORD=pw SETUP_PORT=$port SETUP_BIND=127.0.0.1 \
  SETUP_DONE_FILE="$T/done" SETUP_LOG="$T/setup.log" SETUP_LINGER_SECONDS=0 node "$ROOT/deploy/setup-web/server.js" >"$T/server.out" 2>&1 &
srvpid=$!
for _ in $(seq 1 30); do curl -s -o /dev/null -u admin:pw "http://127.0.0.1:$port/healthz" && break; sleep 0.2; done
page="$(curl -s -u admin:pw "http://127.0.0.1:$port/")"
echo "$page" | grep -q 'name="secure_files"' && ! echo "$page" | grep -q 'name="backend_mode"' && ok "compose form rendered (no host-installer fields)" || fail "compose form"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")" = 401 ] && ok "basic auth required" || fail "basic auth"
r="$(curl -s -u admin:pw -X POST -H 'content-type: application/json' -d '{"domain":"Chat.Example.com","admin_email":"ops@example.com","secure_files":"off","display_name":"Acme"}' "http://127.0.0.1:$port/api/setup")"
echo "$r" | grep -q '"ok":true' && ok "install accepted" || fail "install accepted" "$r"
phase=""
for _ in $(seq 1 100); do phase="$(curl -s -u admin:pw "http://127.0.0.1:$port/api/state" | sed -n 's/.*"phase":"\([a-z]*\)".*/\1/p')"; [ "$phase" != running ] && [ -n "$phase" ] && break; sleep 0.3; done
[ "$phase" = done ] && ok "dry-run install finished (phase done)" || fail "phase $phase" "$(tail -5 "$T/setup.log" 2>/dev/null)"
grep -q "cloud/install.sh --domain Chat.Example.com --admin-email ops@example.com --display-name Acme --secure-files off --dry-run" "$T/setup.log" && ok "answers passed to install.sh" || fail "install.sh args" "$(head -3 "$T/setup.log")"
grep -q "dry run: nothing written" "$T/setup.log" && ok "install.sh log streamed" || fail "log streamed"
r="$(curl -s -u admin:pw -X POST -H 'content-type: application/json' -d '{"domain":"x.example.com","admin_email":"ops@example.com"}' "http://127.0.0.1:$port/api/setup")"
echo "$r" | grep -q '"ok":true' && ok "a dry run leaves no done marker, so a second submit is accepted" || fail "second submit" "$r"
kill "$srvpid" 2>/dev/null; wait "$srvpid" 2>/dev/null; srvpid=""

echo "# Ethora Enterprise through AWS Marketplace (paid image)"
out="$(ETHORA_DONE_FILE="$T/done" bash "$T/src/deploy/cloud/install.sh" --domain chat.example.com --admin-email ops@example.com --aws-marketplace --dry-run 2>&1)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "Ethora Enterprise through AWS Marketplace" && echo "$out" | grep -q "AWS Marketplace: would activate" \
  && echo "$out" | grep -qE "Modules: +ai push mcp uptime" && ok "install.sh --aws-marketplace: activation (dry run) and the default modules" || fail "install.sh --aws-marketplace" "$out"
out="$(ETHORA_DONE_FILE="$T/done" bash "$T/src/deploy/cloud/install.sh" --domain chat.example.com --admin-email ops@example.com --azure-marketplace --dry-run 2>&1)"
echo "$out" | grep -q "Ethora Enterprise through Azure Marketplace" && echo "$out" | grep -q "Azure Marketplace: would activate" && ! echo "$out" | grep -q "AWS Marketplace" \
  && ok "install.sh --azure-marketplace: Azure activation (dry run), no AWS text" || fail "install.sh --azure-marketplace" "$out"
out="$(ETHORA_EDITION=nope ETHORA_STEP=base bash "$T/src/deploy/cloud/provision.sh" 2>&1)"; [ $? = 2 ] && ok "provision.sh refuses an unknown edition" || fail "provision.sh unknown edition" "$out"
port=$((20000 + RANDOM % 20000))
ETHORA_SOURCE_ROOT="$T/src" SETUP_MODE=compose SETUP_EDITION=aws-marketplace SETUP_DRY_RUN=1 SETUP_PASSWORD=pw SETUP_PORT=$port SETUP_BIND=127.0.0.1 \
  SETUP_DONE_FILE="$T/done2" SETUP_LOG="$T/setup2.log" SETUP_LINGER_SECONDS=0 node "$ROOT/deploy/setup-web/server.js" >"$T/server2.out" 2>&1 &
srvpid=$!
for _ in $(seq 1 30); do curl -s -o /dev/null -u admin:pw "http://127.0.0.1:$port/healthz" && break; sleep 0.2; done
page="$(curl -s -u admin:pw "http://127.0.0.1:$port/")"
echo "$page" | grep -q 'Ethora Enterprise setup' && echo "$page" | grep -q 'Licensed through AWS Marketplace' && ! echo "$page" | grep -q 'name="license_key"' \
  && echo "$page" | grep -q 'value="ai,push,mcp,uptime"' && ok "setup page on the paid image: no key field, modules prefilled" || fail "paid setup page"
curl -s -u admin:pw -X POST -H 'content-type: application/json' -d '{"domain":"chat.example.com","admin_email":"ops@example.com","modules":"ai,push","license_key":"ignored"}' "http://127.0.0.1:$port/api/setup" >/dev/null
for _ in $(seq 1 100); do grep -q "dry run: nothing written\|ERROR" "$T/setup2.log" 2>/dev/null && break; sleep 0.3; done
grep -q "cloud/install.sh --domain chat.example.com --admin-email ops@example.com --aws-marketplace --modules ai,push --dry-run" "$T/setup2.log" \
  && ok "paid image: --aws-marketplace passed, a pasted key ignored" || fail "paid image args" "$(head -3 "$T/setup2.log")"
kill "$srvpid" 2>/dev/null; wait "$srvpid" 2>/dev/null; srvpid=""

echo; echo "passed $PASS, failed $FAIL"; [ "$FAIL" = 0 ]
