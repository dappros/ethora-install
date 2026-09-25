# Troubleshooting

Symptoms, causes and fixes collected from real installs. Start with `deploy/scripts/health-check.sh`; its output names the failing component.

## 1. DNS Not Resolving

**Problem**: Health checks fail because domains don't resolve.

**Solution**: Ensure DNS A records are configured and propagated:
```bash
dig api.yourdomain.com
```

## 2. Port Already in Use

**Problem**: Error about ports being in use.

**Solution**: Check what's using the port and stop it:
```bash
sudo lsof -i :8080
sudo systemctl stop <service>
```

## 3. SSL Certificate Issues

**Problem**: Certbot fails to obtain certificates.

**Solution**: 
- Ensure DNS is configured correctly
- Ensure port 80 is accessible (for HTTP-01 challenge)
- Check firewall settings
- Try manual certificate generation:
  ```bash
  sudo certbot certonly --standalone -d api.yourdomain.com
  ```
- For hosted tenant apps on `*.chat.yourdomain.com`, use a public wildcard cert via DNS-01 challenge and set:
  - `ssl.hosted_apps_cert_path`
  - `ssl.hosted_apps_key_path`
- Do not switch the whole stack to `ssl.method: provided` just to support hosted apps unless you want all domains to use the same provided cert.

## 4. Docker Services Not Starting

**Problem**: Docker containers fail to start.

**Solution**:
```bash
# Check Docker logs
docker-compose -f deploy/docker-compose.enterprise.yml logs

# Check Docker status
docker-compose -f deploy/docker-compose.enterprise.yml ps

# Restart services
docker-compose -f deploy/docker-compose.enterprise.yml restart
```

## 4a. Apple Silicon / ARM64 + Ejabberd (XMPP) fails to build/start

**Problem**: On ARM64 hosts (Apple Silicon, ARM VMs), `xmpp` (Ejabberd) can fail to start/build with confusing errors (sometimes `apk add ... exit code 255`).

**Cause**: Our Ejabberd service is pinned to `platform: linux/amd64` for consistency. This requires **working amd64 emulation** (binfmt/qemu or Docker Desktop Rosetta).

**Quick preflight**:

```bash
docker run --rm --platform linux/amd64 alpine:3.19 uname -m
# expected: x86_64
```

**Fix (Linux Docker Engine)**:

```bash
sudo docker run --privileged --rm tonistiigi/binfmt --install all
```

**Fix (Docker Desktop on Apple Silicon)**:
- Enable “Use Rosetta for x86/amd64 emulation” (wording may vary by Docker Desktop version).

## 4c. Ubuntu ARM64 VM: `yq` missing / wrong version (v3 vs v4)

Our deploy scripts require **yq v4** because we use `yq eval ...`.

**Symptoms**:
- install/validate scripts fail to parse `deploy.yml`
- errors mention `yq eval` or YAML validation failing even though the file looks correct

**Fix**:
- Re-run installer (it now installs yq v4 automatically), or install yq v4 manually.
- Example (ARM64):
  - `wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64`
  - `chmod +x /usr/local/bin/yq`
  - `yq --version` should show `version v4.x.x`

## 4d. Ubuntu ARM64 VM: Ejabberd image lacks arm64 manifest

Some legacy Ejabberd images do not publish an ARM64 manifest. For ARM64 hosts/VMs, we use the modern multi-arch image:

- `ghcr.io/processone/ejabberd:26.04`

This avoids installation failures on Apple Silicon / ARM64 environments.

## 4e. Ejabberd MySQL auth fails: `Access denied for user 'root'@'<container-ip>' (using password: YES)`

**Symptoms** (in `docker logs deploy-xmpp-1`):
- `p1_mysql_conn: init error 1045: ... Access denied for user 'root'@'172.x.x.x' (using password: YES)`
- `:mysql connection failed ... Retry after: 5 seconds`

**Cause**:
- The official `mysql` image creates `root@localhost` by default. Since ejabberd runs in a *different* container, it connects as `root@<container-ip>` and MySQL rejects it (even if the password is correct).
- This is especially common when you have a persistent MySQL data dir (`ejabberd-docker/docker-data/my-sql/`): init scripts/env only run on the very first start.

**Fix (recommended, fresh installs)**:
- Ensure `deploy/docker-compose.enterprise.yml` includes:
  - `MYSQL_ROOT_HOST: "%"`

