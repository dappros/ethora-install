# Container images and bytecode builds

How the API is packaged as a prebuilt image, what the bytecode option does
and does not protect, and how to run the image on a host that was installed
with the deploy scripts. Introduced in the `2610` line.

## What gets built

`ethora-backend/services/api/Dockerfile` produces one image, `ethora-api`,
that runs any of the three backend processes:

| `docker run ... ethora-api <arg>` | Source-mode equivalent (PM2 name) |
|---|---|
| `api` (default) | `backend` |
| `jobs` | `backend-jobs` |
| `bc-worker` | `backend-bc-worker` |

The image pins its own Node (`NODE_VERSION` build arg, 24 today). The host
needs Docker only. Configuration is unchanged: the same backend `.env` that
`deploy/scripts/setup-env.sh` renders from `deploy.yml` is passed in as an
`env_file`, and `deploy.yml` stays outside the image.

Build locally:

```bash
cd ethora-backend/services/api
docker build -t ethora-api:dev .                          # plain JavaScript
docker build --build-arg BYTECODE=1 -t ethora-api:dev .   # V8 bytecode
```

Published by `.github/workflows/release-images.yml` (manual run, or push to
a release branch that moves the `ethora-backend` pointer) as
`docker.io/dappros/ethora-api:<release>` and `:<release>.<n>` (and the same
on `ghcr.io/dappros/`, the canonical store for every image), for
linux/amd64 and linux/arm64. The workflow boots the amd64 image with
`CI_SMOKE_TEST=true` and checks `/v1/ping` before pushing anything, and for
bytecode builds also asserts that no `.js` remains under `dist/src`.

## Bytecode: what it is

With `BYTECODE=1` the build compiles every first-party `.js` under
`dist/src` to V8 bytecode (`.jsc`) with bytenode and deletes the source. The
only plain JavaScript left is `dist/start.js`, which installs the bytenode
require hook and then requires the selected entry point; the same file runs
unchanged in a plain build where the hook is simply absent.

Facts that shape how this is used:

- **Bound to the Node major and the CPU architecture.** A `.jsc` compiled
  on Node 24 amd64 loads only on Node 24 amd64. The image carries its own
  Node so operators never see this; it is why `NODE_VERSION` in the
  Dockerfile and `setup_24.x` in `install.sh` must move together, and why
  the workflow builds each architecture natively. In practice: never
  `docker save` an image built on one architecture and `docker load` it on
  another; a wrong-arch bytecode image fails at startup with
  `exec format error`. Pull the published multi-arch image (Docker selects
  the right architecture) or build on the target's architecture. Plain
  (non-bytecode) images run under emulation; bytecode ones do not.
- **Dependencies are not compiled.** `node_modules` stays as published;
  there is nothing to protect there and some packages rely on
  `Function.prototype.toString`, which bytecode breaks.
- **Stack traces keep function names but lose line numbers** for compiled
  files. Reproduce customer issues with a plain build of the same commit;
  `/ping` reports the commit.
- **Tests never ship.** `*.test.js` files are removed from every image.

## Bytecode: what it protects

Honest scale, from weakest to strongest:

| Artifact | Effort to read the logic | Effort to remove a check |
|---|---|---|
| `dist/` as built today | none | one line |
| Bytecode, modular files | a day with a decompiler and the matching V8 | small: drop a plain `.js` shim next to the `.jsc`, Node resolves `.js` first |
| Bytecode + license logic spread across the feature paths it guards | a day per function of interest | days, and again every release |

Public tools exist that disassemble V8 bytecode and emit readable
pseudo-JavaScript for a matching V8 version. Bytecode is therefore a strong
deterrent, not a lock. The contract and the license server's view of which
instances phone home are what make tampering visible; bytecode raises the
cost from "edit a file" to "reverse-engineer every release".

## Running the API image on a deploy-script host

`deploy/docker-compose.api.yml` runs the three processes against the
infrastructure the enterprise compose file already provides. It declares its
own compose project (`name: ethora-api`); never run it under the shared
`deploy` project and never with `--remove-orphans`, or compose will delete
the enterprise stack's containers as orphans. It uses host
networking, because the rendered `.env` points at `localhost` for Mongo,
Redis, MySQL and MinIO, and nginx already proxies to `127.0.0.1:8080`.

```bash
# stop the PM2 processes the image replaces
pm2 stop backend backend-jobs backend-bc-worker

ETHORA_API_IMAGE=docker.io/dappros/ethora-api:2610 \
ETHORA_BACKEND_ENV_FILE=/home/ubuntu/ethora/ethora-backend/services/api/.env \
docker compose -f /home/ubuntu/ethora/deploy/docker-compose.api.yml up -d

curl -s http://127.0.0.1:8080/v1/ping   # version, build commit, license state
```

Add `--profile blockchain` when `features.blockchain` is on. Updating is a
tag change and `up -d`; rolling back is the previous tag.

## Frontend image

