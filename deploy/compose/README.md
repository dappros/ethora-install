# Ethora Core with Docker Compose

This directory runs [Ethora](https://ethora.com) Core on any Docker host with
nothing else installed: an API, a web chat and admin panel, an XMPP server
and file storage, behind Caddy with Let's Encrypt certificates. Copy the
directory to the server, answer two questions, start it.

It is the second way to run Ethora Core, next to the host installer
(`deploy/scripts/install.sh`). Both run the same images from the same
configuration templates; this one needs only Docker.

## Install

On a server with Docker Engine 24+ and the Compose plugin (2.24+), ports 80
and 443 open, 2 vCPU and 4 GB RAM:

```bash
cd ethora-compose            # this directory, copied to the server
./configure.sh --domain chat.example.com --admin-email you@example.com
docker compose up -d
```

`configure.sh` writes `.env`: the hosts derive from your root domain, every
secret is generated, and the admin password is printed once. The first start
pulls the images and takes a few minutes; `docker compose logs -f init` ends
with `done` when the base app and admin account are ready. Then open
`https://app.chat.example.com` and sign in with your e-mail and that password.

Before you start, create five DNS records pointing at the server, all plain
`A` (or `AAAA`) records, no proxy:

| Record | Points to |
|---|---|
| `api.chat.example.com` | your server's IP |
| `app.chat.example.com` | your server's IP |
| `xmpp.chat.example.com` | your server's IP |
| `files.chat.example.com` | your server's IP |
| `secure-files.chat.example.com` | your server's IP |

(`chat.example.com` is your root; every host derives from it. A wildcard
`*.chat.example.com` record covers all five. `secure-files.` serves chat
attachments, gated by chat membership; `SECURE_FILES_DOMAIN=off` in `.env`
drops it and attachments go to the public `files.` bucket.)

**No domain yet?** Use a magic DNS name for a test install: with server IP
`203.0.113.10`, pass `--domain 203-0-113-10.sslip.io`. It resolves
everywhere, gets a real Let's Encrypt certificate, and needs no DNS setup.

No `configure.sh` (a platform that only takes a compose file and variables):
copy `.env.example` to `.env`, or enter its values in the platform, and set
`ROOT_DOMAIN` and `ADMIN_EMAIL`. Secrets left empty are generated on the
first start and kept in the `secrets` volume; the admin password is printed
once by `docker compose logs config`.

### One file instead of this directory

[`single/docker-compose.yml`](single/docker-compose.yml) is the same stack in
one file: nothing else on disk, for "paste a stack" screens (Portainer) and
for anyone copying a compose file from a web page. Save it in an empty
directory next to a two-line `.env`:

```bash
curl -fsSLo docker-compose.yml https://raw.githubusercontent.com/dappros/ethora-install/main/deploy/compose/single/docker-compose.yml
printf 'ROOT_DOMAIN=chat.example.com\nADMIN_EMAIL=you@example.com\n' > .env
docker compose up -d
docker compose logs config | grep 'admin password'
```

Its scripts and templates come from the `ethora-compose-init` image (the
xmpp image of the same release plus this directory's `scripts/`,
`templates/` and `Caddyfile`), which renders the configuration and hands
every other service its start script through the `config` volume. Every
variable of `.env.example` works there too. Caddy always runs in the single
file; behind a proxy of your own, start it with
`docker compose up -d --scale caddy=0`. The file is generated from
`docker-compose.yml` by `single/build.sh`, and the tests fail when it is out
of date.

### One address instead of five hosts

Set `PUBLIC_URL` instead of `ROOT_DOMAIN` (`./configure.sh --public-url ...`)
to put everything on one address, routed by path: the web app at `/`, the
API at `/v1`, `/v2` and `/api-docs`, XMPP at `/ws` and `/bosh`, Centrifugo at
`/connection/websocket`, files at `/files/`. Chat attachments then go to the
public files bucket (the membership-gated `secure-files.` host needs a host
of its own).

- `PUBLIC_URL=https://chat.example.com`: one DNS record, a Let's Encrypt
  certificate for it.
- `PUBLIC_URL=http://192.168.1.20:8456` with `HTTP_PORT=8456`: a LAN
  install without TLS (NAS, home server). This is how the Umbrel and CasaOS
  apps run (`platforms/`).

The host of `PUBLIC_URL` is also the XMPP domain (an IP address works), and
the web app connects to XMPP and links stored files through `PUBLIC_URL`
itself; only its API calls follow the address the page was opened by. So
open it by the `PUBLIC_URL` address, and make sure that name resolves for
every client.

This directory is also what the cloud images run (the AWS AMI, the Azure,
DigitalOcean and Vultr images, the Akamai StackScript): their first-boot
setup page calls `deploy/cloud/install.sh`, which is `./configure.sh` plus
`docker compose up -d` plus the check below, so everything on this page
applies to them.

## Check it

```bash
docker compose ps                              # every service running or exited (0)
docker compose --profile verify run --rm verify
```

`verify` goes through the public URLs the way a browser does: certificates,
web app, API docs, admin login, licence state, a chat room created and a
message sent over `wss://xmpp.<root>/ws`, a file uploaded and read back from
`files.<root>`. It prints one line per check.

## What runs

| Service | Image | Role |
|---|---|---|
| `caddy` | `caddy` | TLS and routing for the five hosts (ports 80, 443) |
| `frontend` | `dappros/ethora-frontend` | web chat and admin panel (`app.<root>`) |
| `api`, `jobs` | `dappros/ethora-api` | HTTP API (`api.<root>`, Swagger at `/api-docs/`), cron and queue workers |
| `xmpp` | `dappros/ethora-xmpp` | ejabberd with the Ethora modules (`xmpp.<root>`, WebSocket at `/ws`) |
| `minio` | `dappros/minio` | file storage (`files.<root>`) |
| `mongo`, `mysql`, `redis`, `centrifugo` | stock images | internal only |
| `config`, `mongo-init`, `init` | the images above | one-shot steps, run on every `up`, then exit (0) |
| `ai-service`, `docs-parse`, `widget`, `ai-postgres` | `dappros/ethora-ai`, `pgvector`, `caddy` | the `ai` module (profile `ai`; see Enterprise modules) |

`config` renders every service's configuration from `.env` with the same
templates the host installer uses (and generates the secrets `.env` leaves
out), `mongo-init` makes MongoDB a replica set,
and `init` creates the base app and admin account and provisions their XMPP
accounts. All three are idempotent; running them again changes nothing.

Only Caddy publishes ports. Native XMPP clients on port 5222 are not exposed;
web, mobile and SDK clients use `wss://xmpp.<root>/ws`.

## Update

```bash
docker compose pull && docker compose up -d
```

The image tags in `.env` (`...:2610`) follow a release line, so a pull picks
up that line's fixes. To move to a newer line, change the three
`ETHORA_*_IMAGE` tags in `.env` (or take this directory from the newer
release) and run the same command. When nothing was published, the update
changes nothing.

## Change a setting

Edit `.env` (or re-run `./configure.sh` with the new answer; it keeps every
secret), then:

```bash
docker compose up -d --force-recreate
```

`ADMIN_PASSWORD` only sets the password the admin account starts with;
change it in the admin panel afterwards. `MYSQL_ROOT_PASSWORD` and
`MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` are written into the databases on
the first start and must not change after it.

Any variable of the installer's service templates can be added to `.env`
(`templates/backend.env.template`, `templates/frontend.env.template`), for
example `POSTMARK_ENABLED=true` with `POSTMARK_TOKEN=...` for e-mail.

## Where the data is

Named Docker volumes (under `/var/lib/docker/volumes/` on a default host):

| Volume | Contents |
|---|---|
| `ethora_mongo` | apps, users, chats, message archive |
| `ethora_mysql` | ejabberd: XMPP accounts, rooms, message history |
| `ethora_minio` | uploaded files |
| `ethora_redis` | cache and queues |
| `ethora_caddy-data` | certificates and the ACME account |
| `ethora_secrets` | the secrets `.env` left out, generated on the first start |
| `ethora_ai-postgres` | ai module: the agents' document embeddings |
| `.env` (this directory) | your settings and the secrets it carries |

They survive `docker compose down`, image updates and reboots.
`docker compose down -v` deletes them, and with them every chat and file.
The volumes `ethora_config`, `ethora_mysql-initdb`, `ethora_mongo-config` and
`ethora_caddy-config` are regenerated and need no backup; `ethora_secrets`
does, since the databases were initialised with its passwords.

## Backup and restore

Stop the stack for a consistent copy (a minute of downtime):

```bash
mkdir -p backup && cp .env backup/
docker compose stop
for v in mongo mysql minio redis caddy-data secrets; do
  docker run --rm -v ethora_$v:/v:ro -v "$PWD/backup:/b" alpine tar czf /b/$v.tgz -C /v .
done
docker compose start
```

(Add `ai-postgres` to the list with the ai module.)

Restore on a new host: copy this directory with `backup/`, then, before
anything has started there:

```bash
cp backup/.env .env
docker compose create          # pulls the images, creates the empty volumes
for v in mongo mysql minio redis caddy-data secrets; do
  docker run --rm -v ethora_$v:/v -v "$PWD/backup:/b:ro" alpine tar xzf /b/$v.tgz -C /v
done
docker compose up -d
```

Without downtime, dump the two databases instead and copy the files volume:

```bash
docker compose exec -T mongo mongodump --archive --gzip > backup/mongo.archive.gz
docker compose exec -T mysql sh -c 'mysqldump -uroot -p"$(cat "$MYSQL_ROOT_PASSWORD_FILE")" --single-transaction --databases ejabberd_db' | gzip > backup/mysql.sql.gz
docker run --rm -v ethora_minio:/v:ro -v "$PWD/backup:/b" alpine tar czf /b/minio.tgz -C /v .
```

## Enterprise modules

The Enterprise modules run from this same bundle as compose profiles. Each
module needs a licence key that carries its feature (the admin panel's
License page, or `--license-key`), and its images come from the private
`dappros` repositories on Docker Hub: sign in to the registry with the
token shown on the License page before the first start.

```bash
docker login -u <registry user> docker.io          # the token from the License page
./configure.sh --modules ai --license-key ETHORA1.... --ai-api-key sk-...
docker compose up -d
```

`configure.sh --modules` writes the profiles into `COMPOSE_PROFILES`
(`caddy,ai`); without `configure.sh`, set that variable and the module's
values in `.env` by hand (see `.env.example`, "modules").

| Module | Profile | Runs | Host |
|---|---|---|---|
| AI agents | `ai` | `ai-service`, `docs-parse`, `ai-postgres` (pgvector), `ai-init`, `widget-export`, `widget` from `dappros/ethora-ai` | `widget.<root>` (the website chat widget; `/widget/` on one origin) |

The `ai` module turns the Agents section of the admin panel on, serves the
embeddable website chat widget from `widget.<root>` (a sixth DNS record,
covered by a wildcard) and needs an OpenAI-compatible provider: `AI_API_KEY`,
and `AI_API_URL`, `AI_CHAT_MODEL`, `AI_EMBEDDING_MODEL` for another
provider or model. Embeddings live in the bundled Postgres (volume
`ethora_ai-postgres`; back it up with the others); `AI_PG_URL` points
ai-service at a Postgres of your own with the pgvector extension instead.
The widget's long-lived script URL carries a version suffix
(`assistant<WIDGET_SCRIPT_VERSION>.js`), fixed at the first start and kept,
so pages that embed it keep working across updates. `docker compose
--profile verify run --rm verify` checks the module too: the widget script
on its public URL, ai-service and docs-parse answering, the licence
feature.

Switching a module off: remove its profile from `COMPOSE_PROFILES` and run
`docker compose up -d --remove-orphans`; its volumes stay until
`docker volume rm`.

The push, SDK playground, MCP and uptime modules follow the same pattern
and are added in later releases; until then the host installer runs them.

## On a platform with its own proxy

Coolify, Dokploy and similar platforms run their own reverse proxy on ports
80 and 443. Leave the bundled one off (`./configure.sh --no-caddy`, or an
empty `COMPOSE_PROFILES`) and route the five hosts to these containers, with
WebSocket upgrades allowed:

| Host | Container and port | Paths |
|---|---|---|
| `api.<root>` | `api:8080` | all (block `/metrics`) |
| `app.<root>` | `frontend:8080`; `centrifugo:8000` for `/connection/websocket` | all |
| `xmpp.<root>` | `xmpp:5280` | `/ws` and `/bosh` only; never `/api` or `/admin` |
| `files.<root>` | `minio:9000` | all, with the original `Host` header |
| `secure-files.<root>` | `api:8080` | all, with the original `Host` header (the API serves this host itself) |
| `widget.<root>` (ai module) | `widget:8080` | all |

For Coolify the exact steps (git-based application, and a draft one-click
service template) are in `platforms/coolify/README.md`; for Dokploy
(Compose service from git, and a template in the format of Dokploy's
templates repository) in `platforms/dokploy/README.md`.

## Portainer

Portainer users can add the bundle to their app templates: Settings > App
Templates > URL, paste

    https://raw.githubusercontent.com/dappros/ethora-install/main/deploy/compose/platforms/portainer-template.json

and Ethora Core appears in the templates list with a field for every value
`.env` needs; secret fields left empty are generated on the first start. To
paste a stack instead (Stacks > Add stack > Web editor), paste
[`single/docker-compose.yml`](single/docker-compose.yml) and add
`ROOT_DOMAIN` and `ADMIN_EMAIL` as environment variables. See
[platforms/](platforms/) for the template and other platforms.

## Kubernetes

The Helm chart [`deploy/helm/ethora-core`](../helm/ethora-core/) runs the same
images and renders the same configuration with `ethora-compose-init`:
`helm install ethora oci://docker.io/dappros/ethora-core --set rootDomain=... --set admin.email=...`.

## Cloudron

The Cloudron package [`deploy/cloudron`](../cloudron/) runs the stack as one
Cloudron app: the same payloads, copied out of the release images, under
supervisord, on Cloudron's MongoDB, MySQL and Redis addons, rendered by this
bundle's `render-config.sh` in one-origin mode behind Cloudron's proxy.

## Umbrel and CasaOS

App-store packages for home servers, generated from the single file and run
on one address over the LAN (`PUBLIC_URL`, port 8456):
[platforms/umbrel/](platforms/umbrel/) (umbrelOS, behind its `app_proxy`) and
[platforms/casaos/](platforms/casaos/) (CasaOS and ZimaOS). Each README has
the store's submission steps.

## Common questions

- **Certificate failed.** DNS does not point at this server yet, or port 80
  is blocked. `docker compose logs caddy` names the host; fix it and
  `docker compose restart caddy`.
- **A service keeps restarting.** `docker compose logs <service>`. If `config`
  exited non-zero, `.env` is missing a value; its log lists which.
- **Which admin password?** The one in `.env` (`ADMIN_PASSWORD`), or, when
  it was left empty, the one `docker compose logs config` printed on the
  first start (also in the `secrets` volume). Change it in the admin panel.
- **Can I put it behind Cloudflare?** Start with plain DNS records first;
  proxying can be switched on afterwards for `app.` and `api.`. `xmpp.` must
  stay unproxied.
- **Mobile apps?** The Ethora SDKs for iOS, Android and React connect to
  `api.<root>` and `xmpp.<root>`; see https://ethora.com/docs.

## Licence

Ethora Core, free with per-server limits (5 apps and 500 user accounts; 10
and 5,000 after registering for free on the admin panel's License page).
Installing it accepts the Ethora Core Software License:
https://ethora.com/legal/ethora-core-license/. The MinIO image is an
unmodified copy of MinIO under AGPL-3.0; the other third-party images keep
their own licences.