**Fix (existing installs with an already-initialized MySQL volume)**:
- Create/repair `root@'%'` inside the MySQL container (important: `CREATE USER IF NOT EXISTS` does **not** update an existing password), then restart `xmpp`:

```bash
sudo bash -lc 'source "/home/ubuntu/ethora/deploy/.deploy.env"; \
  docker exec -i deploy-mysql-1 mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e "CREATE USER IF NOT EXISTS '\''root'\''@'\''%'\'' IDENTIFIED WITH mysql_native_password BY '\''$MYSQL_ROOT_PASSWORD'\''; \
      ALTER USER '\''root'\''@'\''%'\'' IDENTIFIED WITH mysql_native_password BY '\''$MYSQL_ROOT_PASSWORD'\''; \
      GRANT ALL PRIVILEGES ON *.* TO '\''root'\''@'\''%'\'' WITH GRANT OPTION; \
      FLUSH PRIVILEGES; \
      SELECT user,host,plugin FROM mysql.user WHERE user='\''root'\'';"'

sudo bash -lc 'source "/home/ubuntu/ethora/deploy/.deploy.env"; \
  docker-compose -f "/home/ubuntu/ethora/deploy/docker-compose.enterprise.yml" restart xmpp'
```

## 4f. Update stops at "Starting/refreshing docker services": MinIO image cannot be pulled from quay.io

**Symptoms** (in the update log, services untouched, API still on the old
version):

```
Image quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z Error unknown: failed to resolve reference
"quay.io/minio/minio:RELEASE...": unexpected status from HEAD request to https://quay.io/v2/minio/minio/manifests/RELEASE...: 401 UNAUTHORIZED
```

**Cause**: MinIO moved off Docker Hub, so the compose file pulls the release
from quay.io. A host that never pulled that reference has to negotiate a
quay.io token on first pull, and quay.io sometimes refuses that negotiation
(the `401` is the token challenge, which docker then fails to complete).
Hosts that already have the image do not pull and are not affected.
`update.sh` stops before any build or restart, so nothing is half-deployed:
the live tree already has the new source, the running services are the old
build.

**Fix**: the release is byte-identical to the last `minio/minio` image from
Docker Hub, which most hosts still have. If the IDs match, tag it and re-run
the update:

```bash
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -i minio
# minio/minio:latest 14cea493d9a3       <- same ID as on a host that pulled from quay
docker tag minio/minio:latest quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z
sudo ... deploy/scripts/update.sh --ref <line>     # same command as before
```

If there is no local image, copy it from another host of the same line
(`docker save quay.io/minio/minio:RELEASE... | gzip` there, `docker load`
here), or retry the pull later; `docker pull quay.io/minio/minio:RELEASE...`
by hand shows whether quay.io is answering again.

## 4b. Docker Compose YAML option errors

**Problem**: Compose errors like:

> `services.xmpp.build contains unsupported option: 'platform'`

**Cause**: Different Docker Compose builds support different YAML options. Some do not support `build.platform`.

**Solution**: We rely on the **service-level** `platform: linux/amd64` for cross-arch runs/builds. If you see a `build.platform` error, update your monoserver repo to a version that does not include that field.

## 5. Backend Not Starting

**Problem**: PM2 shows backend as stopped.

**Solution**:
```bash
# Check PM2 logs
pm2 logs backend

# Restart backend
pm2 restart backend

**Note on hotfixes:** The backend runs from compiled output in `backend/dist/` (PM2 starts `./dist/app.js`).
If you SCP/edit backend source files under `backend/src/`, you must rebuild, then restart:
```bash
cd /home/ubuntu/deptest/ethora-backend/backend
npm run build
pm2 restart backend --update-env
```

# Check environment variables
pm2 env backend
```

## 7. XMPP chats show “spinner”, broadcast says “sent” but room looks empty, or `room_not_found`

This is almost always a **room existence mismatch**:

- The UI can show a chat because it exists in **MongoDB**.
- Ejabberd may not have the room yet, so clients fail to join until something else triggers creation.

**Symptoms:**
- Admin panel / frontend shows the chat, but it loads forever (spinner).
- Broadcast job returns success but nothing appears in chat.
- `ejabberdctl get_room_occupants_number "<room>" "conference.<domain>"` returns `{error,room_not_found}`.