`ethora-app-reactjs/Dockerfile` builds `ethora-frontend`: one universal
bundle plus an nginx runtime. Everything that used to be baked in through
`VITE_*` at build time is read at runtime from `/config.js`
(`src/config/env.ts`), and the Content-Security-Policy `connect-src` origins
are filled in from the same environment, so the image is identical for every
install. Published by the same workflow as `docker.io/dappros/ethora-frontend:<release>`.

The container has three commands:

| Command | Use |
|---|---|
| `serve` (default) | Render config from env, serve the bundle on 8080 with SPA fallback and `no-store` on `config.js` and `index.html` |
| `export /out` | Render config from env into a directory and exit |
| `render [dir]` | Render in place and exit |

On a deploy-script host, nginx already serves `ethora-app-reactjs/dist`
from disk, so the right move is `export`, not a second web server:

```bash
ETHORA_FRONTEND_IMAGE=docker.io/dappros/ethora-frontend:2610 \
deploy/scripts/frontend-from-image.sh
```

The script takes the frontend `.env` that `setup-env.sh` rendered, writes a
docker-clean copy to `deploy/generated/frontend.image.env`, exports the
rendered bundle (as the invoking user, world-readable, ownership matching the
previous bundle) into a staging directory and swaps it into place so nginx
never serves a half-written tree. It uses an image that is already present
locally (`docker load` or a local build) and only pulls when the image is
missing or `ETHORA_FRONTEND_PULL=always` is set. Re-run it after any
`setup-env.sh` change or to move to another tag. For docker-only hosts the
overlay has a `frontend` service behind the `frontend-container` profile that
serves on `127.0.0.1:${FRONTEND_PORT:-3000}` for a reverse proxy.

nginx must not cache `/config.js`: the deploy templates
(`deploy/nginx/web.conf.template`, `hosted-apps.conf.template`) send it with
`Cache-Control: no-store`, overriding the one-year immutable rule that covers
other `*.js`. Without that a browser would pin one install's configuration
for a year.

Bundles built from source keep working unchanged: `public/config.js` ships an
empty object, so the inlined build values apply.

## Verified on QA

Both images were exercised on the QA host (2026-09-20) and QA was then
restored to source mode:

- Bytecode API image ran the API and jobs from `docker-compose.api.yml`
  against the live `.env` with host networking. Login, `/v2/users/me`, apps,
  agents, license, Swagger, `/v1/chats/my` (200 with a token) and `/metrics`
  all served from compiled `.jsc`; XMPP completed the full
  `auth -> success -> bind -> presence -> iq` cycle and the ejabberd custom
  modules' `track-member` callbacks reached the container.
- Frontend image bundle exported via `frontend-from-image.sh` served the app
  with `config.js` and the CSP rendered from the environment.
- `release-images.yml` built, smoke-tested and pushed both images for
  amd64 and arm64.
- AI module, push, SDK playground and MCP images (2026-09-21): all four ran
  from the overlay under the `ethora-api` project with PM2 apps removed, the
  widget bundle was exported with this install's endpoints and served by
  host nginx, an agent replied in a multi-agent room through the
  containerised AI service, and `health-check.sh` reported every service in
  image mode.

## Enabling image mode

Image mode is a first-class install path. Set it in `deploy.yml` (or with
`setup.sh --backend-mode image --frontend-mode image`):

```yaml
services:
  backend:
    mode: image                                  # source | image
    image: docker.io/dappros/ethora-api:2610
  frontend:
    mode: image
    image: docker.io/dappros/ethora-frontend:2610
```

Then run `install.sh` or `update.sh` as usual. What changes per mode:

| | `source` (default) | `image` |
|---|---|---|
| API | `npm ci` + `tsc` on the host, three PM2 apps | `docker compose -f deploy/docker-compose.api.yml up -d` from the image; PM2 apps are deleted so they cannot hold port 8080 |
| Frontend | `vite build` on the host into `ethora-app-reactjs/dist` | `frontend-from-image.sh` exports the runtime-configured bundle into the same `dist`; host nginx is unchanged |
| One-off scripts (`initEthoraApp.js`, `scripts/deploy/*.js` lookups, data migrations) | run with host `node` from the checkout | run inside the image: `scripts/` ships under `dist/scripts` (bytecode-compiled in bytecode builds) and `ethora-api script <path> [args]` runs one with the same require hook; only the rendered `.env` is passed in. No backend source on the host. |
| `health-check.sh` | PM2 status | container status (`ethora-backend`), same `/ping` license line |
| Switching back | | `mode: source` stops the containers before PM2 starts |

Modes are read by `setup-env.sh` and persisted to `.deploy.env` as
`BACKEND_MODE`, `ETHORA_API_IMAGE`, `FRONTEND_MODE`, `ETHORA_FRONTEND_IMAGE`.
`validate.sh` rejects an unknown mode or an image mode with an empty image
ref. Private GHCR images need `docker login ghcr.io` on the host before the
first install; locally loaded or locally built images are used as-is.

