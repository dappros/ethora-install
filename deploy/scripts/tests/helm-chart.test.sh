#!/bin/bash
# Tests for the Helm chart (deploy/helm/ethora-core): helm lint and helm
# template on the ci/ fixtures, schema validation with kubeconform when it is
# installed, and checks on what the templates produce.
#   run: bash deploy/scripts/tests/helm-chart.test.sh    (needs helm; kubeconform optional)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "$HERE/../../helm/ethora-core" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
skip() { SKIP=$((SKIP+1)); echo "  skip $1"; }
command -v helm >/dev/null 2>&1 || { echo "helm is required"; exit 2; }
render() { helm template ethora "$CHART" "$@" 2>"$T/err"; }
doc() { # doc <kind> <name> <file>: one rendered document
  awk -v k="kind: $1" -v n="  name: $2" 'BEGIN{RS="\n---\n"} index($0, "\n" k "\n") && index($0, "\n" n "\n") {print}' "$3"
}

echo "# lint and template"
for f in "$CHART"/ci/*-values.yaml; do
  n="$(basename "$f" -values.yaml)"
  helm lint "$CHART" -f "$f" >"$T/lint" 2>&1 && ok "helm lint ($n)" || fail "helm lint ($n)" "$(tail -n 5 "$T/lint")"
  render -f "$f" > "$T/$n.yaml" && ok "helm template ($n)" || fail "helm template ($n)" "$(cat "$T/err")"
  if command -v kubeconform >/dev/null 2>&1; then
    kubeconform -strict -summary "$T/$n.yaml" >"$T/kc" 2>&1 && ok "kubeconform ($n): $(tail -n 1 "$T/kc")" || fail "kubeconform ($n)" "$(tail -n 5 "$T/kc")"
  else
    skip "kubeconform ($n) not installed"
  fi
done
cmp -s <(sed '1,4d' "$CHART/ci/external-values.yaml") "$CHART/values-external-databases.yaml" \
  && ok "ci/external-values.yaml follows values-external-databases.yaml" || fail "ci/external-values.yaml differs from values-external-databases.yaml"
grep -rn $'\xe2\x80\x94' "$CHART" >/dev/null && fail "em dash in the chart" || ok "no em dashes in the chart"
grep -qE '^version: [0-9]{2}\.[0-9]{1,2}\.[0-9]+$' "$CHART/Chart.yaml" && ok "chart version is CalVer YY.M.patch" || fail "chart version is not YY.M.patch"

echo "# four hosts"
H="$T/hosts.yaml"
for kind in StatefulSet Deployment; do
  for c in $( [ $kind = StatefulSet ] && echo "mongo mysql redis minio" || echo "api jobs frontend xmpp centrifugo"); do
    doc "$kind" "ethora-ethora-core-$c" "$H" | grep -q . && ok "$kind $c" || fail "$kind $c missing"
  done
done
[ "$(grep -c '^kind: Ingress$' "$H")" = 4 ] && ok "four ingresses" || fail "ingress count" "$(grep -c '^kind: Ingress$' "$H")"
[ "$(grep -c 'cert-manager.io/cluster-issuer: letsencrypt-prod' "$H")" = 4 ] && ok "cert-manager annotation on every ingress" || fail "cert-manager annotation"
X="$(doc Ingress ethora-ethora-core-xmpp "$H")"
echo "$X" | grep -q 'path: /ws$' && echo "$X" | grep -q 'path: /bosh$' && ! echo "$X" | grep -qE 'path: /(api|admin)?$' \
  && ok "xmpp ingress: /ws and /bosh only" || fail "xmpp ingress paths" "$(echo "$X" | grep 'path:')"
A="$(doc Ingress ethora-ethora-core-api "$H")"
echo "$A" | grep -A6 'path: /metrics' | grep -q 'name: ethora-ethora-core-frontend' && ok "api ingress: /metrics is not the API's" || fail "api /metrics route"
echo "$A" | grep -q 'proxy-body-size: "0"' && ok "api ingress: no upload size limit" || fail "api upload annotation"
doc Ingress ethora-ethora-core-web "$H" | grep -q 'proxy-read-timeout: "3600"' && ok "web ingress: WebSocket timeouts" || fail "web websocket annotation"
S="$(doc ConfigMap ethora-ethora-core-settings "$H")"
for kv in 'ETHORA_MONGO_URI: "mongodb://ethora-ethora-core-mongo:27017/ethora_prod?directConnection=true"' 'ETHORA_REDIS_HOST: "ethora-ethora-core-redis"' \
          'ETHORA_MYSQL_HOST: "ethora-ethora-core-mysql"' 'ETHORA_MINIO_HOST: "ethora-ethora-core-minio"' 'ETHORA_API_URL: "http://ethora-ethora-core-api:8080"' \
          'ETHORA_XMPP_URL: "http://ethora-ethora-core-xmpp:5280"' 'ETHORA_CENTRIFUGO_URL: "http://ethora-ethora-core-centrifugo:8000"' 'API_DOMAIN: "api.chat.example.com"'; do
  echo "$S" | grep -qF "$kv" && ok "settings: ${kv%%:*}" || fail "settings: $kv"
done
SEC="$(doc Secret ethora-ethora-core-secrets "$H")"
[ "$(echo "$SEC" | grep -cE '^  [A-Z_]+: "')" = 14 ] && ok "secret: 14 keys generated" || fail "secret keys" "$(echo "$SEC" | grep -cE '^  [A-Z_]+: "')"
echo "$SEC" | grep -q 'helm.sh/resource-policy: keep' && ok "secret kept on uninstall" || fail "secret resource-policy"
MY="$(doc StatefulSet ethora-ethora-core-mysql "$H")"
echo "$MY" | grep -q 'subPath: mysql' && echo "$MY" | grep -q MYSQL_ROOT_PASSWORD_FILE && ok "mysql: subPath data, password from file" || fail "mysql volume/password"
XD="$(doc Deployment ethora-ethora-core-xmpp "$H")"
echo "$XD" | grep -q 'value: "+Q 65536"' && ok "xmpp: Erlang port table capped" || fail "xmpp ERL_FLAGS"
grep -q 'name: ethora-ethora-core-init-1$' "$H" && ok "init Job named after the revision" || fail "init job name"
for c in api jobs frontend xmpp centrifugo mysql minio; do
  kind=Deployment; case $c in mysql|minio) kind=StatefulSet ;; esac
  doc "$kind" "ethora-ethora-core-$c" "$H" | grep -q 'ethora-compose-init:2610' || fail "$c renders its config with ethora-compose-init"
done; ok "every consumer renders its config with ethora-compose-init:<appVersion>"

echo "# one origin, external databases, existing secret"
O="$T/one-origin.yaml"
[ "$(grep -c '^kind: Ingress$' "$O")" = 1 ] && ok "one origin: one ingress" || fail "one-origin ingress count"
OI="$(doc Ingress ethora-ethora-core-web "$O")"
for p in /v1 /v2 /api-docs /ws /bosh /connection/websocket /files /; do
  echo "$OI" | grep -q "path: $p\$" || fail "one origin: path $p"
done; ok "one origin: every path routed"
doc ConfigMap ethora-ethora-core-settings "$O" | grep -q 'PUBLIC_URL: "https://chat.example.com"' && ok "one origin: PUBLIC_URL set" || fail "one origin: PUBLIC_URL"
E="$T/external.yaml"
! grep -qE '^kind: StatefulSet$' "$E" && ok "external: no bundled databases" || fail "external: StatefulSets rendered"
ES="$(doc ConfigMap ethora-ethora-core-settings "$E")"
echo "$ES" | grep -q 'ETHORA_MYSQL_USER: "ejabberd"' && echo "$ES" | grep -q 'ETHORA_REDIS_HOST: "redis.internal.example.com"' \
  && echo "$ES" | grep -q 'mongodb+srv://' && ok "external: endpoints in the settings" || fail "external endpoints"
doc Deployment ethora-ethora-core-api "$E" | grep -q 'name: mongo-init' && fail "external: mongo-init should not run" || ok "external: no mongo-init"
render --set rootDomain=x.example.com --set admin.email=a@b.co --set secrets.existingSecret=mine > "$T/ex.yaml"
! grep -q '^kind: Secret$' "$T/ex.yaml" && grep -q 'name: mine' "$T/ex.yaml" && ok "existingSecret: used, none created" || fail "existingSecret"
render --set rootDomain=x.example.com >/dev/null && fail "admin.email required" || { grep -q 'admin.email is required' "$T/err" && ok "admin.email required"; }
render --set admin.email=a@b.co >/dev/null && fail "rootDomain or publicUrl required" || ok "rootDomain or publicUrl required"
render --set admin.email=a@b.co --set rootDomain=x.example.com --set publicUrl=https://x.example.com >/dev/null && fail "not both" || ok "rootDomain and publicUrl together refused"
render --set admin.email=a@b.co --set rootDomain=x.example.com --set mongo.enabled=false >/dev/null && fail "external mongo uri required" || ok "mongo.enabled=false needs external.mongo.uri"

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
[ "$FAIL" -eq 0 ]
