#!/bin/bash
# Tests for deploy/scripts/deploy-lock.sh (one install.sh / update.sh at a
# time) and the atomic .deploy.env rewrite in refresh-deploy-env.sh.
# Run: bash deploy/scripts/tests/deploy-lock.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/deploy/scripts/deploy-lock.sh"
T="$(mktemp -d)"; trap 'kill "${holder:-}" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }

# A stand-in for a running update.sh: its argv names update.sh, so the lock
# recognises it as a deploy run.
mkdir -p "$T/bin"
cat > "$T/bin/update.sh" <<EOF
#!/bin/bash
source "$LIB"
acquire_deploy_lock "\$1" update.sh || exit 3
echo held > "\$1/held"
sleep "\${2:-30}"
EOF
chmod +x "$T/bin/update.sh"

echo "# scripts parse"
for f in deploy-lock.sh update.sh install.sh setup-env.sh refresh-deploy-env.sh setup-nginx.sh migrate-data-paths.sh; do
  bash -n "$ROOT/deploy/scripts/$f" && ok "bash -n $f" || fail "bash -n $f"
done

echo "# a second run is refused while the first holds the lock"
S="$T/state1"; mkdir -p "$S"
"$T/bin/update.sh" "$S" 30 & holder=$!
for _ in $(seq 1 50); do [ -f "$S/held" ] && break; sleep 0.1; done
out="$(env -u ETHORA_DEPLOY_LOCK bash -c "source '$LIB'; acquire_deploy_lock '$S' install.sh; echo acquired" 2>&1)"; rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "already running" && ! echo "$out" | grep -q acquired && ok "refused with exit 1" || fail "second run refused" "$out"
echo "$out" | grep -q "update.sh pid $holder" && ok "names the running owner" || fail "names the owner" "$out"
echo "# a lock left by a run that is gone is taken over"
# SIGKILL, like a crash or a reboot: the EXIT trap never runs, the lock stays.
kill -KILL "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""
[ -d "$S/deploy.lock" ] && ok "killed run left its lock" || fail "stale lock present"
out="$(env -u ETHORA_DEPLOY_LOCK bash -c "source '$LIB'; acquire_deploy_lock '$S' install.sh; echo acquired; cat '$S/deploy.lock/owner'" 2>&1)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "Taking over" && echo "$out" | grep -q acquired && ok "stale lock taken over" || fail "stale takeover" "$out"
# An unrelated live PID (not install.sh / update.sh) does not hold the lock.
mkdir -p "$T/state2/deploy.lock"; sleep 30 & other=$!; echo "$other" > "$T/state2/deploy.lock/pid"
out="$(env -u ETHORA_DEPLOY_LOCK bash -c "source '$LIB'; acquire_deploy_lock '$T/state2' update.sh; echo acquired" 2>&1)"
kill "$other" 2>/dev/null
echo "$out" | grep -q acquired && ok "reused PID of another program is not a holder" || fail "reused PID" "$out"

echo "# released on exit, kept across the self re-exec"
S="$T/state3"; mkdir -p "$S"
env -u ETHORA_DEPLOY_LOCK bash -c "source '$LIB'; acquire_deploy_lock '$S' update.sh"
[ ! -e "$S/deploy.lock" ] && ok "lock removed when the run exits" || fail "lock released on exit"
out="$(env -u ETHORA_DEPLOY_LOCK bash -c "
  source '$LIB'; acquire_deploy_lock '$S' update.sh
  exec bash -c \"source '$LIB'; acquire_deploy_lock '$T/elsewhere' update.sh && echo reacquired \\\$ETHORA_DEPLOY_LOCK\"
" 2>&1)"
echo "$out" | grep -q "reacquired $S/deploy.lock" && ok "re-exec keeps the same lock" || fail "re-exec" "$out"
[ ! -e "$S/deploy.lock" ] && ok "re-exec'd run releases it on exit" || fail "re-exec release"

echo "# refresh-deploy-env.sh rewrites .deploy.env atomically"
D="$T/deploy"; mkdir -p "$D/scripts" "$D/config"
cp "$ROOT/deploy/scripts/refresh-deploy-env.sh" "$D/scripts/"
printf 'domains:\n  api: api.example.com\n' > "$D/config/deploy.yml"
{ echo 'export KEEP_ME="secret"'; for i in $(seq 1 300); do echo "export FILLER_$i=\"$i\""; done; } > "$D/.deploy.env"
if command -v yq >/dev/null 2>&1; then
  ino_before="$(stat -c %i "$D/.deploy.env")"
  # A reader looping over the file while it is rewritten must always see KEEP_ME.
  ( for _ in $(seq 1 400); do grep -q '^export KEEP_ME=' "$D/.deploy.env" || { echo torn; break; }; done ) > "$T/reader" &
  rpid=$!
  bash "$D/scripts/refresh-deploy-env.sh" >/dev/null 2>&1
  wait "$rpid"
  [ ! -s "$T/reader" ] && ok "a concurrent reader never sees a truncated file" || fail "torn read"
  grep -q '^export KEEP_ME="secret"' "$D/.deploy.env" && grep -q '^export API_DOMAIN="api.example.com"' "$D/.deploy.env" && ok "keys kept, new key written" || fail "content"
  [ "$(stat -c %i "$D/.deploy.env")" != "$ino_before" ] && ok "file replaced by rename" || fail "rename"
  [ "$(stat -c %a "$D/.deploy.env")" = 600 ] && ok "mode 600" || fail "mode" "$(stat -c %a "$D/.deploy.env")"
  ! ls "$D"/.deploy.env.tmp.* >/dev/null 2>&1 && ok "no temp files left" || fail "temp files left"
else
  echo "  skip refresh-deploy-env.sh checks (yq not installed)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