**Root cause (design + security):**
- Ethora is multi-tenant; we intentionally keep **room creation controllable**.
- Normal users should **NOT** create rooms by joining them.
- Rooms and users must follow `${appId}_*` naming to preserve tenant boundaries and future migrations.

**What to verify (Ejabberd config):**
- Your active ejabberd config must contain an admin-only room create rule and use it in `mod_muc`:
  - `access_rules.muc_create_admin: allow admin`
  - `modules.mod_muc.access_create: muc_create_admin`
  - `modules.mod_muc.access_persistent: muc_create_admin`

**Backend behavior:**
- The backend is responsible for creating the room in ejabberd before clients join (or on-demand as part of “send message” flows).
- The backend XMPP WS sender contains a fallback: when join is denied by policy, it creates the room server-side as admin and retries.

**Quick checks:**
- Is the room present in ejabberd?
  - `docker exec deploy-xmpp-1 ejabberdctl get_room_options "<roomName>" "conference.<domain>"`
  - `docker exec deploy-xmpp-1 ejabberdctl get_room_occupants_number "<roomName>" "conference.<domain>"`
- Does a non-admin join attempt show “Room creation is denied by service policy”?
  - This indicates the policy is working; the fix is to ensure backend creates rooms reliably.

## 7a. Uptime `xmpp_muc_echo` check fails with “Database error” or “Room creation is denied by service policy”

If uptime shows `local:xmpp_muc_echo` as red, common failure modes and the *right* mental model:

- **MySQL vs Mnesia**
  - Ethora uses **MySQL** for persistent Ejabberd data (MAM, MUC room metadata, users, etc).
  - Ejabberd still uses **Mnesia for small runtime/online-state tables** (for example `muc_online_room`).
  - This is normal: “MySQL everywhere” for persistence does **not** mean “no Mnesia at all”.

- **Symptom: `XMPP_ROOM_CREATE_FAILED` with `{error,"Database error"}`**
  - This can happen when using Ejabberd admin commands / HTTP API room creation (`create_room*` / `create_room_with_opts`) and Ejabberd returns a generic error.
  - **Preferred approach (matches Ethora backend behavior)**: create rooms by **joining them as the admin XMPP user** (server-side), not by relying on HTTP API room creation.

- **Symptom: `XMPP_JOIN_ERROR ... Room creation is denied by service policy`**
  - This is expected for non-admin users because room creation-on-join is disabled by design.
  - If uptime checks join as user1/user2 and the room doesn’t exist yet, they will fail.
  - Fix: ensure the room is created first by the **admin account**, and keep the admin “presence” active until at least one non-admin occupant has joined.

- **Symptom: Ejabberd logs show `Using module mod_http_api for host xmpp, but it isn't configured`**
  - Ejabberd routes some HTTP modules by the **HTTP Host header** (vhost).
  - When calling Ejabberd from another container via Docker DNS (`http://xmpp:5280/api`), the Host can become `xmpp`, which is not a configured vhost (we use `localhost`).
  - If you need to call Ejabberd HTTP API from containers, ensure the request uses `Host: localhost`.
    - Note: in Node, `fetch()` (undici) does not allow overriding `Host`; use `node:http`/`node:https` instead if you must force Host.

## 7b. Signup / journey test fails with "XMPP user provisioning failed" or "xmpp registration failed"

When creating users (signup, synthetic journey), the backend must register them in Ejabberd via the HTTP API. If that fails, you get `XMPP_REGISTER_FAILED` / 502.

**Verify:**
1. **Backend .env** – `XMPP_PATH`, `XMPP_HOST`, `XMPP_ADMIN`, `XMPP_PASS` are set. Production uses `XMPP_PATH=http://127.0.0.1:5280/api`.
2. **Ejabberd admin ACL** – `acl.apicommands` must include `admin@<XMPP_DOMAIN>`. Run `setup-ejabberd-config.sh` and restart xmpp.
3. **Connectivity** – Backend (PM2) must reach Ejabberd. Test: `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5280/api/register` (expect 400/405, not connection refused).
4. **Host match** – `XMPP_HOST` must match Ejabberd `hosts` (e.g. `xmpp.chat.example.com`).

**Quick test:**
```bash
# From the host (where backend runs)
curl -X POST http://127.0.0.1:5280/api/register \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n 'admin@xmpp.chat.example.com:YOUR_ADMIN_PASS' | base64)" \
  -d '{"user":"test123","host":"xmpp.chat.example.com","password":"testpass"}'
```
- 200/201 = success
- 403 = ACL/permission issue (check apicommands)
- Connection refused = Ejabberd not listening on 5280 or port not published

