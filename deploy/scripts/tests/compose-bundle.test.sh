#!/bin/bash
# Tests for the compose bundle (deploy/compose). Pure bash; the parts that
# need Docker (BusyBox parity of the renderer, `docker compose config`, the
# Caddyfile) are skipped when it is not available.
#   run: bash deploy/scripts/tests/compose-bundle.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$(cd "$HERE/../.." && pwd)"
BUNDLE="$DEPLOY/compose"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
skip() { SKIP=$((SKIP+1)); echo "  skip $1"; }
envval() { sed -n "s/^$1=//p" "$2" | head -n 1 | sed "s/^'\(.*\)'$/\1/"; }
have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
XMPP_IMAGE="$(sed -n 's/^ETHORA_XMPP_IMAGE=//p' "$BUNDLE/.env.example")"

echo "# bundle is in sync with the installer"
for t in backend.env.template frontend.env.template centrifugo-config.json.template; do
  cmp -s "$BUNDLE/templates/$t" "$DEPLOY/templates/$t" && ok "templates/$t identical to deploy/templates" \
    || fail "templates/$t differs from deploy/templates/$t" "cp deploy/templates/$t deploy/compose/templates/"
done
for fn in norm_host valid_host valid_email valid_key; do
  a="$(grep -E "^$fn\(\)" "$DEPLOY/scripts/setup.sh")"; b="$(grep -E "^$fn\(\)" "$BUNDLE/configure.sh")"
  [ -n "$a" ] && [ "$a" = "$b" ] && ok "configure.sh $fn() identical to setup.sh" || fail "configure.sh $fn() differs from setup.sh"
done
# templates/ are verbatim copies of the installer's, checked above.
grep -rn --exclude-dir=templates $'\xe2\x80\x94' "$BUNDLE" >/dev/null && fail "em dash in the bundle" "$(grep -rln --exclude-dir=templates $'\xe2\x80\x94' "$BUNDLE")" || ok "no em dashes in the bundle"

echo "# platforms/coolify"
CT="$BUNDLE/platforms/coolify/ethora-core.yaml"
"$BUNDLE/platforms/coolify/build-template.sh" --check >/dev/null 2>"$T/tpl.err" && ok "coolify template regenerates identically" || fail "coolify template out of date" "run deploy/compose/platforms/coolify/build-template.sh"
grep -q $'\xe2\x80\x94' "$CT" && fail "em dash in the coolify template" || ok "no em dashes in the coolify template"
for f in scripts/api-entrypoint.sh scripts/init.sh scripts/verify.js scripts/render-config.sh scripts/mongo-init.sh scripts/xmpp-start.sh scripts/frontend-start.sh \
         templates/backend.env.template templates/frontend.env.template templates/centrifugo-config.json.template; do
  grep -q "source: ./$f$" "$CT" || fail "coolify template carries $f"
done; ok "coolify template carries every script and template inline"
grep -q "^# port: 8080" "$CT" && grep -q "^# slogan:" "$CT" && ok "coolify template header" || fail "coolify template header"
grep -qE '^  caddy:' "$CT" && fail "coolify template must not include caddy" || ok "coolify template has no bundled proxy"
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  python3 - "$CT" >"$T/tpl.out" 2>&1 <<'PY' && ok "coolify template parses: $(cat "$T/tpl.out")" || fail "coolify template does not parse" "$(cat "$T/tpl.out")"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
svcs = d["services"]
assert set(svcs) == {"config","mongo","mongo-init","mysql","redis","minio","centrifugo","xmpp","api","jobs","init","frontend"}, sorted(svcs)
files = {(v["source"], len(v["content"])) for s in svcs.values() for v in s.get("volumes", []) if isinstance(v, dict) and "content" in v}
assert len(files) == 10, files
assert all(n > 0 for _, n in files)
print(f"{len(svcs)} services, {len(files)} inline files, {sum(n for _, n in files)} bytes of content")
PY
else skip "coolify template parses (python3 + pyyaml not available)"; fi

echo "# platforms/dokploy"
DT="$BUNDLE/platforms/dokploy"
"$DT/build-template.sh" --check >/dev/null 2>"$T/dtpl.err" && ok "dokploy blueprint regenerates identically" || fail "dokploy blueprint out of date" "run deploy/compose/platforms/dokploy/build-template.sh"
for f in scripts/api-entrypoint.sh scripts/init.sh scripts/verify.js scripts/render-config.sh scripts/mongo-init.sh scripts/xmpp-start.sh scripts/frontend-start.sh \
         templates/backend.env.template templates/frontend.env.template templates/centrifugo-config.json.template; do
  grep -q "^filePath = \"/$f\"$" "$DT/template.toml" || fail "dokploy blueprint carries $f"
done; ok "dokploy blueprint carries every script and template as a mount"
DC="$DT/docker-compose.yml"
grep -qE '^  caddy:' "$DC" && fail "dokploy compose must not include caddy" || ok "dokploy compose has no bundled proxy"
grep -qE '^\s+(ports|container_name|networks):' "$DC" && fail "dokploy compose has ports/container_name/networks (the templates repository rejects them)" || ok "dokploy compose has no ports, container_name or networks"
grep -qE '\./(scripts|templates):' "$DC" && fail "dokploy compose still mounts ./scripts or ./templates" || ok "dokploy compose mounts ../files/scripts and ../files/templates"
grep -qE '^name:' "$DC" && fail "dokploy compose sets a project name" || ok "dokploy compose leaves the project name to Dokploy"
python3 -c 'import json,sys,os; d=json.load(open(sys.argv[1])); assert d["id"]=="ethora-core" and all(k in d for k in ("name","version","description","links","logo","tags")); assert os.path.exists(os.path.join(os.path.dirname(sys.argv[1]), d["logo"]))' "$DT/meta.json" 2>"$T/meta.err" && ok "dokploy meta.json complete, logo present" || fail "dokploy meta.json" "$(cat "$T/meta.err")"
if command -v python3 >/dev/null 2>&1 && python3 -c "import tomllib" 2>/dev/null; then
  python3 - "$DT/template.toml" "$BUNDLE" >"$T/dtpl.out" 2>&1 <<'PY' && ok "dokploy template.toml parses: $(cat "$T/dtpl.out")" || fail "dokploy template.toml" "$(cat "$T/dtpl.out")"
