# Ethora Core on Coolify

[Coolify](https://coolify.io) is a self-hosted PaaS with its own reverse
proxy (Traefik by default). Ethora Core runs on it in two ways, both from
the compose bundle in this directory's parent:

1. **A Docker Compose application from the public installer repository**
   (`github.com/dappros/ethora-install`, base directory `/deploy/compose`).
   Coolify clones the repository, so the bundle's `scripts/` and
   `templates/` are bind-mounted from the checkout. This is the supported
   way; the steps below were run end to end on Coolify 4.3.23 and the
   bundle's `verify` check passed through Coolify's proxy.
2. **The one-click service template** `ethora-core.yaml` in this directory:
   the same compose file with the scripts and templates carried inline (see
   "One-click template" below). Draft: it parses and deploys on Coolify,
   but it is not yet in Coolify's template catalogue.

Either way the bundled Caddy stays off (Coolify's proxy terminates TLS and
routes the five hosts), the data lives in Docker volumes prefixed with the
resource's uuid, and the installed stack is the one described in
`../../README.md`.

Server: 2 vCPU and 4 GB RAM for Ethora Core on top of what Coolify needs
itself (2 GB); 8 GB in total is comfortable.

## DNS

Point the five hosts at the Coolify server before deploying, all plain A
records (a wildcard `*.chat.example.com` covers them):

| Host | Routed to |
|---|---|
| `api.chat.example.com` | `api:8080` |
| `app.chat.example.com` | `frontend:8080`; `centrifugo:8000` for `/connection/websocket` |
| `xmpp.chat.example.com` | `xmpp:5280`, paths `/ws` and `/bosh` only |
| `files.chat.example.com` | `minio:9000` |
| `secure-files.chat.example.com` | `api:8080` (chat attachments, gated by chat membership; the API serves this host itself) |

`chat.example.com` is the root domain; every host derives from it. For a
test without DNS use `<server IP with dashes>.sslip.io` as the root.

## Way 1: Docker Compose application from git (supported)

In Coolify: project > environment > **+ New** > **Public Repository**.

1. Repository `https://github.com/dappros/ethora-install`, branch `main`,
   build pack **Docker Compose**, base directory `/deploy/compose`,
   compose file `/docker-compose.yml`. Coolify reads the compose file and
   lists its services. (Git deployments accept only public repositories
   this way; the branch must be one the sync publishes, `main` or a
   release line such as `2610`.)
2. **Domains**, one per routed service (the port after the host tells
   Coolify's proxy which container port to use):
   - `api`: `https://api.chat.example.com:8080,https://secure-files.chat.example.com:8080`
   - `frontend`: `https://app.chat.example.com:8080`
   - `centrifugo`: `https://app.chat.example.com:8000/connection/websocket`
   - `xmpp`: `https://xmpp.chat.example.com:5280/ws,https://xmpp.chat.example.com:5280/bosh`
   - `minio`: `https://files.chat.example.com:9000`
   Coolify warns that `app.` and `xmpp.` are used twice; confirm (in the API:
   `force_domain_override: true`). Traefik gives the longer path rule
   priority, so `/connection/websocket` reaches centrifugo and everything
   else on `app.` reaches the frontend; on `xmpp.` only `/ws` and `/bosh`
   are routed, which keeps ejabberd's `/api` and `/admin` internal.
3. **Advanced**: turn **Preserve Repository During Deployment** on and
   **Strip Prefix** off. The first keeps the checkout under
   `/data/coolify/applications/<uuid>/`, which is where the bundle's
   `./scripts` and `./templates` bind mounts resolve; without it those
   directories are created empty and `config` exits with 2
   (`can't open '/ethora/scripts/render-config.sh'`), `mongo-init` with
   127 (checked on a fresh application). The second keeps
   `/ws`, `/bosh` and `/connection/websocket` on the request that reaches
   the container.
4. **Environment variables**, developer view: paste `.env.example` from the
   bundle, then
   - set `ROOT_DOMAIN`, `ADMIN_EMAIL` and every empty secret (a random
     value of 32+ letters and digits each; `./configure.sh --no-caddy
     --domain ... --admin-email ... --out /tmp/ethora.env` on any machine
     with bash writes a complete file to paste);
   - set `API_DOMAIN`, `WEB_DOMAIN`, `XMPP_DOMAIN`, `FILES_DOMAIN` and
     `SECURE_FILES_DOMAIN` to the five hosts, or delete those five lines.
     Do not leave them empty:
     Coolify resolves the compose defaults (`${XMPP_DOMAIN:-xmpp.${ROOT_DOMAIN}}`)
     itself at parse time and writes the current value, so an empty
     override reaches the containers as an empty variable;
   - leave `COMPOSE_PROFILES` empty (no bundled Caddy).
   Coolify also generates `SERVICE_URL_*` / `SERVICE_FQDN_*` for the routed
   services; the bundle does not read them.
5. **Deploy**. The first deployment pulls the images (about 4 GB on disk)
   and takes a few minutes; it ends when `docker compose up` returns, i.e. after
   `init` has finished (its log, under the `init` container, ends with
   `done`). Certificates are requested by Coolify's proxy as soon as each
   container is healthy. `config`, `mongo-init` and `init` are one-shot
   containers that exit with 0; Coolify excludes `restart: "no"` services
   from the application's health status.

Then open `https://app.chat.example.com` and sign in with `ADMIN_EMAIL`
and `ADMIN_PASSWORD`.

### The same with the API

```bash
COOLIFY=https://coolify.example.com/api/v1; TOKEN=...   # Keys & Tokens, root or write permission
R=chat.example.com
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' $COOLIFY/applications/public -d "{
  \"project_uuid\":\"$PROJECT\", \"server_uuid\":\"$SERVER\", \"environment_name\":\"production\",
  \"name\":\"ethora-core\",
  \"git_repository\":\"https://github.com/dappros/ethora-install\", \"git_branch\":\"main\",
  \"build_pack\":\"dockercompose\", \"base_directory\":\"/deploy/compose\", \"docker_compose_location\":\"/docker-compose.yml\",
  \"docker_compose_domains\":[
    {\"name\":\"api\",\"domain\":\"https://api.$R:8080\"},
    {\"name\":\"frontend\",\"domain\":\"https://app.$R:8080\"},
    {\"name\":\"centrifugo\",\"domain\":\"https://app.$R:8000/connection/websocket\"},
    {\"name\":\"xmpp\",\"domain\":\"https://xmpp.$R:5280/ws,https://xmpp.$R:5280/bosh\"},
    {\"name\":\"minio\",\"domain\":\"https://files.$R:9000\"}],
  \"is_preserve_repository_enabled\":true, \"is_stripprefix_enabled\":false,
  \"is_auto_deploy_enabled\":false, \"instant_deploy\":false}"
# -> {"uuid":"<app>"}. Then send the domains once more with PATCH
# /applications/<app> (same docker_compose_domains, plus
# "force_domain_override": true): the create call stores the hosts but
# drops the :port suffixes; the update call stores them as port overrides.
```

Environment variables go to `PATCH /applications/<app>/envs/bulk` with
`{"data":[{"key":"ROOT_DOMAIN","value":"chat.example.com","is_literal":true}, ...]}`
(every key of `.env.example`, values as above), and
`POST /deploy?uuid=<app>` starts the deployment; `GET /deployments/<uuid>`
returns its status and log. The API is off by default: Settings >
Advanced > API, then Keys & Tokens > API Tokens.

### Check

From the Coolify server, the bundle's own end-to-end check, run against
Coolify's copy of the compose project:

```bash
D=/data/coolify/applications/<app uuid>
docker compose --env-file $D/.env --project-name <app uuid> --project-directory $D \
  -f $D/docker-compose.yml --profile verify run --rm verify
```

It goes through the public URLs: certificates, web app, API docs, admin
login, licence state, a room created and a message sent over
`wss://xmpp.<root>/ws`, a file uploaded and read back from `files.<root>`.

### Update

Redeploy in Coolify. It pulls the images of the release line pinned in the
environment variables (`ETHORA_*_IMAGE`) and re-runs the one-shot steps,
which are idempotent. To move to a newer line change the three image tags.

### Data

The named volumes are `<app uuid>_mongo`, `_mysql`, `_minio`, `_redis`
(see "Where the data is" in the bundle README; the backup commands apply
with these names). `/data/coolify/applications/<app uuid>/.env` holds every
secret; Coolify keeps a copy in its database.

## Way 2: one-click template (draft)

`ethora-core.yaml` is a Coolify service template: the bundle's compose
file with the bundled proxy removed, the 7 scripts and 3 templates carried
inline as `content:` bind files (57 KB of the file's 71 KB; YAML anchors
share each file between the services that mount it), every secret as a
Coolify magic variable (`SERVICE_PASSWORD_64_JWT`, `SERVICE_USER_MINIO`,
...), and `ROOT_DOMAIN` and `ADMIN_EMAIL` as the two required inputs. It is
generated: edit `ethora-core.in.yaml` and run `./build-template.sh`
(`--check` verifies the checked-in file, and the bundle test suite runs
that).

Until it is in Coolify's catalogue, use it as a custom service: **+ New** >
**Docker Compose Empty**, paste the file, save, then before the first
deploy:

1. Domains: `api` -> `https://api.<root>,https://secure-files.<root>`,
   `frontend` -> `https://app.<root>`, `xmpp` -> `https://xmpp.<root>/ws`,
   `minio` -> `https://files.<root>`, `centrifugo` ->
   `https://app.<root>/connection/websocket` (the ports and paths are
   declared in the template, only the hosts are needed). The hosts must be
   these five: they derive from `ROOT_DOMAIN` inside the
   stack. Coolify's `SERVICE_FQDN_*` values are deliberately not used for
   them, because Coolify appends a route's path to them
   (`xmpp.example.com/ws` is not an XMPP host).
2. On the `xmpp` and `centrifugo` services turn **Strip Prefix** off
   (service > that application > Advanced). Coolify's default for a
   service application strips the route's path before the container sees
   it, and ejabberd needs `/ws` (centrifugo `/connection/websocket`) on the
   request; with the default, XMPP logins fail and the web app's real-time
   channel falls back to the frontend.
3. Environment variables: `ROOT_DOMAIN`, `ADMIN_EMAIL`. Everything else is
   generated; `SERVICE_PASSWORD_ADMIN` is the admin panel password.
4. Deploy. The stack comes up in the bundle's order; `init` exits with 0
   once the base app and admin exist.

With the API: `POST /services` with `docker_compose_raw` (the file,
base64), then `PATCH /services/<uuid>` with `urls` (as above,
`force_domain_override: true`), `PATCH /services/<uuid>/applications/<app uuid>`
with `{"is_stripprefix_enabled": false}` for `xmpp` and `centrifugo` (the
application uuids come from `GET /services/<uuid>`),
`PATCH /services/<uuid>/envs/bulk` for the two inputs, and
`POST /services/<uuid>/start`.

Check it like the git-based way, with the service's project
(`/data/coolify/services/<uuid>`) and `run --rm api verify` instead of the
`verify` profile (the template has no `verify` service; `api-entrypoint.sh
verify` is the same check). Run this way on Coolify 4.3.23, every check
passed.

To submit it to Coolify: `templates/compose/ethora-core.yaml` in
`github.com/coollabsio/coolify` plus a logo under `public/svgs/`; the
header comments (`documentation`, `slogan`, `category`, `tags`, `logo`,
`port`) are the catalogue entry. Coolify asks for pinned image tags (done)
and for the project to have 1,000 GitHub stars.

## Known differences from the bundle's own proxy

- `api.<root>/metrics` is reachable (the Caddyfile answers 404 there).
  Coolify has no per-path deny; put the API behind an allow-list in the
  application if Prometheus metrics must stay private.
- `files.<root>`: Traefik passes the `Host` header through, which MinIO's
  presigned URLs need; uploads have no size limit at the proxy.
- `xmpp.<root>` in the git-based way exposes `/ws` and `/bosh`; the
  template declares `/ws` only, add `/bosh` as a second domain on the
  `xmpp` service if BOSH clients are needed.
