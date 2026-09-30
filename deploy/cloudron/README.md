# Ethora Core for Cloudron

The Cloudron package of Ethora Core: one app container that runs the whole
stack of the compose bundle (`deploy/compose`) under supervisord, on
Cloudron's own databases.

| Process    | From                                | Listens on             |
|------------|-------------------------------------|------------------------|
| caddy      | `caddy` (static binary)             | `:3000` (the app port), `127.0.0.1:8081` (web app files) |
| api, jobs  | `ethora-api` (Node and `/app`)      | `127.0.0.1:8080` (api) |
| init       | `ethora-api`, first-boot steps, then exits | -               |
| xmpp       | `ethora-xmpp` via `ethora-compose-init` (ejabberd, musl runtime in `/opt/musl`) | `5280` and ejabberd's other ports, inside the container |
| centrifugo | `centrifugo` (static binary)        | `8000`                 |
| minio      | `dappros/minio` (static binary)     | `127.0.0.1:9000`       |

Nothing is compiled here: the Dockerfile copies each payload out of the
release images with `COPY --from=`, onto `cloudron/base`. The images are
pinned as tag@digest to the release build in
`deploy/compose/platforms/images.env` (`pin.sh`).

## Routing

One origin, the app's Cloudron domain. Cloudron's reverse proxy terminates
TLS and sends everything to caddy on port 3000, which routes by path the
same way as the compose bundle's one-origin mode (`PUBLIC_URL`):

| Path                               | Goes to                   |
|------------------------------------|---------------------------|
| `/v1`, `/v2`, `/api-docs`          | API                       |
| `/ws`, `/bosh`                     | ejabberd (XMPP over WebSocket / BOSH) |
| `/connection/websocket`            | Centrifugo                |
| `/files/...`                       | MinIO (the `files` bucket) |
| anything else                      | web app and admin panel   |

The API stays under its own version prefixes, `/v1` and `/v2`, rather than
under a new `/api` prefix: those are the paths the web app, the SDKs and the
host installer's nginx already use, so no client needs a different base
URL. The XMPP domain is the app's domain (the web client names its XMPP
domain after the host of its WebSocket URL). Native XMPP clients on TCP 5222
are not exposed; clients connect over `wss://<app domain>/ws`.

## Storage

| Where              | What                                                   |
|--------------------|--------------------------------------------------------|
| MongoDB addon      | app data and the chat archive (one database)           |
| MySQL addon        | ejabberd (schema loaded on first start)                |
| Redis addon        | cache and queues (no password: the API has none)       |
| `/app/data/minio`  | uploaded files                                         |
| `/app/data/ejabberd` | ejabberd's Mnesia database and HTTP uploads          |
| `/app/data/secrets` | generated secrets, the initial admin password included |
| `/app/data/env.sh` | optional settings, see below                           |

Cloudron's backups cover all of it: the addons are dumped, `/app/data` is
copied. Everything else is rendered again on every start (`start.sh` runs
the compose bundle's renderer into `/run/ethora/config`).

## Settings

On first start the app creates the base app and its administrator,
`admin@<app domain>`, with a generated password (see `POSTINSTALL.md`). Any
variable of `deploy/compose/.env.example` can be set in `/app/data/env.sh`
(a shell file, sourced on every start; open the app's Web Terminal to edit
it), then restart the app, for example:

```sh
# /app/data/env.sh
BASE_APP_DISPLAY_NAME="Acme Chat"
POSTMARK_ENABLED=true
POSTMARK_SERVER_TOKEN=...
```

`ADMIN_EMAIL` and the `BASE_APP_*` values only matter before the first
start; afterwards change them in the admin panel. The public URL, the
databases and the internal endpoints come from Cloudron and cannot be set
there.

## Build and install

With the Cloudron CLI (`npm install -g cloudron`, version 9 or later) logged
in to your Cloudron (`cloudron login my.example.com`), from this directory:

```sh
cloudron install --location chat
```

The CLI uploads this directory and the Cloudron builds the image itself.
Later versions of the package install over the running app with
`cloudron update` from the same directory. To build elsewhere and install an
image instead:

```sh
docker build -t registry.example.com/ethora-cloudron:26.9.0 .
docker push registry.example.com/ethora-cloudron:26.9.0
cloudron install --location chat --image registry.example.com/ethora-cloudron:26.9.0
```

(or `cloudron builder build --repository <repository>` against a Cloudron
Build Service). The Dockerfile's image ARGs can be overridden with
`--build-arg` on both `cloudron install` and `docker build`, e.g. to try a
`ethora-compose-init` built from a branch:

```sh
cloudron install --location chat --build-arg INIT_IMAGE=registry.example.com/ethora-compose-init:test
```

The image is amd64 only (the Cloudron base image is).

## After a release build

```sh
deploy/compose/platforms/pin-images.sh 2610.9   # the store packages' pins
deploy/cloudron/pin.sh                          # Dockerfile ARGs, upstreamVersion
```

Then add an entry to `CHANGELOG.md` and bump `version` in
`CloudronManifest.json` (CalVer `YY.M.patch`, the month the package ships).
`deploy/scripts/tests/compose-bundle.test.sh` fails while the Dockerfile is
not pinned to `images.env`.

## Publishing

Cloudron lists apps in its App Store after review by the Cloudron team, or
as a community package that users install from a versions file you host.

App Store:

1. Push the image to a public registry (Docker Hub), e.g.
   `docker.io/dappros/ethora-cloudron:26.9.0`.
2. `cloudron appstore login` with the publisher account, then
   `cloudron appstore verify-manifest`.
3. `cloudron appstore upload --image docker.io/dappros/ethora-cloudron:26.9.0`
   uploads the version for testing; install it on a test Cloudron with
   `cloudron install --appstore-id com.ethora.core@26.9.0` and run the checks
   below.
4. `cloudron appstore submit` sends it for review, and
   `cloudron appstore notify` posts the submission in the Cloudron forum's
   App Packaging category, where the review happens. New apps usually start
   there as a packaging thread with a link to the package repository.

Community package: `cloudron versions init` creates `CloudronVersions.json`,
`cloudron versions add --image <image>` adds a build (image and manifest) to it;
host the file anywhere, and users install with
`cloudron install --versions-url https://.../CloudronVersions.json`.

## Checks

On a fresh install: sign in as the admin; create a room and send a message
(it must come back over `/ws`); upload a file and open its link (served from
`/files/`); restart the app and sign in again; take a backup in the app's
Backups view, change something, restore the backup and see the change
undone. `deploy/compose/scripts/verify.js` runs the first three from inside
the app (Web Terminal):

```sh
ETHORA_BACKEND_ENV_FILE=/run/ethora/config/api/backend.env HOME=/tmp \
  gosu cloudron bash /ethora/scripts/api-entrypoint.sh verify
```