import sys, tomllib, re
d = tomllib.load(open(sys.argv[1], "rb")); bundle = sys.argv[2]
c = d["config"]
doms = {(x["serviceName"], x["port"], x["host"], x.get("path", "/")) for x in c["domains"]}
assert doms == {("api", 8080, "api.${root_domain}", "/"), ("frontend", 8080, "app.${root_domain}", "/"),
                ("centrifugo", 8000, "app.${root_domain}", "/connection/websocket"), ("xmpp", 5280, "xmpp.${root_domain}", "/ws"),
                ("xmpp", 5280, "xmpp.${root_domain}", "/bosh"), ("minio", 9000, "files.${root_domain}", "/"),
                ("api", 8080, "secure-files.${root_domain}", "/")}, doms
assert d["variables"]["root_domain"] == "${domain}"
for m in c["mounts"]:
    assert m["content"] == open(bundle + m["filePath"]).read(), m["filePath"]
env = dict(l.split("=", 1) for l in c["env"])
example = [l.split("=", 1)[0] for l in open(bundle + "/.env.example") if re.match(r"^[A-Z_]+=", l)]
skipped = {"API_DOMAIN", "WEB_DOMAIN", "XMPP_DOMAIN", "FILES_DOMAIN", "SECURE_FILES_DOMAIN", "ACME_EMAIL", "CADDY_GLOBAL_OPTIONS", "HTTP_PORT", "HTTPS_PORT",
           "PUBLIC_URL", "ETHORA_COMPOSE_INIT_IMAGE"}  # five hosts routed by Traefik; the dev form renders with the xmpp image
assert [k for k in example if k not in skipped] == list(env), list(env)
assert env["COMPOSE_PROFILES"] == "" and env["ROOT_DOMAIN"] == "${root_domain}"
secrets = [k for k in env if k.endswith(("_SECRET", "_PASSWORD", "_KEY")) and k != "ETHORA_LICENSE_KEY"] + ["MINIO_ROOT_USER"]
for k in secrets:
    v = re.fullmatch(r"(ethora)?\$\{([a-z_]+)\}", env[k]); assert v and "${password:" in d["variables"][v.group(2)], (k, env[k])
print(f"{len(c['domains'])} domains, {len(c['mounts'])} mounts, {len(env)} env keys, {len(secrets)} generated secrets")
PY
else skip "dokploy template.toml parses (python3 3.11+ with tomllib not available)"; fi

