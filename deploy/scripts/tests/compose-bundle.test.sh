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

echo "# configure.sh"
B="$T/bundle"; cp -r "$BUNDLE" "$B"; rm -f "$B/.env"
cfg() { "$B/configure.sh" "$@" >"$T/out" 2>"$T/err"; }
cfg --domain Chat.Example.com --admin-email ops@example.com --yes
E="$B/.env"
[ -f "$E" ] && ok "wrote .env" || fail "wrote .env" "$(cat "$T/err")"
[ "$(envval ROOT_DOMAIN "$E")" = "chat.example.com" ] && ok "root domain normalised" || fail "root domain" "$(envval ROOT_DOMAIN "$E")"
[ -z "$(envval API_DOMAIN "$E")" ] && ok "hosts left to derive from ROOT_DOMAIN" || fail "hosts derived" "$(envval API_DOMAIN "$E")"
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
        CENTRIFUGO_HMAC_SECRET=chs CENTRIFUGO_ADMIN_PASSWORD=cap CENTRIFUGO_ADMIN_SECRET=cas 'BASE_APP_DISPLAY_NAME=Acme Chat')
  R="$T/r"; mkdir -p "$R"
  env -i PATH="$PATH" TMPDIR="$T" "${renv[@]}" TEMPLATES_DIR="$BUNDLE/templates" XMPP_DIST_DIR="$T/dist" \
    CONFIG_OUT_DIR="$R/config" MYSQL_INITDB_DIR="$R/initdb" sh "$BUNDLE/scripts/render-config.sh" >"$T/out" 2>"$T/err" \
    && ok "renders (template from $TPL)" || fail "render" "$(cat "$T/err")"
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
            'MINIO_URL=https://files.chat.example.com' ENABLE_SWAGGER=true BASE_APP_DOMAIN_NAME=app 'PLATFORM_ACCOUNT_PASSWORD="p&w|d\1"' \
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
      -v "$BUNDLE/templates:/ethora/templates:ro" -v "$R2:/out" "$XMPP_IMAGE" /ethora/scripts/render-config.sh >/dev/null 2>"$T/err2" \
      && ok "renders in $XMPP_IMAGE (BusyBox)" || fail "render in $XMPP_IMAGE" "$(cat "$T/err2")"
    diff -r "$R/config" "$R2/config" >"$T/bb.diff" 2>&1 \
      && ok "BusyBox and GNU renderings identical" || fail "BusyBox rendering differs" "$(head -n 12 "$T/bb.diff")"
  else
    skip "BusyBox parity ($XMPP_IMAGE not available)"
  fi
fi

echo "# compose file and Caddyfile"
if have_docker; then
  B2="$T/b2"; cp -r "$BUNDLE" "$B2"; rm -f "$B2/.env"
  "$B2/configure.sh" --domain chat.example.com --admin-email ops@example.com --yes >/dev/null 2>&1
  (cd "$B2" && docker compose config --quiet) 2>"$T/err" && ok "docker compose config" || fail "docker compose config" "$(cat "$T/err")"
  (cd "$B2" && docker compose config 2>/dev/null) > "$T/resolved.yml"
  grep -q 'API_DOMAIN: api.chat.example.com' "$T/resolved.yml" && ok "hosts derive from ROOT_DOMAIN in compose" || fail "compose host derivation"
  ports="$(grep -cE '^\s+published: ' "$T/resolved.yml")"
  [ "$ports" = "3" ] && ok "only caddy publishes ports (80, 443, 443/udp)" || fail "published ports" "$ports"
  (cd "$B2" && COMPOSE_PROFILES= docker compose config --services 2>/dev/null) | grep -qx caddy && fail "caddy off without the profile" || ok "caddy off without the profile"
  if docker image inspect caddy:2.10-alpine >/dev/null 2>&1 || docker pull -q caddy:2.10-alpine >/dev/null 2>&1; then
    docker run --rm -e ACME_EMAIL=ops@example.com -e CADDY_GLOBAL_OPTIONS= -e API_DOMAIN=api.chat.example.com \
      -e WEB_DOMAIN=app.chat.example.com -e XMPP_DOMAIN=xmpp.chat.example.com -e FILES_DOMAIN=files.chat.example.com \
      -v "$BUNDLE/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.10-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >"$T/cv" 2>&1 \
      && ok "Caddyfile validates" || fail "Caddyfile" "$(tail -n 3 "$T/cv")"
  else
    skip "Caddyfile validation (no caddy image)"
  fi
else
  skip "docker compose config / Caddyfile (no Docker)"
fi

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
[ "$FAIL" -eq 0 ]