## The other services

Every PM2 service now has an image and a mode switch, built by the same
workflow and run from the same compose overlay (each behind a compose
profile that `setup-node-services.sh` enables per mode):

| `deploy.yml` key | Image | Commands / notes |
|---|---|---|
| `services.ai_service.mode` | `ethora-ai` (built from the monoserver root, `deploy/docker/ai.Dockerfile`) | `ai-service`, `docs-parse` (both bytecode-compiled), `widget-export /out`. One switch covers the whole AI module: agent runtime, document parsing and the AI chat widget bundle. |
| `services.push.mode` | `ethora-push` (`deploy/docker/push.Dockerfile`, bytecode) | `server`, `worker`. Uploads are mounted at the host path the service's `.env` names. |
| `services.playground.mode` | `ethora-playground` (`deploy/docker/playground.Dockerfile`) | Next.js inlines `NEXT_PUBLIC_*` at build time, so the container builds on first start for this install's env (kept in a volume) and rebuilds only when those values change. That first build needs about 1.5 GB of RAM; the installer starts it after every other service and waits for it, so do not start it by hand while a source-mode backend or frontend build is running on a 4 GB host. |
| `services.mcp.mode` | `ethora-mcp` (the public repo's own Dockerfile) | Reads its config from the env; HTTP transport when `ETHORA_MCP_TRANSPORT=http`. |
| `services.ejabberd.mode` | `ethora-xmpp` (`ejabberd-docker/docker/Dockerfile`: ejabberd plus the Ethora modules compiled in) | `scripts/xmpp-from-image.sh` pulls it, extracts the config templates, entrypoint, module sources and beams from the image's `/ethora-dist` into the directory the compose file mounts, and tags it `deploy-xmpp`, so `docker-compose.enterprise.yml` runs it unchanged. Config rendering, `jwt.key`, certificates and the stale-beam purge on module changes work as in source mode. |

The AI chat widget is a static bundle that bakes its API and XMPP endpoints
in at build time and is embedded on third-party pages, so it cannot load a
`config.js`. The image is built with placeholders in place of the
`VITE_WIDGET_*` values; `widget-export` substitutes the rendered
`ethora-ai-chat-widget/.env.production.local` into the bundle and writes the
`assistant.js` / `assistant<version>.js` copies. `deploy/scripts/widget-from-image.sh`
drops the result into the directory host nginx serves, the same way the
frontend export works. In AI image mode the schema initialisation for the AI
Postgres also runs inside the image (it needs the service's `pg` module and
migrations), so no host Node.js is involved for any of these services.

`setup.sh --all-modes image` switches every service at once
(`--ai-mode`, `--push-mode`, `--playground-mode`, `--mcp-mode`, `--ejabberd-mode`
individually). The smallest image-mode install is the API, the frontend and
ejabberd; everything else is optional per `deploy.yml`.

## Compose bundle

`deploy/compose/` (2610) runs the three Core images plus the databases as a
single compose project with Caddy: the delivery form for compose-based
platforms and the base for future Helm charts and slimmer cloud images. It
renders the service configuration from the same templates as the installer
(a test asserts the templates are identical) and runs the first-boot steps
through the API image's script mode. See its README.

## Editions, registries and versions

`setup.sh --edition core` writes a `deploy.yml` with only the API, the
frontend and ejabberd enabled (AI, push, playground, MCP, uptime,
monitoring, widget and hosted apps off) and points the three image refs at
Docker Hub (`docker.io/dappros/ethora-{api,frontend,xmpp}`). `--edition
full` (the default) keeps everything and the GHCR refs. The same workflow
builds both: the three Core images are pushed to Docker Hub as well as
GHCR when the `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secrets exist; the
other four stay on GHCR (private packages, enterprise installs pull them
with a token).

Every run gets a build number `<line>.<n>` (`2610.4`): the release branch
plus the next free number among this repository's git tags. Each image is
tagged with the moving line tag (`2610`) and the build (`2610.4`), and a git
tag `2610.4` is created on the monoserver commit once all seven images
succeeded, so one number names the whole set. `promote_latest` on a manual
run also moves Docker Hub `latest`; use it only for the production line.
`/v1/ping` reports the build number as the version.

The ejabberd image ships the Dappros modules as compiled beams only: debug
information is stripped at build time (`beam_lib:strip_files`), the Erlang
sources are deleted from the image, and `/ethora-dist` carries beams and
config templates but no `custom_modules` sources. The smoke test asserts
all three. Source-mode installs still compile from the checkout.

Every job in `release-images.yml` scans the image it just smoke-tested with
Trivy before pushing: fixable HIGH and CRITICAL findings are printed, a
fixable CRITICAL fails the job. Unfixed findings in the base image are
reported, not blocking.
Host Node.js is still installed by `install.sh` for source mode and for the
localhost dev server.