**Important notes from a real incident (Mar 2026):**
- Ejabberd custom source modules such as `mod_ethora` must actually be compiled and loaded at container startup. If source changes are deployed but the xmpp container still behaves as before, check `docker logs deploy-xmpp-1` for lines like `Compiling custom module: mod_ethora/mod_ethora` and `*** Starting mod_ethora`.
- If backend logs show `XMPP_REGISTER_FAILED` but the Ejabberd HTTP API returns `409 User ... already registered`, treat that as an idempotent success path, not a hard provisioning failure. The backend now recovers by syncing the password with `change_password`.
- If room creation or uptime heartbeat reports `wrong app name`, verify whether Ejabberd actually created the room anyway. In this incident, the fallback path succeeded server-side, but backend/uptime still reported failure until they were updated to accept "room already exists after fallback" as success.
- Useful log filters:
  - `pm2 logs backend --lines 200 | rg "xmpp.register|\\[chat.create\\]|wrong app name"`
  - `docker logs --tail 200 deploy-xmpp-1 | rg "mod_ethora|API call register|Created MUC room|wrong app name"`

## 7c. Admin panel Apps list “Chats” stays 0 (but chat works)

In Ethora UI, the Apps list “Chats” value is used as a **message counter** (not “rooms count”).

How it works:
- Ejabberd custom module `mod_track_last_message` POSTs to the backend endpoint:
  - `POST /v1/chats/track-last-message`
- The backend validates a shared secret (`XMPP_SECRET`) and increments `appstatdayli.chats`.
- The Apps list stats (`GET /v1/apps`) aggregates `appstatdayli.chats` into `totalChats`.

Localhost gotcha (Docker networking):
- Ejabberd runs in Docker. It cannot reach the host backend via `http://localhost:8080`.
- Local installs must configure the tracking URL as:
  - `http://host.docker.internal:<BACKEND_PORT>/v1/chats/track-last-message`

Quick checks:
- Verify ejabberd config contains the correct module config (and secret):
  - `mod_track_last_message.url` points to `host.docker.internal` in localhost installs
  - `mod_track_last_message.secret` matches backend `XMPP_SECRET`
- Send a message in chat, then check:
  - `docker exec deploy_mongo_1 mongosh --quiet ethora_test --eval 'db.appstatdayli.find().sort({date:-1}).limit(5).toArray()'`

## 6. Frontend Build Fails

**Problem**: Frontend build errors.

**Solution**:
```bash
cd ethora-app-reactjs
rm -rf node_modules
npm install
npm run build
```

## 8. Locked out of the admin account, or no email configured

Symptoms: "forgot password" on the login page says the installation does
not send email; an admin clicked "Reset password" on the Users page and the
user never received anything; the seed `admin@example.com` owner cannot sign
in; the authenticator is gone.

Without `integrations.postmark` no reset email is ever sent. Recovery is on
the host, with the deploy directory's `scripts/admin-reset.sh`:

```bash
cd <deploy dir of the live install>
sudo ./scripts/admin-reset.sh list                                    # who the superadmins are, and whether each has a password
sudo ./scripts/admin-reset.sh temp-password --email admin@example.com # prints a one-time password; new one is chosen at login
sudo ./scripts/admin-reset.sh clear-mfa     --email admin@example.com # lost authenticator
sudo ./scripts/admin-reset.sh set-email     --email admin@example.com --new-email ops@example.com
```

`list` showing `password=NONE temp-password pending` means a reset was
triggered but its email never went out (older releases reported success
regardless); `temp-password` issues a fresh one. Full reference:
[deploy/README.md](../../deploy/README.md#recover-or-manage-the-superadmin-from-the-host).

## Log Files

- Deployment log: `deploy/deploy.log`
- PM2 logs: `pm2 logs`
- Docker logs: `docker-compose logs`
- Nginx logs: `/var/log/nginx/`

## Manual Service Checks

```bash
# Check Docker services
docker-compose -f deploy/docker-compose.enterprise.yml ps

# Check PM2 processes
pm2 list
pm2 logs

# Check Nginx
sudo systemctl status nginx
sudo nginx -t

# Check SSL certificates
sudo certbot certificates
```