echo "# configure.sh"
B="$T/bundle"; cp -r "$BUNDLE" "$B"; rm -f "$B/.env"
cfg() { "$B/configure.sh" "$@" >"$T/out" 2>"$T/err"; }
cfg --domain Chat.Example.com --admin-email ops@example.com --yes
E="$B/.env"
[ -f "$E" ] && ok "wrote .env" || fail "wrote .env" "$(cat "$T/err")"
[ "$(envval ROOT_DOMAIN "$E")" = "chat.example.com" ] && ok "root domain normalised" || fail "root domain" "$(envval ROOT_DOMAIN "$E")"
[ -z "$(envval API_DOMAIN "$E")" ] && ok "hosts left to derive from ROOT_DOMAIN" || fail "hosts derived" "$(envval API_DOMAIN "$E")"
[ -z "$(envval SECURE_FILES_DOMAIN "$E")" ] && ok "secure files host left to derive" || fail "secure files derived" "$(envval SECURE_FILES_DOMAIN "$E")"
[ "$(stat -c %a "$E")" = "600" ] && ok ".env mode 600" || fail ".env mode" "$(stat -c %a "$E")"
missing=""
for k in ADMIN_PASSWORD JWT_SECRET REFRESH_SECRET XMPP_SECRET XMPP_JWT_SECRET XMPP_ADMIN_PASSWORD INTERNAL_REQUESTS_SECRET \
         MYSQL_ROOT_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD CENTRIFUGO_API_KEY CENTRIFUGO_HMAC_SECRET \
         CENTRIFUGO_ADMIN_PASSWORD CENTRIFUGO_ADMIN_SECRET; do
  v="$(envval "$k" "$E")"; [ ${#v} -ge 12 ] || missing="$missing $k"
done
[ -z "$missing" ] && ok "every secret generated" || fail "secrets not generated:$missing"
[ "$(envval JWT_SECRET "$E" | tr -d "\n" | wc -c)" -ge 64 ] && ok "signing keys are 64 chars" || fail "JWT_SECRET length"
pw="$(envval ADMIN_PASSWORD "$E")"; grep -q "$pw" "$T/out" && ok "generated admin password printed" || fail "admin password printed"
[ "$(envval COMPOSE_PROFILES "$E")" = "caddy" ] && ok "caddy profile on" || fail "caddy profile"
keys_example="$(grep -oE '^[A-Z_]+=' "$BUNDLE/.env.example" | sort)"; keys_env="$(grep -oE '^[A-Z_]+=' "$E" | sort)"
[ "$keys_example" = "$keys_env" ] && ok "same keys as .env.example" || fail "keys differ from .env.example" "$(diff <(echo "$keys_example") <(echo "$keys_env") | head -5)"

cp "$E" "$T/first.env"; echo "POSTMARK_ENABLED=true" >> "$E"
cfg --display-name "Acme Chat" --yes
for k in JWT_SECRET MYSQL_ROOT_PASSWORD MINIO_ROOT_PASSWORD ADMIN_PASSWORD; do
  [ "$(envval "$k" "$E")" = "$(envval "$k" "$T/first.env")" ] || { fail "re-run kept $k"; continue; }
done; ok "re-run keeps secrets and the admin password"
[ "$(envval BASE_APP_DISPLAY_NAME "$E")" = "Acme Chat" ] && grep -q "^BASE_APP_DISPLAY_NAME='Acme Chat'$" "$E" && ok "answer applied, quoted" || fail "display name" "$(grep DISPLAY "$E")"
[ "$(envval POSTMARK_ENABLED "$E")" = "true" ] && ok "operator-added variable kept" || fail "added variable kept"
[ "$(envval ROOT_DOMAIN "$E")" = "chat.example.com" ] && ok "unanswered domain kept" || fail "domain kept"
cfg --api api-x.example.com --no-caddy --yes
[ "$(envval API_DOMAIN "$E")" = "api-x.example.com" ] && ok "explicit host override" || fail "host override"
[ -z "$(envval COMPOSE_PROFILES "$E")" ] && ok "--no-caddy clears COMPOSE_PROFILES" || fail "--no-caddy"
cfg --force --domain chat.example.com --admin-email ops@example.com --yes
[ "$(envval JWT_SECRET "$E")" != "$(envval JWT_SECRET "$T/first.env")" ] && ok "--force regenerates secrets" || fail "--force"
rm -f "$E"
cfg --domain localhost --admin-email a@b.co --yes && fail "localhost refused" || ok "localhost refused"
cfg --domain 'not a domain' --admin-email a@b.co --yes && fail "invalid domain refused" || ok "invalid domain refused"
cfg --domain chat.example.com --admin-email nope --yes && fail "invalid email refused" || ok "invalid email refused"
cfg --domain chat.example.com --admin-email a@b.co --admin-password "it's" --yes && fail "single quote refused" || ok "single quote refused"
cfg --domain chat.example.com --admin-email a@b.co --license-key bogus --yes && fail "bad licence key refused" || ok "bad licence key refused"
cfg --domain chat.example.com --admin-email a@b.co --dry-run --yes; [ ! -f "$E" ] && ok "--dry-run writes nothing" || fail "--dry-run wrote"

echo "# render-config.sh"
TPL=""
if [ -f "$DEPLOY/../ejabberd-docker/docker/ejabberd-prod.yml" ]; then
  mkdir -p "$T/dist"; cp "$DEPLOY/../ejabberd-docker/docker/ejabberd-prod.yml" "$DEPLOY/../ejabberd-docker/docker/mysql2.sql" "$T/dist/"; TPL=submodule
elif have_docker && { docker image inspect "$XMPP_IMAGE" >/dev/null 2>&1 || docker pull -q "$XMPP_IMAGE" >/dev/null 2>&1; }; then
  cid="$(docker create "$XMPP_IMAGE")"; mkdir -p "$T/dist"
  docker cp "$cid:/ethora-dist/ejabberd-prod.yml" "$T/dist/" >/dev/null && docker cp "$cid:/ethora-dist/mysql2.sql" "$T/dist/" >/dev/null && TPL=image
  docker rm -f "$cid" >/dev/null
fi
if [ -z "$TPL" ]; then
  skip "render tests (no ejabberd-docker checkout and no Docker to read $XMPP_IMAGE)"
else
  # Passwords with the characters sed and dotenv care about. The installer's
  # own seds only survive base64-style secrets, so the comparison with it
  # below uses those everywhere except MYSQL_ROOT_PASSWORD (checked apart).
  renv=(ROOT_DOMAIN=chat.example.com ADMIN_EMAIL=ops@example.com 'ADMIN_PASSWORD=p&w|d\1' JWT_SECRET=jwt REFRESH_SECRET=ref
        XMPP_SECRET='x+s/ec=' XMPP_JWT_SECRET='jwt+/=secret' XMPP_ADMIN_PASSWORD=xadm 'MYSQL_ROOT_PASSWORD=my|sq&l\1/x'
        MINIO_ROOT_USER=mu MINIO_ROOT_PASSWORD=mp INTERNAL_REQUESTS_SECRET=irs CENTRIFUGO_API_KEY=cak
        CENTRIFUGO_HMAC_SECRET=chs CENTRIFUGO_ADMIN_PASSWORD=cap CENTRIFUGO_ADMIN_SECRET=cas 'BASE_APP_DISPLAY_NAME=Acme Chat'
  CRYPTOPAIR_SECRET=testpassphrase SECRET_FOR_DB_ENCRYPTION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb SECRET_FOR_FILES_ENCRYPTION=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd
)
  R="$T/r"; mkdir -p "$R"
  # rcfg <out dir> [VAR=value ...]: run the renderer on the host (GNU tools).
  rcfg() {
    local o="$1"; shift
    env -i PATH="$PATH" TMPDIR="$T" TEMPLATES_DIR="$BUNDLE/templates" XMPP_DIST_DIR="$T/dist" \
      CADDYFILE_TEMPLATE="$BUNDLE/Caddyfile" CONFIG_OUT_DIR="$o/config" MYSQL_INITDB_DIR="$o/initdb" \
      SECRETS_DIR="$o/secrets" "$@" sh "$BUNDLE/scripts/render-config.sh"
  }
  rcfg "$R" "${renv[@]}" >"$T/out" 2>"$T/err" && ok "renders (template from $TPL)" || fail "render" "$(cat "$T/err")"
  be="$R/config/api/backend.env"; fe="$R/config/frontend/frontend.env"
  ! grep -nE '\{\{|_PLACEHOLDER' "$be" "$fe" "$R/config/centrifugo/config.json" >/dev/null && ok "no unrendered placeholders" \
    || fail "unrendered placeholders" "$(grep -nE '\{\{|_PLACEHOLDER' "$be" "$fe" "$R/config/centrifugo/config.json" | head -3)"
  missing=""
  for k in $(grep -oE '^[A-Z0-9_]+=' "$DEPLOY/templates/backend.env.template" | tr -d =; grep -oE '^[A-Z0-9_]+_PLACEHOLDER' "$DEPLOY/templates/backend.env.template" | sed 's/_PLACEHOLDER$//'); do
    grep -q "^$k=" "$be" || missing="$missing $k"
  done
  [ -z "$missing" ] && ok "backend.env carries every variable of backend.env.template" || fail "backend.env misses:$missing"
  missing=""
  for k in $(grep -oE '^[A-Z0-9_]+=' "$DEPLOY/templates/frontend.env.template" | tr -d =; grep -oE '^[A-Z0-9_]+_PLACEHOLDER' "$DEPLOY/templates/frontend.env.template" | sed 's/_PLACEHOLDER$//'); do
    grep -q "^$k=" "$fe" || missing="$missing $k"
  done
  [ -z "$missing" ] && ok "frontend.env carries every variable of frontend.env.template" || fail "frontend.env misses:$missing"
  for kv in 'MONGO_URI=mongodb://mongo:27017/ethora_prod?directConnection=true' REDIS_HOST=redis MINIO_HOST=minio MAM_MYSQL_HOST=mysql \
            'CENTRIFUGO_API_URL=http://centrifugo:8000/api' 'XMPP_PATH=http://xmpp:5280/api' 'XMPP_SERVICE=wss://xmpp.chat.example.com/ws' \
            'MINIO_URL=https://files.chat.example.com' 'MINIO_SECURE_URL=https://secure-files.chat.example.com' 'AUTH_COOKIE_DOMAIN=.chat.example.com' \
            ENABLE_SWAGGER=true BASE_APP_DOMAIN_NAME=app 'PLATFORM_ACCOUNT_PASSWORD="p&w|d\1"' \
            'ETHORA_LICENSED_HOSTS=api.chat.example.com,app.chat.example.com,xmpp.chat.example.com,files.chat.example.com'; do
    grep -qxF "$kv" "$be" && ok "backend.env: $kv" || fail "backend.env: $kv" "$(grep "^${kv%%=*}=" "$be")"
  done
  for kv in 'VITE_API=https://api.chat.example.com/v1' 'VITE_APP_XMPP_SERVICE=wss://xmpp.chat.example.com/ws' \
            'VITE_APP_CENTRIFUGE_SERVICE=wss://app.chat.example.com/connection/websocket' 'VITE_PLATFORM_NAME=Acme Chat' VITE_DOMAIN_NAME=app; do
    grep -qxF "$kv" "$fe" && ok "frontend.env: $kv" || fail "frontend.env: $kv"
  done
  grep -q '"hmac_secret_key": "chs"' "$R/config/centrifugo/config.json" && ok "centrifugo config rendered" || fail "centrifugo config"
  [ "$(cat "$R/config/xmpp/jwt.key")" = '{"kty":"oct","k":"'"$(printf '%s' 'jwt+/=secret' | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"'"}' ] && ok "jwt.key" || fail "jwt.key" "$(cat "$R/config/xmpp/jwt.key")"
  cmp -s "$R/initdb/01-ejabberd.sql" "$T/dist/mysql2.sql" && ok "ejabberd schema staged for mysql" || fail "schema staged"
  [ "$(stat -c %a "$R/config/api/backend.env")" = "600" ] && [ "$(stat -c %a "$R/config/api")" = "700" ] && ok "rendered secrets are 600 in 700 dirs" || fail "rendered modes"
  for f in mysql/root-password minio/root-user minio/root-password xmpp/admin-password; do
    [ -f "$R/config/$f" ] && [ "$(stat -c %a "$R/config/$f")" = "600" ] || fail "config/$f rendered 600"
  done
  [ "$(cat "$R/config/mysql/root-password")" = 'my|sq&l\1/x' ] && [ "$(cat "$R/config/minio/root-user")" = mu ] \
    && ok "database credentials rendered for the *_FILE variables" || fail "database credential files"
  n="$(ls "$R/config/scripts" | wc -l)"; [ "$n" = "$(ls "$BUNDLE"/scripts/*.sh "$BUNDLE"/scripts/*.js | wc -l)" ] \
    && ok "scripts published into the config volume ($n)" || fail "scripts published" "$n"
  grep -q '^api.chat.example.com {$' "$R/config/caddy/Caddyfile" && grep -q '^	import files$' "$R/config/caddy/Caddyfile" \
    && grep -q '^secure-files.chat.example.com {$' "$R/config/caddy/Caddyfile" && grep -q '^	import secure_files$' "$R/config/caddy/Caddyfile" \
    && ! grep -q '{\$' <(grep -v '^[[:space:]]*#' "$R/config/caddy/Caddyfile") && ok "Caddyfile rendered for five hosts" || fail "Caddyfile (five hosts)"
  grep -qxF 'ETHORA_PUBLIC_XMPP_WS_URL=wss://xmpp.chat.example.com/ws' "$be" && grep -qxF 'ETHORA_PUBLIC_FILES_URL=https://files.chat.example.com' "$be" \
    && grep -qxF 'ETHORA_PUBLIC_SECURE_FILES_URL=https://secure-files.chat.example.com' "$be" \
    && ok "backend.env names the public entry points" || fail "ETHORA_PUBLIC_* in backend.env"
  # SECURE_FILES_DOMAIN=off: four hosts, attachments in the public bucket.
  R2b="$T/r2b"; mkdir -p "$R2b"
  rcfg "$R2b" ROOT_DOMAIN=chat.example.com ADMIN_EMAIL=ops@example.com SECURE_FILES_DOMAIN=off >/dev/null 2>&1
  grep -qxF 'MINIO_SECURE_URL=' "$R2b/config/api/backend.env" && ! grep -q '^secure-files' "$R2b/config/caddy/Caddyfile" \
    && grep -qxF 'ETHORA_PUBLIC_SECURE_FILES_URL=' "$R2b/config/api/backend.env" \
    && ok "SECURE_FILES_DOMAIN=off: no fifth host, MINIO_SECURE_URL empty" || fail "SECURE_FILES_DOMAIN=off" "$(grep -n 'MINIO_SECURE_URL\|secure-files' "$R2b/config/api/backend.env" "$R2b/config/caddy/Caddyfile")"

  # Secrets left out are generated once into the secrets volume and reused.
  R3="$T/r3"; mkdir -p "$R3"
  rcfg "$R3" ROOT_DOMAIN=chat.example.com ADMIN_EMAIL=ops@example.com >"$T/out3" 2>&1 && ok "renders with only ROOT_DOMAIN and ADMIN_EMAIL" || fail "minimal render" "$(cat "$T/out3")"
  [ "$(grep -c '=' "$R3/secrets/secrets.env")" = "17" ] && [ "$(stat -c %a "$R3/secrets/secrets.env")" = "600" ] \
    && ok "17 secrets generated into the secrets volume (600)" || fail "generated secrets" "$(cut -d= -f1 "$R3/secrets/secrets.env" | tr '\n' ' ')"
  pw="$(sed -n 's/^ADMIN_PASSWORD=//p' "$R3/secrets/secrets.env")"
  grep -q "admin password (generated, shown once): $pw" "$T/out3" && ok "generated admin password printed" || fail "admin password printed"
  cp "$R3/secrets/secrets.env" "$T/secrets.1"
  rcfg "$R3" ROOT_DOMAIN=chat.example.com ADMIN_EMAIL=ops@example.com >"$T/out3b" 2>&1
  cmp -s "$T/secrets.1" "$R3/secrets/secrets.env" && ! grep -q 'generated' "$T/out3b" && ok "second start reuses them" || fail "secrets reused"
  grep -qxF "PLATFORM_ACCOUNT_PASSWORD=\"$pw\"" "$R3/config/api/backend.env" && ok "generated secrets reach the rendered config" || fail "generated secrets rendered"
  rcfg "$R3" ROOT_DOMAIN=chat.example.com ADMIN_EMAIL=ops@example.com JWT_SECRET=from-env >/dev/null 2>&1
  grep -qxF "SECRET_KEY='from-env'" "$R3/config/api/backend.env" && grep -qxF 'JWT_SECRET=from-env' "$R3/secrets/secrets.env" \
    && ok "a secret in the environment wins and is recorded" || fail "environment secret" "$(grep '^SECRET_KEY' "$R3/config/api/backend.env")"
  rcfg "$T/r4" ROOT_DOMAIN=chat.example.com ADMIN_EMAIL=ops@example.com SECRETS_DIR=/proc/nope >"$T/out4" 2>&1 \
    && fail "no secrets volume and no secrets refused" || { grep -q 'missing: ADMIN_PASSWORD' "$T/out4" && ok "no secrets volume and no secrets refused"; }
  rcfg "$T/r5" ADMIN_EMAIL=ops@example.com >"$T/out5" 2>&1 && fail "ROOT_DOMAIN or PUBLIC_URL required" || ok "ROOT_DOMAIN or PUBLIC_URL required"

  # One origin (PUBLIC_URL).
  R6="$T/r6"; mkdir -p "$R6"
  rcfg "$R6" PUBLIC_URL=http://192.168.1.20:8456/ ADMIN_EMAIL=ops@example.com >"$T/out6" 2>&1 && ok "renders for one origin" || fail "one-origin render" "$(cat "$T/out6")"
  be6="$R6/config/api/backend.env"; fe6="$R6/config/frontend/frontend.env"
  for kv in 'DEFAULT_APP_URL=http://192.168.1.20:8456' 'MINIO_URL=http://192.168.1.20:8456' 'XMPP_SERVICE=ws://192.168.1.20:8456/ws' \
            'XMPP_HOST=192.168.1.20' 'AUTH_COOKIE_DOMAIN=' 'BASE_APP_DOMAIN_NAME=ethora' 'ETHORA_PUBLIC_API_URL=http://192.168.1.20:8456' \
            'MINIO_SECURE_URL=' 'ETHORA_PUBLIC_SECURE_FILES_URL='; do
    grep -qxF "$kv" "$be6" && ok "one origin, backend.env: $kv" || fail "one origin, backend.env: $kv" "$(grep "^${kv%%=*}=" "$be6")"
  done
  for kv in 'VITE_API=__ETHORA_ORIGIN__/v1' 'VITE_APP_XMPP_SERVICE=ws://192.168.1.20:8456/ws' \
            'VITE_APP_CENTRIFUGE_SERVICE=__ETHORA_ORIGIN_WS__/connection/websocket' 'VITE_XMPP_HOST=192.168.1.20'; do
    grep -qxF "$kv" "$fe6" && ok "one origin, frontend.env: $kv" || fail "one origin, frontend.env: $kv"
  done
  grep -q '^:80 {$' "$R6/config/caddy/Caddyfile" && grep -q '^	import single_origin$' "$R6/config/caddy/Caddyfile" \
    && ok "one origin over HTTP: Caddy site :80" || fail "one-origin Caddyfile (http)"
  grep -q '^  - 192.168.1.20$' "$R6/config/xmpp/ejabberd.yml" && ok "the XMPP domain is the origin's host (the web client derives it from the WebSocket URL)" || fail "xmpp domain for an IP origin"
  R7="$T/r7"; mkdir -p "$R7"
  rcfg "$R7" PUBLIC_URL=https://chat.example.com ADMIN_EMAIL=ops@example.com >/dev/null 2>&1
  grep -q '^chat.example.com {$' "$R7/config/caddy/Caddyfile" && grep -qxF 'XMPP_SERVICE=wss://chat.example.com/ws' "$R7/config/api/backend.env" \
    && grep -q '^  - chat.example.com$' "$R7/config/xmpp/ejabberd.yml" && ok "one origin over HTTPS: site block for the host, wss" || fail "one-origin Caddyfile (https)"
  rcfg "$T/r8" PUBLIC_URL=https://chat.example.com/app ADMIN_EMAIL=ops@example.com >/dev/null 2>&1 && fail "PUBLIC_URL with a path refused" || ok "PUBLIC_URL with a path refused"

  # Internal endpoints (Helm chart, external databases).
  R9="$T/r9"; mkdir -p "$R9"
  rcfg "$R9" ROOT_DOMAIN=chat.example.com ADMIN_EMAIL=ops@example.com \
    'ETHORA_MONGO_URI=mongodb://u:p@db.internal:27017/ethora?tls=true' ETHORA_CHAT_DATABASE_URI=mongodb://db.internal/chat_archive \
    ETHORA_REDIS_HOST=cache.internal ETHORA_REDIS_PORT=6380 ETHORA_MYSQL_HOST=sql.internal ETHORA_MYSQL_PORT=3307 ETHORA_MYSQL_USER=ejabberd \
    ETHORA_MINIO_HOST=s3.internal ETHORA_MINIO_PORT=9900 ETHORA_CENTRIFUGO_URL=http://rt.internal:8000 \
    ETHORA_XMPP_URL=http://x.internal:5280 ETHORA_API_URL=http://a.internal:8080 \
    ETHORA_MYSQL_DATABASE=ejdb ETHORA_FRONTEND_URL=http://web.internal:8081 >/dev/null 2>&1
  be9="$R9/config/api/backend.env"; ej9="$R9/config/xmpp/ejabberd.yml"
  for kv in 'MONGO_URI=mongodb://u:p@db.internal:27017/ethora?tls=true' 'CHAT_DATABASE=mongodb://db.internal/chat_archive' REDIS_HOST=cache.internal REDIS_PORT=6380 \
            MAM_MYSQL_HOST=sql.internal MAM_MYSQL_PORT=3307 MAM_MYSQL_USER=ejabberd MINIO_HOST=s3.internal MINIO_PORT=9900 \
            'CENTRIFUGO_API_URL=http://rt.internal:8000/api' 'XMPP_PATH=http://x.internal:5280/api' 'API_INTERNAL_URL=http://a.internal:8080' \
            MAM_MYSQL_DATABASE=ejdb; do
    grep -qxF "$kv" "$be9" && ok "endpoint override, backend.env: $kv" || fail "endpoint override, backend.env: $kv" "$(grep "^${kv%%=*}=" "$be9")"
  done
  grep -qxF 'sql_server: "sql.internal"' "$ej9" && grep -qxF 'sql_username: "ejabberd"' "$ej9" && grep -qxF 'sql_port: 3307' "$ej9" \
    && grep -q 'url: "http://a.internal:8080/v1/chats/track-member"' "$ej9" && ok "endpoint override, ejabberd.yml: sql server/user/port, tracking URLs" \
    || fail "endpoint override, ejabberd.yml" "$(grep -E '^sql_(server|username|port)' "$ej9")"
  grep -qxF 'sql_database: "ejdb"' "$ej9" && grep -qxF 'sql_database: "ejabberd_db"' "$R/config/xmpp/ejabberd.yml" \
    && ok "endpoint override, ejabberd.yml: sql_database (default kept otherwise)" || fail "sql_database" "$(grep '^sql_database' "$ej9")"
  grep -qxF 'API_INTERNAL_URL=http://api:8080' "$be" && ok "default internal API URL is the compose service" || fail "default API_INTERNAL_URL"
  proxies() { grep -o 'reverse_proxy [^ ]*' "$1" | sort -u | tr '\n' ' '; }
  [ "$(proxies "$R/config/caddy/Caddyfile")" = "reverse_proxy api:8080 reverse_proxy centrifugo:8000 reverse_proxy frontend:8080 reverse_proxy minio:9000 reverse_proxy xmpp:5280 " ] \
    && ok "Caddyfile upstreams default to the compose services" || fail "default Caddyfile upstreams" "$(proxies "$R/config/caddy/Caddyfile")"
  [ "$(proxies "$R9/config/caddy/Caddyfile")" = "reverse_proxy a.internal:8080 reverse_proxy rt.internal:8000 reverse_proxy s3.internal:9900 reverse_proxy web.internal:8081 reverse_proxy x.internal:5280 " ] \
    && ok "endpoint override, Caddyfile upstreams follow the internal URLs" || fail "Caddyfile upstream overrides" "$(proxies "$R9/config/caddy/Caddyfile")"
  # A host that is not compose (the Cloudron package): its own site address
  # behind a TLS-terminating proxy, and an extra site of its own.
  R10="$T/r10"; mkdir -p "$R10"
  rcfg "$R10" PUBLIC_URL=https://chat.example.com ADMIN_EMAIL=ops@example.com ETHORA_SITE_ADDRESS=:3000 \
    "$(printf 'ETHORA_EXTRA_SITES=:8081 {\n\tbind 127.0.0.1\n\troot * /srv\n\tfile_server\n}')" \
    API_UID=4242 XMPP_UID=4242 CENTRIFUGO_UID=4242 MYSQL_UID=4242 MINIO_UID=4242 FRONTEND_UID=4242 >"$T/out10" 2>&1
  grep -q '^:3000 {$' "$R10/config/caddy/Caddyfile" && grep -q '^:8081 {$' "$R10/config/caddy/Caddyfile" && ! grep -q '^chat.example.com {$' "$R10/config/caddy/Caddyfile" \
    && grep -qxF 'XMPP_SERVICE=wss://chat.example.com/ws' "$R10/config/api/backend.env" \
    && ok "ETHORA_SITE_ADDRESS and ETHORA_EXTRA_SITES shape the Caddyfile" || fail "site address / extra sites" "$(cat "$T/out10")"
  # Caddy substitutes its environment everywhere in the file, comments included.
  grep -nE '^[[:space:]]*#.*\{\$' "$BUNDLE/Caddyfile" >"$T/cc" && fail "placeholder syntax in a Caddyfile comment" "$(head -n 3 "$T/cc")" || ok "no placeholder syntax in Caddyfile comments"

  # ejabberd.yml must equal what setup-ejabberd-config.sh produces from the
  # same template and values (its production branch), except the tracking URLs
  # which point at the api service here (passed to both sides below).
  I="$T/installer"; mkdir -p "$I/docker"; cp "$T/dist/ejabberd-prod.yml" "$I/docker/ejabberd-prod.yml"
  sed -n '/^if sed --version/,/^fi$/p; /^update_[a-z_]*() {/,/^}$/p' "$DEPLOY/scripts/setup-ejabberd-config.sh" > "$T/installer-fns.sh"
  (
    set +u
    log() { :; }; warn() { :; }
    for kv in "${renv[@]}"; do export "$kv"; done
    export XMPP_DOMAIN=xmpp.chat.example.com API_DOMAIN=api.chat.example.com EJABBERD_DIR="$I"
    export TRACK_MEMBER_URL=http://api:8080/v1/chats/track-member TRACK_LAST_MESSAGE_URL=http://api:8080/v1/chats/track-last-message \
           TRACK_MESSAGE_URL=http://api:8080/v1/chats/archive-message HISTORY_ACCESS_URL=http://api:8080/v1/chats/history-access \
           MESSAGE_AUDIT_URL=http://api:8080/v1/chats/message-audit
    # shellcheck disable=SC1090
    source "$T/installer-fns.sh"
    cfg="$I/docker/ejabberd-prod.yml"
    sed -i "/^hosts:/,/^[a-z]/s/^  -.*/  - $XMPP_DOMAIN/" "$cfg"
    update_api_acl_admin_jid "$cfg"; update_tracking_urls_and_secret "$cfg"
    update_offline_post_urls_and_secret "$cfg"; update_certfiles_path "$cfg"; update_translate_url "$cfg"; update_jwt_auth "$cfg"
  ) >/dev/null 2>&1
  # The installer's sql_password sed has no escaping (its generated passwords
  # never need it), so compare that line separately.
  if diff <(grep -v '^sql_password:' "$I/docker/ejabberd-prod.yml") <(grep -v '^sql_password:' "$R/config/xmpp/ejabberd.yml") >"$T/ej.diff"; then
    ok "ejabberd.yml identical to setup-ejabberd-config.sh's rendering"
  else
    fail "ejabberd.yml differs from setup-ejabberd-config.sh's rendering" "$(head -n 12 "$T/ej.diff")"
  fi
  grep -qxF 'sql_password: "my|sq&l\1/x"' "$R/config/xmpp/ejabberd.yml" && ok "sql_password rendered literally" || fail "sql_password" "$(grep '^sql_password' "$R/config/xmpp/ejabberd.yml")"
  cmp -s "$I/docker/jwt.key" "$R/config/xmpp/jwt.key" && ok "jwt.key identical to the installer's" || fail "jwt.key differs from the installer's"

  if have_docker && docker image inspect "$XMPP_IMAGE" >/dev/null 2>&1; then
    R2="$T/r2"; mkdir -p "$R2"
    args=(); for kv in "${renv[@]}"; do args+=(-e "$kv"); done
    docker run --rm --user "$(id -u):$(id -g)" --entrypoint sh "${args[@]}" -v "$BUNDLE/scripts:/ethora/scripts:ro" \
      -v "$BUNDLE/templates:/ethora/templates:ro" -v "$BUNDLE/Caddyfile:/ethora/Caddyfile:ro" -v "$R2:/out" \
      "$XMPP_IMAGE" /ethora/scripts/render-config.sh >/dev/null 2>"$T/err2" \
      && ok "renders in $XMPP_IMAGE (BusyBox)" || fail "render in $XMPP_IMAGE" "$(cat "$T/err2")"
    diff -r "$R/config" "$R2/config" >"$T/bb.diff" 2>&1 \
      && ok "BusyBox and GNU renderings identical" || fail "BusyBox rendering differs" "$(head -n 12 "$T/bb.diff")"
  else
    skip "BusyBox parity ($XMPP_IMAGE not available)"
  fi
fi

echo "# compose files"
keys_env_example="$(grep -oE '^[A-Z_]+=' "$BUNDLE/.env.example" | tr -d = | grep -vE '^(ETHORA_[A-Z_]*_IMAGE|COMPOSE_PROFILES|HTTP_PORT|HTTPS_PORT)$' | sort)"
keys_config="$(sed -n '/^  config:/,/^  [a-z]/p' "$BUNDLE/docker-compose.yml" | sed -n 's/^      \([A-Z_]*\): .*/\1/p' | sort)"
[ "$keys_env_example" = "$keys_config" ] && ok "config lists every .env.example setting (platforms without a .env)" \
  || fail "config environment differs from .env.example" "$(diff <(echo "$keys_env_example") <(echo "$keys_config") | head -5)"
n="$(grep -cE '^\s+- \./' "$BUNDLE/docker-compose.yml")"
[ "$n" = "3" ] && sed -n '/^  config:/,/^  # -/p' "$BUNDLE/docker-compose.yml" | grep -qE '^\s+- \./Caddyfile' \
  && ok "only config mounts the working tree (scripts, templates, Caddyfile)" || fail "working-tree mounts outside config" "$n"
"$BUNDLE/single/build.sh" --check >/dev/null 2>"$T/sgl.err" && ok "single/docker-compose.yml regenerates identically" \
  || fail "single/docker-compose.yml out of date" "run deploy/compose/single/build.sh; $(head -c 300 "$T/sgl.err")"
for f in deploy/compose/scripts/ deploy/compose/templates/ deploy/compose/Caddyfile; do
  grep -qxF "!$f" "$DEPLOY/../.dockerignore" || fail ".dockerignore lets $f into the compose-init build context"
done; ok ".dockerignore lets the bundle files into the compose-init build context"
grep -q 'compose-init.Dockerfile' "$DEPLOY/../.github/workflows/release-images.yml" && ok "release-images.yml builds ethora-compose-init" || fail "release-images.yml has no compose-init job"

if have_docker; then
  B2="$T/b2"; cp -r "$BUNDLE" "$B2"; rm -f "$B2/.env"
  "$B2/configure.sh" --domain chat.example.com --admin-email ops@example.com --yes >/dev/null 2>&1
  (cd "$B2" && docker compose config --quiet) 2>"$T/err" && ok "docker compose config" || fail "docker compose config" "$(cat "$T/err")"
  (cd "$B2" && docker compose config 2>/dev/null) > "$T/resolved.yml"
  ports="$(grep -cE '^\s+published: ' "$T/resolved.yml")"
  [ "$ports" = "3" ] && ok "only caddy publishes ports (80, 443, 443/udp)" || fail "published ports" "$ports"
  (cd "$B2" && COMPOSE_PROFILES= docker compose config --services 2>/dev/null) | grep -qx caddy && fail "caddy off without the profile" || ok "caddy off without the profile"
  S="$T/single"; mkdir -p "$S"; cp "$BUNDLE/single/docker-compose.yml" "$S/"
  printf 'ROOT_DOMAIN=chat.example.com\nADMIN_EMAIL=ops@example.com\n' > "$S/.env"
  (cd "$S" && docker compose config --quiet) 2>"$T/err" && ok "single file validates with a two-line .env" || fail "single file with a two-line .env" "$(cat "$T/err")"
  (cd "$S" && docker compose config --services 2>/dev/null) | grep -qx caddy && ok "single file runs caddy without a profile" || fail "single file caddy"
  (cd "$S" && rm .env && ROOT_DOMAIN=chat.example.com ADMIN_EMAIL=ops@example.com docker compose config 2>/dev/null) | grep -q 'ADMIN_EMAIL: ops@example.com' \
    && ok "single file takes the settings from the environment too (no .env)" || fail "single file without .env"
  if docker image inspect caddy:2.10-alpine >/dev/null 2>&1 || docker pull -q caddy:2.10-alpine >/dev/null 2>&1; then
    for r in r r6 r7 r9 r10; do
      [ -f "$T/$r/config/caddy/Caddyfile" ] || { skip "Caddyfile $r (not rendered)"; continue; }
      docker run --rm -v "$T/$r/config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.10-alpine \
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >"$T/cv" 2>&1 \
        && ok "rendered Caddyfile validates ($r)" || fail "Caddyfile $r" "$(tail -n 3 "$T/cv")"
    done
  else
    skip "Caddyfile validation (no caddy image)"
  fi
else
  skip "docker compose config / Caddyfile (no Docker)"
fi

echo "# platforms/umbrel and platforms/casaos"
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -qE 'version v?4\.'; then
  P="$BUNDLE/platforms"
  "$P/umbrel/build.sh" --check >/dev/null 2>"$T/u.err" && ok "umbrel package regenerates identically" || fail "umbrel package out of date" "run deploy/compose/platforms/umbrel/build.sh; $(head -c 300 "$T/u.err")"
  "$P/casaos/build.sh" --check >/dev/null 2>"$T/c.err" && ok "casaos app regenerates identically" || fail "casaos app out of date" "run deploy/compose/platforms/casaos/build.sh; $(head -c 300 "$T/c.err")"
  U="$P/umbrel/ethora"
  [ "$(yq '.id' "$U/umbrel-app.yml")" = ethora ] && [ "$(yq '.port' "$U/umbrel-app.yml")" = 8456 ] && [ "$(yq '.deterministicPassword' "$U/umbrel-app.yml")" = true ] \
    && ok "umbrel-app.yml: id, port, deterministic password" || fail "umbrel-app.yml"
  [ "$(yq '.services.app_proxy.environment.APP_HOST' "$U/docker-compose.yml")" = ethora_caddy_1 ] && ok "umbrel app_proxy fronts caddy" || fail "umbrel app_proxy"
  bad="$(yq '.services[] | select(has("image")) | .image' "$U/docker-compose.yml" | grep -vE ':[^@:]+@sha256:([0-9a-f]{64}|PENDING)$' || true)"
  [ -z "$bad" ] && ok "umbrel images pinned as tag@digest" || fail "umbrel images not pinned" "$bad"
  bad="$(yq '.services[] | select(has("volumes")) | .volumes[]' "$U/docker-compose.yml" | grep -vE '^\$\{APP_DATA_DIR\}/data/[a-z-]+:' || true)"
  [ -z "$bad" ] && ok "umbrel volumes are bind mounts under APP_DATA_DIR/data" || fail "umbrel volumes" "$bad"
  for d in $(yq '.services[] | select(has("volumes")) | .volumes[]' "$U/docker-compose.yml" | sed -n 's#^\${APP_DATA_DIR}/data/\([a-z-]*\):.*#\1#p' | sort -u); do
    [ -f "$U/data/$d/.gitkeep" ] || fail "umbrel data/$d/.gitkeep missing"
  done; ok "umbrel bind-mount sources committed (data/*/.gitkeep)"
  grep -q 'PENDING' "$U/docker-compose.yml" && echo "       note: an image is still PENDING in images.env (run platforms/pin-images.sh after the release build)"
  C="$P/casaos/docker-compose.yml"
  for k in id main index port_map icon title category version; do
    [ "$(yq ".[\"x-casaos\"].$k" "$C")" != null ] || fail "casaos x-casaos.$k"
  done; ok "casaos x-casaos has id, main, index, port_map, icon, title, category, version"
  [ "$(yq '.["x-casaos"].main' "$C")" = caddy ] && [ "$(yq '.services.caddy.ports[0].published' "$C")" = "$(yq '.["x-casaos"].port_map' "$C")" ] \
    && ok "casaos main service publishes port_map" || fail "casaos port_map"
  if have_docker; then
    (cd "$P/casaos" && AppID=ethora docker compose config --quiet) 2>"$T/err" && ok "casaos compose validates" || fail "casaos compose" "$(cat "$T/err")"
  fi
else
  skip "umbrel / casaos packages (yq v4 not installed)"
fi

echo "# deploy/cloudron"
CL="$DEPLOY/cloudron"
"$CL/pin.sh" --check >/dev/null 2>"$T/cl.err" && ok "cloudron package pinned to images.env" || fail "cloudron package pins out of date" "run deploy/cloudron/pin.sh"
python3 - "$CL" >"$T/cl.out" 2>&1 <<'PY' && ok "CloudronManifest.json: $(cat "$T/cl.out")" || fail "CloudronManifest.json" "$(cat "$T/cl.out")"
import json, os, re, sys
d = sys.argv[1]; m = json.load(open(os.path.join(d, "CloudronManifest.json")))
for k in ("id", "title", "author", "tagline", "version", "upstreamVersion", "httpPort", "healthCheckPath", "addons", "icon", "description", "postInstallMessage", "changelog"):
    assert k in m, k
assert m["manifestVersion"] == 2 and re.fullmatch(r"\d+\.\d+\.\d+", m["version"]), m["version"]
assert set(m["addons"]) == {"localstorage", "mongodb", "mysql", "redis"}, m["addons"]
assert m["addons"]["redis"].get("noPassword") is True  # the API has no Redis password
for k in ("icon", "description", "postInstallMessage", "changelog"):
    v = m[k]; assert not v.startswith("file://") or os.path.exists(os.path.join(d, v[7:])), v
png = open(os.path.join(d, "icon.png"), "rb").read(32)
assert png[:8] == b"\x89PNG\r\n\x1a\n" and int.from_bytes(png[16:20], "big") == 256 == int.from_bytes(png[20:24], "big")
print(f"{m['id']} {m['version']} ({m['upstreamVersion']}), port {m['httpPort']}, 256px icon")
PY
bash -n "$CL/start.sh" && ok "start.sh parses" || fail "start.sh syntax"
awk '/^FROM /{n=NR} {l[NR]=$0} END{for(i=n;i<=NR;i++) print l[i]}' "$CL/Dockerfile" | grep -qE "^USER " \
  && fail "final stage sets USER (start.sh runs as root; supervisord drops privileges per program)" || ok "final stage runs start.sh as root"
bad=""; for c in $(sed -n 's/^command=//p' "$CL/supervisor/ethora.conf" | grep -oE '/ethora/scripts/[a-z-]+\.sh' | sort -u); do
  [ -f "$BUNDLE/scripts/${c##*/}" ] || bad="$bad $c"; done
[ -z "$bad" ] && ok "supervisor programs run the bundle's scripts" || fail "supervisor programs name missing scripts:$bad"
grep -rn $'\xe2\x80\x94' "$CL" >/dev/null && fail "em dash in deploy/cloudron" || ok "no em dashes in deploy/cloudron"

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
[ "$FAIL" -eq 0 ]
