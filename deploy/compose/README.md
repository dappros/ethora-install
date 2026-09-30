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

Before you start, create four DNS records pointing at the server, all plain
`A` (or `AAAA`) records, no proxy:

| Record | Points to |
|---|---|
| `api.chat.example.com` | your server's IP |
| `app.chat.example.com` | your server's IP |
| `xmpp.chat.example.com` | your server's IP |
| `files.chat.example.com` | your server's IP |

(`chat.example.com` is your root; every host derives from it. A wildcard
`*.chat.example.com` record covers all four.)

**No domain yet?** Use a magic DNS name for a test install: with server IP
`203.0.113.10`, pass `--domain 203-0-113-10.sslip.io`. It resolves
everywhere, gets a real Let's Encrypt certificate, and needs no DNS setup.

No `configure.sh` (a platform that only takes a compose file and variables):
copy `.env.example` to `.env`, or enter its values in the platform, and give
every empty secret its own random value of 32+ letters and digits.

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
| `caddy` | `caddy` | TLS and routing for the four hosts (ports 80, 443) |
| `frontend` | `dappros/ethora-frontend` | web chat and admin panel (`app.<root>`) |
| `api`, `jobs` | `dappros/ethora-api` | HTTP API (`api.<root>`, Swagger at `/api-docs/`), cron and queue workers |
| `xmpp` | `dappros/ethora-xmpp` | ejabberd with the Ethora modules (`xmpp.<root>`, WebSocket at `/ws`) |
| `minio` | `dappros/minio` | file storage (`files.<root>`) |
| `mongo`, `mysql`, `redis`, `centrifugo` | stock images | internal only |
| `config`, `mongo-init`, `init` | the images above | one-shot steps, run on every `up`, then exit (0) |

`config` renders every service's configuration from `.env` with the same
templates the host installer uses, `mongo-init` makes MongoDB a replica set,
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
| `.env` (this directory) | every secret of the install |

They survive `docker compose down`, image updates and reboots.
`docker compose down -v` deletes them, and with them every chat and file.
The volumes `ethora_config`, `ethora_mysql-initdb`, `ethora_mongo-config` and
`ethora_caddy-config` are regenerated and need no backup.

## Backup and restore

Stop the stack for a consistent copy (a minute of downtime):

```bash
mkdir -p backup && cp .env backup/
docker compose stop
for v in mongo mysql minio redis caddy-data; do
  docker run --rm -v ethora_$v:/v:ro -v "$PWD/backup:/b" alpine tar czf /b/$v.tgz -C /v .
done
docker compose start
```

Restore on a new host: copy this directory with `backup/`, then, before
anything has started there:

```bash
cp backup/.env .env
docker compose create          # pulls the images, creates the empty volumes
for v in mongo mysql minio redis caddy-data; do
  docker run --rm -v ethora_$v:/v -v "$PWD/backup:/b:ro" alpine tar xzf /b/$v.tgz -C /v
done
docker compose up -d
```

Without downtime, dump the two databases instead and copy the files volume:

```bash
docker compose exec -T mongo mongodump --archive --gzip > backup/mongo.archive.gz
docker compose exec -T mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --databases ejabberd_db' | gzip > backup/mysql.sql.gz
docker run --rm -v ethora_minio:/v:ro -v "$PWD/backup:/b" alpine tar czf /b/minio.tgz -C /v .
```

## On a platform with its own proxy

Coolify, Dokploy and similar platforms run their own reverse proxy on ports
80 and 443. Leave the bundled one off (`./configure.sh --no-caddy`, or an
empty `COMPOSE_PROFILES`) and route the four hosts to these containers, with
WebSocket upgrades allowed:

| Host | Container and port | Paths |
|---|---|---|
| `api.<root>` | `api:8080` | all (block `/metrics`) |
| `app.<root>` | `frontend:8080`; `centrifugo:8000` for `/connection/websocket` | all |
| `xmpp.<root>` | `xmpp:5280` | `/ws` and `/bosh` only; never `/api` or `/admin` |
| `files.<root>` | `minio:9000` | all, with the original `Host` header |

## Common questions

- **Certificate failed.** DNS does not point at this server yet, or port 80
  is blocked. `docker compose logs caddy` names the host; fix it and
  `docker compose restart caddy`.
- **A service keeps restarting.** `docker compose logs <service>`. If `config`
  exited non-zero, `.env` is missing a value; its log lists which.
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
