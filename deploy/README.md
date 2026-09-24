# Ethora Deployment Guide

`deploy/` turns a checkout of this repository into a running Ethora install
with one command, and updates it with one more. This page is for the person
who runs those commands: the operator of a customer instance, a developer
with a staging box, or someone installing locally.

The first three sections are what you need day to day. Everything after
them is reference and runbooks.

## Table of Contents

Day to day:

- [How an install is laid out](#how-an-install-is-laid-out)
- [Install](#install)
  - [First login: secure the superadmin account](#first-login-secure-the-superadmin-account)
- [Update and rollback](#update-and-rollback)
- [Licensing](#licensing)
- [Image mode (prebuilt containers)](#image-mode-prebuilt-containers)
- [Runbooks and further reading](#runbooks-and-further-reading)

Reference:

- [Update behaviour in detail](#update-behaviour-in-detail) and [Data migrations](#data-migrations)
- [Quick QA checks](#quick-qa-checks)
- [Hosted MCP server (optional)](#hosted-mcp-server-optional)
- [Feedback channel](#feedback-channel)
- [Uptime monitoring (ethora-uptime)](#uptime-monitoring-ethora-uptime)
- [Backend jobs / cron runner (PM2)](#backend-jobs--cron-runner-pm2)
- [Repo integration model (how bumps work)](#repo-integration-model-how-bumps-work)
- [Local Testing](#local-testing)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Deployment](#deployment)
- [Security Considerations](#security-considerations)
- [Post-Deployment](#post-deployment)

## How an install is laid out

Every install uses three directories. Each has exactly one job, and the
deploy refuses to run when they overlap.

| Directory | Default | What it holds | Who writes it |
|---|---|---|---|
| **source** (`paths.source`) | `~/ethora-install-shared` | the git checkout you run the scripts from, plus the only `deploy.yml` | git, on every update |
| **target** (`paths.base`) | `~/ethora` | the live install: built code, rendered `.env` files, what PM2 and nginx serve | `install.sh` / `update.sh` |
| **data** (`DATA_DIR`) | `~/ethora-data` | MongoDB, MinIO, MySQL and Redis volumes | the databases only; never a deploy |

`~` is the home of the user who runs `sudo` (normally `ubuntu`). The source
and target directories are set in `deploy/config/deploy.yml`:

```yaml
paths:
  source: /home/ubuntu/ethora-install-shared   # where this checkout lives
  base:   /home/ubuntu/ethora                  # live install (must differ from source)
```

The data directory is not in `deploy.yml`. It defaults to `~/ethora-data`
and can be moved once, at first install, with `DATA_DIR=/mnt/data
sudo ... install.sh`; the choice is persisted in `deploy/.deploy.env`
(inside the source directory) and reused by every later update.

Two rules follow from this layout:

- **Edit `deploy.yml` only in the source directory** and run every script
  from there. The target directory keeps no `deploy/` folder.
- **Nothing you care about lives in the source or target tree.** Both are
  overwritten by deploys. Data, uploads and rendered secrets are outside
  them or regenerated from `deploy.yml`.

Older installs that put everything in one directory, or kept data inside a
tree, are stopped by `scripts/preflight-paths.sh` at the start of the next
deploy. [`docs/MIGRATE_TO_CLEAN_PATHS.md`](../docs/MIGRATE_TO_CLEAN_PATHS.md)
walks through the ten-minute migration.

### Which repository to clone

- **Developers** clone `dappros/ethora-monoserver` and run
  `git submodule update --init --recursive`. Components are git submodules.
- **Customer instances** clone `dappros/ethora-install-shared`: the same
  content with the submodules flattened into plain directories, one branch
  per release line, refreshed automatically from this repo. It needs no
  submodule step and is what the examples below assume. Access is by a
  per-instance read-only deploy key.

Release lines are branches named by year and month (`2609`, `2610`, ...).
The highest is the current development line; the one below it is what
production runs. Pick the branch you were told to deploy.

## Install

Fresh Ubuntu 22.04 or 24.04 host, DNS records pointing at it, a user with
`sudo`. The installer installs Docker, Node.js 24, nginx, certbot and `yq`
itself.

```bash
# 1. Source checkout (release line 2609 shown; use the branch you were given)
git clone -b 2609 git@github.com:dappros/ethora-install-shared.git ~/ethora-install-shared
cd ~/ethora-install-shared

# 2. Write deploy/config/deploy.yml: root domain, admin email, license key.
#    Every host (api., app., xmpp., files., ...) derives from the root domain,
#    every secret is generated, and the file stays fully commented for later edits.
deploy/scripts/setup.sh --domain chat.example.com --admin-email ops@example.com \
    --license-key 'ETHORA1....' --yes
#    (run it with no flags for prompts, or copy deploy/config/deploy.yml.template by hand)

# 3. Install. Builds every service from source, starts Docker services and PM2
#    processes, obtains certificates, seeds the base app and admin user.
sudo deploy/scripts/install.sh

# 4. Check
deploy/scripts/health-check.sh
```

Expect 20 to 40 minutes on a 2 vCPU host, most of it Node builds. The
install log ends with the service URLs and the admin email; the admin
password is the one `setup.sh` printed (or `admin.password` in `deploy.yml`).

### First login: secure the superadmin account

The installer seeds one platform superadmin (`admin.email` in `deploy.yml`)
with a generated password when `admin.password` is left blank, and stores
that password in `deploy/.deploy.env` on the host. Treat it as a first-boot
seed only: the platform creates the account once, so editing `deploy.yml`
later does not change it. Recommended practice on a production host, in
this order, before anyone else gets the URL:

1. **Use a real owner address** for `admin.email` (a named administrator or
   an operations mailbox the customer controls), never the template default.
   Leave `admin.password` blank so the installer generates one, and hand it
   over out of band (password manager or one-time secret link), not by email
   or chat.
2. **Change the password** at first login: Account > Security > Change
   password. Every other session is signed out; the stored seed value is now
   stale, so either update `.deploy.env` or treat host access as the only
   recovery path.
3. **Enrol in two-step verification** on the same tab (authenticator app,
   backup codes shown once). Store the backup codes with the credentials.
4. **Enforce it for administrators**: on the base app, App settings > Sign-on
   options > "Require two-step verification for administrators and owners".
   Administrators without MFA are sent to Account > Security after signing
   in; end users and API clients are not affected.
5. **Recovery**: an owner can clear a locked-out user's MFA from the Users
   page (select the user > Reset MFA). For the superadmin itself, recovery
   goes through the host with `scripts/admin-reset.sh` (next section).
   Restrict SSH/SSM access accordingly.

Outbound email (`integrations.postmark`) is optional. Without it the login
page's "forgot password" answers that the install cannot send email, and the
Users page "Reset password" shows the temporary passwords to the admin who
clicked it (once, with a copy button) instead of emailing them; the user
signs in with the temporary password and is asked to choose a new one.

### Recover or manage the superadmin from the host

`scripts/admin-reset.sh` works without email and without a working login.
Run it from the deploy directory of the live install; it reads `deploy.yml`
and `.deploy.env` for the backend location, mode and base app slug, and runs
inside the API image in image mode.

```bash
sudo ./scripts/admin-reset.sh list                                   # every superadmin on the base app
sudo ./scripts/admin-reset.sh show          --email admin@example.com
sudo ./scripts/admin-reset.sh set-password  --email admin@example.com  # generates one, prints it once
sudo ./scripts/admin-reset.sh temp-password --email admin@example.com  # one-time password, new one chosen at login
sudo ./scripts/admin-reset.sh clear-mfa     --email admin@example.com  # lost authenticator and backup codes
sudo ./scripts/admin-reset.sh set-email     --email admin@example.com --new-email ops@example.com
sudo ./scripts/admin-reset.sh create        --email ops@example.com     # a second superadmin
```

`set-password` and `temp-password` end the account's open sessions. To
choose the password yourself, pass `--password <p>` or set
`ADMIN_RESET_PASSWORD=<p>` in the environment (keeps it out of shell
history). `--json` gives a machine-readable result. Hand generated passwords
over out of band; the script does not store them.

Note on `deploy.yml`: `admin.email` / `admin.password` are read only when the
owner account is first created. Changing `admin.password` later has no
effect; changing `admin.email` makes the next `update.sh` create an
additional superadmin with that address (the old one stays). Use
`admin-reset.sh` for deliberate changes.

Useful `install.sh` flags:

| Flag | Effect |
|---|---|
| `--yes` | never prompt (scripted installs) |
| `--reset` | wipe MongoDB and MySQL data, then install (all apps, users and chats gone) |
| `--reinstall --yes` | delete the target directory and install from scratch; data directory untouched |
| `--cleanup-only` | stop and remove the stack without installing |
| `--base-dir DIR` | override `paths.base` for this run |

Environment variables the installer honours: `DATA_DIR` (see above),
`INSTALL_NODE_MAJOR` (default 24), `GIT_SSH_COMMAND` (see the note under
[Update](#update-and-rollback)).

For a laptop install with no domain or TLS: `deploy/scripts/setup.sh --local --yes`
then `sudo deploy/scripts/install.sh`. Details in [TESTING.md](./TESTING.md).

## Update and rollback

Updates are git based. `update.sh` fetches the requested branch into the
source directory, syncs it into the target, re-renders every `.env` from
`deploy.yml`, rebuilds only the services whose source changed, restarts
Docker and PM2 services, runs pending data migrations, then the QA and
health checks.

```bash
cd ~/ethora-install-shared
sudo GIT_SSH_COMMAND="ssh -i /home/ubuntu/.ssh/id_ed25519 -o IdentitiesOnly=yes" \
    deploy/scripts/update.sh --ref 2609
```

- `--ref` is the branch, tag or commit to deploy. Staying on the same
  release line picks up its latest fixes; naming the next line
  (`--ref 2610`) upgrades.
- `GIT_SSH_COMMAND` is needed because the fetch runs as root, and root has
  no key for the repository. Point it at the deploy key of the user who
  cloned. Put it on the `sudo` line as shown; `sudo -E` alone does not
  carry it through on default sudo configurations.
- Paths are not passed on the command line. The script reads
  `paths.source` and `paths.base` from `deploy.yml` and the persisted
  `deploy/.deploy.env`. Setting `ROOT_DIR` or similar variables in the
  environment has no lasting effect and is not needed.
- The script re-executes itself when the target branch ships a newer
  `update.sh`, so you never have to update the script before running it.
- A typical update takes 10 to 20 minutes. Services restart near the end;
  chat sessions reconnect on their own.

Roll back to the previous known-good commit:

```bash
sudo GIT_SSH_COMMAND="..." deploy/scripts/update.sh --rollback <sha>
```

Every update log prints the commit the host ran before fetching
(`Source SHA before fetch`); developer checkouts also keep it in
`deploy/.deploy-state/last-sha`. A rollback rebuilds and restarts exactly
like an update. Data migrations are not reversed; every registered migration
is written so that the previous release keeps working on migrated data.

Other `update.sh` flags: `--no-qa` skips the QA probes, `--skip-migrations`
holds data migrations back for a host that must schedule them,
`--no-reexec` keeps the currently checked-out script (for testing a local
edit). `update.sh --help` lists them.

After an update:

```bash
deploy/scripts/health-check.sh     # every service, the license state, external URLs
pm2 list                           # backend, backend-jobs, backend-bc-worker, push, push-worker, ai-service, docs-parse, sdk-playground, mcp
docker ps                          # mongo, redis, xmpp, mysql, minio, centrifugo, ai-postgres, uptime
```

Changing configuration between releases is the same command: edit
`deploy/config/deploy.yml` in the source directory and run `update.sh` with
the ref you are already on. It re-renders and restarts what the change
touches.

## Licensing

The backend enforces a signed license key. Set it in `deploy.yml`:

```yaml
license:
  key: ""              # ETHORA1.<payload>.<signature>, as issued
  key_file: ""         # or a path to a file holding the key (wins over key)
  call_home: true      # daily heartbeat to the license server; false for air-gapped
  server_url: ""       # license server base URL; empty = no call-home
  grace_days: ""       # override the 14-day default
```

`setup.sh --license-key KEY` (or `--license-key-file PATH`, `--license-server URL`,
`--no-call-home`) writes this block for you.

Without a key the install runs every feature for a 14-day grace window,
then restricts creating apps and users and locks the admin panel until a
key is installed. Chat keeps working in every state. The key binds a
parent domain: every host under `domains:` must be that domain or a
subdomain of it, so `dev`, `qa` and `prod` under one second-level domain
share one key. `localhost` and `*.test.ethora.com` always pass.

`setup-env.sh` renders the block into the backend env (`ETHORA_LICENSE_*`
plus `ETHORA_LICENSED_HOSTS`, derived from `domains:`), `validate.sh`
rejects a malformed key or a missing key file, and `health-check.sh`
prints the license state at the end of every install and update. Operators
can also paste a key on the admin panel License page (`/app/admin/license`);
a key in `deploy.yml` wins over it. To renew, replace the key and run
`update.sh` on the current ref, or paste the new key in the admin panel.

Full reference, states and key issuance: [`docs/LICENSING.md`](../docs/LICENSING.md).
Keys are issued from the private `dappros/ethora-license-server`.

## Image mode (prebuilt containers)

Every service that source mode builds on the host also exists as a prebuilt
image, and each can be switched independently in `deploy.yml`:

| `deploy.yml` key | Image | Replaces |
|---|---|---|
| `services.backend.mode` | `ghcr.io/dappros/ethora-api` (optionally V8 bytecode) | PM2 `backend`, `backend-jobs`, `backend-bc-worker` |
| `services.frontend.mode` | `ghcr.io/dappros/ethora-frontend` (one bundle, configured at runtime) | the host `vite build` |
| `services.ai_service.mode` | `ghcr.io/dappros/ethora-ai` (ai-service, docs-parse and the AI chat widget) | PM2 `ai-service`, `docs-parse`, the widget build |
| `services.push.mode` | `ghcr.io/dappros/ethora-push` | PM2 `push`, `push-worker` |
| `services.playground.mode` | `ghcr.io/dappros/ethora-playground` | PM2 `sdk-playground` |
| `services.mcp.mode` | `ghcr.io/dappros/ethora-mcp` | PM2 `mcp` |
| `services.ejabberd.mode` | `ghcr.io/dappros/ethora-xmpp` (ejabberd with the Ethora modules) | the host build of `ejabberd-docker` |

```yaml
services:
  backend:
    mode: image          # source | image
    image: ghcr.io/dappros/ethora-api:2610
```

`setup.sh --all-modes image` (or `--backend-mode image` and friends) writes
the switches; `install.sh` and `update.sh` then run the containers from
`deploy/docker-compose.api.yml` instead of building, export the frontend
and widget bundles into the directories nginx already serves, and run the
one-off init scripts from inside the API image. A minimal image-mode
install is API, frontend and ejabberd; the rest is optional. Nothing else changes:
same `deploy.yml`, same nginx, same data directories, and switching back to
`source` is another update.

**Status: verified on our QA, not yet used on a customer instance.** Source
mode remains the recommended and supported path for customer installs
until it has soaked. Private GHCR images need `docker login ghcr.io` on the
host first, and bytecode images are bound to the CPU architecture they were
built for, so always pull the multi-arch tag rather than copying images
between hosts. Full reference: [`docs/CONTAINER_IMAGES.md`](../docs/CONTAINER_IMAGES.md).

For AWS: `deploy/aws/` holds the Packer template that bakes a Marketplace
AMI (images pre-pulled, first-boot setup page from `deploy/setup-web/`
enabled) and a CloudFormation template that launches one instance. See
`deploy/aws/README.md`.

## Update behaviour in detail

Things `update.sh` does that are worth knowing when something looks slow
or unexpected:

- **Self re-exec.** After checking out the requested ref it compares the
  running script with the checked-out copy and, if they differ, hands over
  to the new one with the same arguments. `--no-reexec` disables this.
- **Incremental builds.** Backend, frontend, AI service and SDK playground
  are rebuilt only when their source tree changed; the uptime Docker image
  only when `ethora-uptime` changed.
- **Swap.** Small hosts get a swap file enabled for the duration of the
  build, the same safeguard as `install.sh`.
- **Rsync without checksums** by default, which keeps large tree syncs
  fast. `ETHORA_UPDATE_RSYNC_CHECKSUM=true` restores the old behaviour.
- **Orphan pruning.** When a branch removes files, or a host switches
  branches, the sync can leave stale source behind that breaks
  `tsc --build`. The script previews the orphaned paths (count and size)
  and gates deletion: `ETHORA_UPDATE_PRUNE=true` prunes without asking
  (CI, cutovers), `ETHORA_UPDATE_PRUNE=false` never prunes, an interactive
  terminal gets a `y/N` prompt (default `N`), and a non-interactive run
  with the variable unset does not prune and prints how to enable it.
  Never deleted regardless: `deploy.yml`, data directories and docker
  volumes, `.env` files, `uploads/`, `node_modules` and build output.
- **Developer checkouts.** When the source directory is a
  `ethora-monoserver` clone with submodules, the same command works; the
  script runs `git submodule update --init --recursive` after the checkout.

### Data migrations

`install.sh` and `update.sh` both call `scripts/run-migrations.sh`, which runs
the one-shot data migrations an install needs. An existing install therefore
picks up a new migration on its next update with no operator step.

```bash
sudo ./scripts/run-migrations.sh --list      # what is registered, and what has run
sudo ./scripts/run-migrations.sh --dry-run   # report, write nothing
sudo ./scripts/run-migrations.sh             # run what is pending
sudo ./scripts/run-migrations.sh --force     # re-run everything, stamps ignored
sudo ./scripts/run-migrations.sh --only <name>
```

Where it sits in the update: **after** the service restart. Every migration in
the registry has to leave the database in a state the new code already handles,
so the app is correct while one is still in flight - and putting them first
would block the deploy behind a long backfill instead.

A failure does not abort the update (QA and health checks still run, so the
operator sees the whole picture), but the run exits non-zero and does not report
success. No stamp is written for a migration that failed, so the next update
retries it. `--skip-migrations` on `update.sh`, or `SKIP_MIGRATIONS=true` in
`.deploy.env`, holds them back on a host that needs to schedule the work.

Stamps live in `deploy/.deploy-state/migrations/`. They are an optimisation and
an audit trail, not a correctness mechanism: every registered migration is
idempotent and safe to re-run against any database.

Adding one: put the script in `ethora-backend/services/api/scripts/` (**not**
`src/utils/` - those need ts-node, which a deployed host does not run) and append
a line to the `MIGRATIONS` array at the top of `run-migrations.sh`. The contract
each entry must satisfy is documented in that script's header.

**Re-running a shipped migration that turned out to be wrong:** bump a revision
suffix on its registry name (`foo` → `foo-v2`). The old stamp stops matching, so
every install runs it again exactly once on its next update - no operator has to
remember `--force`, and hosts that never saw the broken version are unaffected
because the migration is idempotent either way. Do not rename an entry for any
other reason.

Currently registered:

| name | script | what it does |
|---|---|---|
| `source-agent-id-v2` | `scripts/migrateSourceAgentId.js` | Attributes `site_sources` / `documentsources` rows that predate per-Agent ownership to each App's agent, then recomputes `Agent.totalSiteSourceSize` from the rows. Also self-heals a counter that drifted from a half-failed ingest or delete. See the [backend README](../ethora-backend/README.md#per-agent-source-ownership-web-index--knowledge). |

`-v2` because the first version resolved an App's agent only through
`App.defaultBotInstanceId → BotInstance.agentId`. Installs whose agents were all
created through the Agents UI have no BotInstances, so it attributed nothing,
reported `0` and stamped itself done - leaving the whole historical Web Index
unreachable from the UI. Any host that ran `source-agent-id` picks the fix up
automatically.

## Runbooks and further reading

Send customers [`docs/OPERATOR_QUICKSTART.md`](../docs/OPERATOR_QUICKSTART.md):
install, update, rollback, check, license and backup on one page, nothing
internal. Before upgrading between release lines read
[`docs/RELEASE_NOTES_OPERATORS.md`](../docs/RELEASE_NOTES_OPERATORS.md): new
`deploy.yml` keys, new services, migrations, decisions per line.

Runbooks (`docs/runbooks/`):

| When | Read |
|---|---|
| Setting up or checking backups, restoring a host | [BACKUP_AND_RESTORE.md](../docs/runbooks/BACKUP_AND_RESTORE.md) |
| Something is down or misbehaving | [TROUBLESHOOTING.md](../docs/runbooks/TROUBLESHOOTING.md), after `scripts/health-check.sh` |
| Restoring a production snapshot into QA or staging under other domains | [STATEFUL_SNAPSHOT_MIGRATION.md](../docs/runbooks/STATEFUL_SNAPSHOT_MIGRATION.md) |
| Copying files between MinIO instances | [MINIO_OBJECT_MIGRATION.md](../docs/runbooks/MINIO_OBJECT_MIGRATION.md) |
| Moving an old install onto the source / target / data layout | [MIGRATE_TO_CLEAN_PATHS.md](../docs/MIGRATE_TO_CLEAN_PATHS.md) |
| Keeping old hostnames answering after a domain change | [LEGACY_DOMAIN_COMPATIBILITY.md](../docs/runbooks/LEGACY_DOMAIN_COMPATIBILITY.md) |
| Tenant apps on wildcard subdomains | [HOSTED_TENANT_APPS.md](../docs/runbooks/HOSTED_TENANT_APPS.md) |
| Installing on a host without git or internet access | [OFFLINE_TARBALL_DEPLOY.md](../docs/runbooks/OFFLINE_TARBALL_DEPLOY.md) |
| Moving the shared `ethora.com` environment | [ETHORA_COM_MIGRATION_RUNBOOK.md](../docs/ETHORA_COM_MIGRATION_RUNBOOK.md) and the checklists under `docs/checklists/` |

Architecture of what the deploy wires together, the AI subsystem and the
system diagram: [`docs/DEPLOY_ARCHITECTURE.md`](../docs/DEPLOY_ARCHITECTURE.md).

### Troubleshooting in three commands

```bash
deploy/scripts/health-check.sh                 # names the failing component
pm2 logs <service> --lines 300 --nostream      # backend, backend-jobs, ai-service, push, ...
docker logs --tail 200 deploy-<svc>-1          # mongo, mysql, xmpp, minio, redis
```

nginx logs are in `/var/log/nginx/`; the install and update logs are
whatever you redirected the script output to. The catalogue of known
symptoms is [TROUBLESHOOTING.md](../docs/runbooks/TROUBLESHOOTING.md).

## Quick QA checks

For a fast smoke test after install/update:

```bash
cd deploy
./scripts/qa-check.sh
```

This checks:
- API `/ping`
- Swagger spec JSON is valid at `/api-docs/swagger.json`
- MinIO health
- XMPP `/ws` endpoint probe

For a broader check (docker + PM2 + SSL + nginx):

```bash
./scripts/health-check.sh
```

## Hosted MCP server (optional)

The deploy can run the public [`ethora-mcp-server`](../ethora-mcp-server) as a
hosted service so AI agents and MCP clients (Claude, Cursor, ChatGPT, autonomous
agents) talk to this install over HTTPS instead of running the npm CLI locally.
It is the same tool set as the CLI, served over the MCP Streamable HTTP transport,
and it calls the local API over loopback like any other client - no backend
service is bypassed and every request passes the API's auth, tenant and rate-limit
middleware.

Off by default: single-tenant enterprise installs normally leave it disabled.
Enable it on multi-tenant installs that want to be reachable by agents.

```yaml
domains:
  mcp: mcp.chat.example.com   # optional; defaults to mcp.<root-of-web> when enabled

services:
  mcp:
    enabled: true
    port: 3030                    # loopback port the PM2 `mcp` process listens on
    enable_dangerous_tools: true  # app delete / bulk delete / wallet transfer for the token owner
```

What the deploy does when enabled:

- `setup-env.sh` renders `ethora-mcp-server/.env` from `templates/mcp.env.template`
  (API URL = `http://127.0.0.1:<backend port>/v1`, base app slug, public URL).
- `setup-node-services.sh` builds `ethora-mcp-server` and starts PM2 process `mcp`.
  Disabling the flag removes the PM2 process on the next deploy.
- `setup-ssl.sh` requests a certificate for the MCP host; `setup-nginx.sh` writes
  `ethora-mcp.conf` (SSE-friendly: no buffering, long read timeout).
- `health-check.sh` / `qa-check.sh` probe `/healthz` locally and
  `https://<domains.mcp>/.well-known/mcp` publicly.

Client endpoints on `https://<domains.mcp>` (local installs with `ssl.method: none`
serve the same paths at `http://localhost:<port>` with no nginx in front):

| Path | Who uses it | Identity |
|---|---|---|
| `/mcp` | developers, autonomous agents, custom connectors | `Authorization: Bearer <api key>` header, or the `ethora-user-login` / `ethora-user-register` tools inside the session |
| `/mcp/k/<api-key>` | Claude.ai / ChatGPT custom connectors (URL only, no headers) | the user's API key embedded in the path; paste once, authenticated in every conversation |
| `/mcp/oauth` | Claude.ai / ChatGPT connector directory listings | OAuth 2.1 (PKCE + dynamic client registration) against the backend authorization server |

OAuth: enabling the MCP service also renders `OAUTH_ISSUER` (default
`https://<domains.api>`, override with `services.mcp.oauth_issuer`) into the
backend env, which turns on `/.well-known/oauth-authorization-server`,
`/oauth/authorize`, `/oauth/token`, `/oauth/register` and `/oauth/revoke` on the
API host, and into the MCP env as `ETHORA_MCP_AUTH_ISSUER`, which publishes
`/.well-known/oauth-protected-resource` on the MCP host. `health-check.sh`,
`qa-check.sh` and the uptime `OAuth_metadata` tile probe both documents.

Log hygiene: the personal-URL entry point carries a credential in the request
path, so `ethora-mcp.conf` uses its own `log_format` (method, status, bytes,
timing; no request line) and writes to `/var/log/nginx/ethora-mcp.access.log`.

Authentication (API keys, bearer headers, and the session-bound login/signup
tools for clients that cannot send headers) is documented in the
[`ethora-mcp-server` README](../ethora-mcp-server/README.md).

Enabling the MCP service also raises the backend's per-IP auth limits (login
120/min, signup 30/min instead of 20/10), because hosted assistants such as
Claude and ChatGPT reach the API from a handful of vendor egress IPs shared by
all their users. Set explicit values in the top-level `rate_limits` block of
`deploy.yml` to override; per-email limits are unchanged.

## Feedback channel

The backend exposes `POST /v2/feedback` so users, and the AI agents acting for
them, can report a bug, an unexpected result or a feature request without
leaving whatever client they are in. The hosted MCP server is the main caller:
an agent has the failing tool, error code and request id in hand, so a report
sent from there carries the context a support ticket usually loses.

Submissions are always stored. Delivery is optional and configured per install:

```yaml
feedback:
  email_to: ""            # comma-separated; needs features.postmark enabled
  slack_webhook_url: ""   # Slack incoming webhook (keep out of version control)
  retention_days: 180     # 0 = keep forever
```

- **Email** rides on the existing Postmark settings, so it silently sends
  nothing when `features.postmark` is false. `setup-env.sh` warns when
  `email_to` is set on a Postmark-off install.
- **Slack** needs an incoming webhook created in the workspace first (Slack
  app → Incoming Webhooks → add one for the destination channel). The webhook
  URL is a secret: set it on the server's `deploy.yml`, never in git.
- **Leaving both blank is valid** and is the default: submissions are stored in
  Mongo and nothing leaves the install. That is the right setting for
  enterprise deployments that do not want feedback reaching a third party.
- **Retention** is `retention_days` (default 180). `0` keeps submissions until
  they are deleted by hand.

Rate limits live in the top-level `rate_limits` block as `feedback_max`
(per minute, authenticated) and `feedback_anon_max` (per hour, anonymous);
blank uses the backend defaults of 10 and 5.

## Uptime monitoring (ethora-uptime)

This deployment system can optionally run a local uptime dashboard/service (dockerized) alongside the Ethora stack. The monitoring service lives in the public repo/submodule [`ethora-uptime`](../ethora-uptime).

### Enable

In `deploy/config/deploy.yml`:

```yaml
services:
  uptime:
    enabled: true
    port: 8099
    postgres_port: 5433
```

Then run:

```bash
cd deploy
sudo ./scripts/install.sh
```

The deploy scripts generate:
- `deploy/generated/uptime/uptime.env`
- `deploy/generated/uptime/uptime.yml`

and start the stack via `deploy/docker-compose.uptime.yml`.

Open:
- `http://<server>:8099` (dashboard)
- `http://<server>:8099/api/summary` (JSON)

### Uptime instances: Local vs Public
The uptime wallboard shows two instance types:

- **Local** (e.g. “Astro Test”): Checks run from *inside* the uptime Docker container to services on the host or other containers. Uses `host.docker.internal` for API/MinIO and `xmpp:5280` for XMPP (same Docker network). Validates internal connectivity.
- **Public** (e.g. “Astro Test_Public”): Checks run over the internet to your public URLs (`https://api.*`, `https://xmpp.*`, etc.). Validates external TLS and Nginx routing.

If **Local** is red but **Public** is green, the uptime container may not reach the host (e.g. `host.docker.internal` not resolving on Linux). The deploy adds `extra_hosts: host.docker.internal:host-gateway`; if Local stays red, verify the uptime container is on the same network as the main stack.

### Recommended domain pattern (QA/Dev/Prod)

Use a 4th-level domain pattern so you can reuse the same 2nd-level domain across environments:

```
app.messenger-dev.example.com
api.messenger-dev.example.com
xmpp.messenger-dev.example.com
files.messenger-dev.example.com
uptime.messenger-dev.example.com
playground.messenger-dev.example.com
```

If you want the base app slug to be `messenger-dev` (instead of `app`), set:

```
base_app:
  domain_name: messenger-dev
```

## Backend jobs / cron runner (PM2)

The backend contains scheduled tasks (cron jobs). In the current (new major) layout, cron does **not** run inside the main PM2 process **`backend`**.

If the backend build contains a compiled jobs entrypoint (`dist/src/jobs.js`), the deploy scripts will also start a separate PM2 process:

- **`backend-jobs`**: runs scheduled tasks only (no HTTP server)

If `backend-jobs` is not running, scheduled tasks will not run.

## Repo integration model (how bumps work)

This matters for day-to-day development and deployments:

- **`ethora-backend/`** in monoserver is a **git submodule**.
  - Updating backend code requires:
    - pushing commits in `ethora-backend` (enterprise branch: `new-dev-tf`)
    - then bumping the submodule pointer in monoserver (commit in `ethora-monoserver`).
- **`ethora-app-reactjs/`** in monoserver is a **git submodule**.
  - Updating frontend code requires:
    - pushing commits to the frontend repo (branch: `dev-tf`)
    - then bumping the frontend submodule pointer in monoserver.

### Optional synthetic regression test (journeys)

The uptime service supports opt-in synthetic journeys. They are generated from the monoserver uptime templates and are disabled by default unless noted otherwise.

Available journey checks:
- `journey` → basic flow (user/admin auth path)
- `journey_advanced` → broader runtime flow
- `journey_b2b` → tenant-admin / B2B flow (apps → users → chats → memberships → cleanup)

To enable them:
- edit `deploy/generated/uptime/uptime.yml` or the source template `deploy/templates/uptime-config.yml.template`
- set the required `ETHORA_*` env vars in `deploy/generated/uptime/uptime.env` (or template)

Additional env for `journey_b2b`:
- `ETHORA_B2B_APP_ID`
- `ETHORA_B2B_APP_SECRET`

These should be the **tenant/root app** credentials, not a child app credential. The backend stores and resolves tenant-scoped B2B signing from the tenant/root app record.

`update.sh` already reruns `deploy/scripts/setup-env.sh`, so template changes in monoserver regenerate `deploy/generated/uptime/uptime.env` and `deploy/generated/uptime/uptime.yml` automatically on update.

### Optional push service validation (no mobile app)

The stack includes an integrated **push microservice** (FCM) used by the backend routes under `/v1/push/*`.

To validate the Firebase service account setup **without a mobile app**, you can enable the optional Uptime check:

- `type: push_validate` (see `deploy/templates/uptime-config.yml.template`)

It performs a Firebase **dry-run** validation via:

- `POST /v1/push/validate/{appId}`

## Local Testing

For testing the deployment automation locally without SSL certificates or domain names, see [TESTING.md](./TESTING.md) for detailed instructions.

## Path Configuration

Covered in [How an install is laid out](#how-an-install-is-laid-out).
[PATHS.md](./PATHS.md) has the history of the path variables and the
legacy layouts the scripts still recognise.

## Prerequisites

### System Requirements

- **OS**: Ubuntu 22.04 or 24.04 (other Debian-based distributions may work)
- **RAM**: Minimum 4GB, recommended 8GB+
- **Disk**: Minimum 20GB free space
- **Network**: Public IP address with DNS records configured

### Required Software

The installer will check for and attempt to install these, but you can install them manually:

- **Docker** (20.10+)
- **Docker Compose** (1.29+)
- **Node.js** (18+)
- **npm** or **pnpm**
- **PM2** (for process management)
- **Nginx**
- **Certbot** (for SSL certificates)
- **yq** (YAML parser - will be auto-installed if missing)

### DNS Configuration

Before deployment, ensure DNS A records are configured for:

- `api.chat.yourdomain.com` → Your server IP
- `app.chat.yourdomain.com` → Your server IP
- `xmpp.chat.yourdomain.com` → Your server IP
- `files.chat.yourdomain.com` → Your server IP
- Optional widget host: `widget.chat.yourdomain.com` → Your server IP
- Optional hosted-app root: `chat.yourdomain.com` → Your server IP
- Optional hosted-app wildcard: `*.chat.yourdomain.com` → Your server IP

## Configuration

### Configuration File

The main configuration file is `config/deploy.yml`. Copy the template and customize it:

```bash
cp config/deploy.yml.template config/deploy.yml
```

### Configuration Options

#### Domain Configuration

```yaml
domains:
  api: api.chat.example.com          # Backend API domain
  web: app.chat.example.com          # Frontend web app domain
  xmpp: xmpp.chat.example.com        # XMPP server domain
  files: files.chat.example.com      # MinIO file storage domain
  widget: widget.chat.example.com    # Dedicated AI widget host
  mcp: mcp.chat.example.com          # Optional hosted MCP server host (defaults to mcp.<root-of-web> when services.mcp.enabled)
  hosted_apps_root: chat.example.com   # Optional tenant suffix -> <app>.chat.example.com
```

Optional legacy compatibility during cutover:

```yaml
legacy_domains:
  enabled: true
  web: app.example.com
  web_mode: redirect
  files: files.example.com
  files_mode: proxy
```

#### SSL Configuration

**Option 1: Let's Encrypt (Recommended)**

```yaml
ssl:
  method: certbot
  email: admin@example.com      # Email for Let's Encrypt notifications
  # Optional dedicated wildcard cert just for hosted tenant apps:
  # hosted_apps_cert_path: /etc/letsencrypt/live/chat.example.com/fullchain.pem
  # hosted_apps_key_path: /etc/letsencrypt/live/chat.example.com/privkey.pem
```

**Option 2: Provide Your Own Certificates**

```yaml
ssl:
  method: provided
  cert_path: /path/to/cert.pem
  key_path: /path/to/key.pem
  # Optional separate wildcard cert for hosted tenant apps:
  # hosted_apps_cert_path: /path/to/chat-wildcard-fullchain.pem
  # hosted_apps_key_path: /path/to/chat-wildcard-privkey.pem
```

#### Database Configuration

```yaml
databases:
  mongo:
    port: 27017
    database: ethora_prod
  mysql:
    port: 3306
    root_password: # Auto-generated if not provided
  redis:
    port: 6379
```

#### Service Configuration

```yaml
services:
  backend:
    port: 8080
    node_env: production
    client_max_body_size: 50M  # Nginx API upload/request body limit
  widget:
    enabled: true
    script_version: ""
  hosted_apps:
    enabled: false
  ai_service:
    enabled: true              # Enable/disable AI service
    port: 8013
  docs_parse_service:
    enabled: true              # Enable/disable docs parse service
    port: 8201
  crawler:
    enabled: false             # AI crawler (optional)
    port: 8000
    callback_url: ""           # Optional; see "Crawler callback" below
  ejabberd:
    admin_password: # Auto-generated if not provided
```

#### Feature Flags

```yaml
features:
  blockchain: false            # Disable blockchain for enterprise
  ai_service: true             # AI umbrella flag. If false, ai-service/docs-parse/crawler are forced off.
  analytics: false
  stripe: false               # Disable Stripe for enterprise
  postmark: false             # Disable Postmark for enterprise
  iap: false                  # Disable in-app purchases / subscription cron
  firebase: false             # Disable Firebase Admin integration (backend)
  immutable_logs: false       # Tamper-evident audit log export to S3 (see below)
```

#### Immutable Audit Logs (S3 export)

`features.immutable_logs` gates the tamper-evident audit log export. When it is
`true`, the log-export job periodically ships the audit log file to an
S3-compatible bucket you own; when it is `false`, nothing is rendered into any
service `.env` and **no service attempts to reach S3**.

The log file format, the write logic and the uploader itself belong to a
separate service - this repo owns only the configuration contract below.

```yaml
features:
  immutable_logs: true

integrations:
  immutable_logs:
    interval_hours: 6           # How often (in hours) the log-upload job runs (default: 6)
    aws_access_key_id: ""       # IAM user's access key ID
    aws_secret_access_key: ""   # IAM user's secret access key
    aws_region: ""              # AWS region the bucket lives in (e.g. eu-central-1)
    aws_s3_bucket_name: ""      # Exact name of the bucket used to store the files
```

Rules:

- **All five fields are required when the flag is on.** `deploy/scripts/validate.sh`
  aborts the install with a clear error if any of `aws_access_key_id`,
  `aws_secret_access_key`, `aws_region`, `aws_s3_bucket_name` is missing, or if
  `interval_hours` is not a positive integer.
- **When the flag is off**, the fields are ignored. They are still allowed to be
  present in `deploy.yml` (blank or filled) - the deploy scripts render them as
  empty and never hand them to a service.
- **Rendered into:**
  - `ethora-backend/services/api/.env` - as `IMMUTABLE_LOGS_ENABLED`,
    `IMMUTABLE_LOGS_INTERVAL_HOURS`, `IMMUTABLE_LOGS_AWS_ACCESS_KEY_ID`,
    `IMMUTABLE_LOGS_AWS_SECRET_ACCESS_KEY`, `IMMUTABLE_LOGS_AWS_REGION`,
    `IMMUTABLE_LOGS_AWS_S3_BUCKET_NAME`.
  - `deploy/generated/immutable-logs/immutable-logs.env` (mode `600`) - a
    standalone env file for the export service, generated **only** while the
    flag is on. Turning the flag off deletes it on the next
    `setup-env.sh`/`update.sh` run, so a decommissioned install stops holding
    AWS credentials on disk.
- **The `IMMUTABLE_LOGS_` prefix on the AWS names is deliberate.** Unprefixed
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` are picked up
  implicitly by every AWS SDK in the process and would silently repoint
  unrelated S3/MinIO clients at this bucket's credentials.
- **Secrets stay out of git.** `deploy/config/deploy.yml` is gitignored (see
  `deploy/.gitignore`) and `deploy/generated/` is gitignored at the repo root  - 
  only the `*.template` files, which ship with empty values, are tracked.
- Retention / object-lock / lifecycle rules on the bucket are configured in AWS,
  not here. Give the IAM user write-only access to this one bucket
  (`s3:PutObject` on the bucket ARN); the platform never reads the objects back.

#### Admin Configuration

```yaml
admin:
  email: admin@example.com
  password: # Will prompt if not provided
```

#### Security

```yaml
security:
  jwt_secret: # Auto-generated if not provided
  refresh_secret: # Auto-generated if not provided
```

## Deployment

### Step-by-Step Deployment

The commands are in [Install](#install). What the installer does, in order:

1. Checks `sudo` and installs prerequisites that are missing: Docker, Node.js, nginx, certbot, `yq`.
2. Reads `deploy.yml` and runs `preflight-paths.sh` (source, target and data directories must not overlap).
3. Enables a swap file on small hosts and copies the source tree into the target directory.
4. Validates `deploy.yml` (`validate.sh`), including the license block.
5. Renders every `.env` and config file from `deploy.yml` (`setup-env.sh`, `setup-ejabberd-config.sh`).
6. Obtains or installs TLS certificates and writes the nginx vhosts (`setup-nginx.sh`).
7. Stops any previous Ethora stack, then starts the Docker services (MongoDB, Redis, MinIO, MySQL, ejabberd, Centrifugo, AI Postgres, uptime) and waits for them.
8. Seeds the base app and admin user (`init-services.sh`).
9. Builds and starts the Node services under PM2, or their containers in image mode (`setup-node-services.sh`).
10. Runs pending data migrations (`run-migrations.sh`).
11. Runs the health checks and prints the URLs.

### What Gets Deployed

The deployment system sets up:

- **Backend API** (Node.js/Express)
  - MongoDB database
  - Redis cache
  - MinIO object storage
  - Centrifugo real-time messaging
  - Crawler service (optional; enabled via `services.crawler.enabled` + `features.ai_service: true`)

- **Ejabberd XMPP Server**
  - MySQL database
  - Custom modules
  - SSL/TLS encryption

- **AI Service** (optional)
  - OpenAI-compatible AI integration via configurable `ai.ai_api_url` + `ai.ai_api_key`
  - Can be disabled entirely for enterprise installs via `features.ai_service: false`
  - RAG capabilities
  - Runs under PM2 in this deployment flow; `crawler` remains Dockerized
  - Uses MongoDB plus a Postgres / pgvector database referenced by `PG_URL`
  - By default deploy provisions a dedicated managed pgvector database via `deploy/docker-compose.ai.yml`
  - If `services.ai_service.pg_url` is set, deploy skips the managed DB and uses that external Postgres instead

- **Docs Parse Service** (optional)
  - Document parsing and processing

- **Hosted MCP server** (optional, `services.mcp.enabled: true`)
  - `ethora-mcp-server` running as PM2 process `mcp` with the Streamable HTTP transport
  - Published by nginx at `https://<domains.mcp>/mcp`; proxies to the local API over loopback
  - See [Hosted MCP server (optional)](#hosted-mcp-server-optional)

- **Frontend** (React/Vite)
  - Production build
  - Served via Nginx

- **Nginx Reverse Proxy**
  - SSL/TLS termination
  - Domain routing
  - Static file serving

## Security Considerations

### SSL/TLS

- All domains use HTTPS with valid SSL certificates
- Certificates auto-renew via Certbot
- Strong SSL/TLS protocols and ciphers configured

### Passwords

- Auto-generated passwords are stored in `config/deploy.yml`
- **Important**: Secure this file with proper permissions:
  ```bash
  chmod 600 deploy/config/deploy.yml
  ```

### Firewall

Recommended firewall configuration:

```bash
# Allow SSH
sudo ufw allow 22/tcp

# Allow HTTP/HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Allow XMPP (if needed externally)
sudo ufw allow 5280/tcp
sudo ufw allow 5443/tcp

# Enable firewall
sudo ufw enable
```

### Database Security

- MongoDB: Configured with replica set (local only)
- MySQL: Root password auto-generated
- Redis: No password (local only, behind firewall)

### Service Isolation

- All services run in Docker containers
- Services communicate via internal Docker network
- Only necessary ports exposed to host

## Post-Deployment

### Access Your System

- **API**: `https://api.yourdomain.com`
- **Web App**: `https://app.yourdomain.com`
- **API Docs (Swagger)**:
  - Hosted (Ethora main): `https://api.ethoradev.com/api-docs/`
  - Enterprise/self-hosted: `https://api.<your-domain>/api-docs/` (example: `https://api.yourdomain.com/api-docs/`)
- **MinIO Console**: `http://localhost:9001` (local only)

### Initial Setup

1. **Login to Admin Panel:**
   - Go to `https://app.yourdomain.com`
   - Use admin credentials from `deploy.yml`

2. **Configure Base App:**
   - The base app is automatically created
   - Customize settings via admin panel

3. **Create Additional Apps:**
   - Use the admin panel to create new apps
   - Configure app-specific settings

### Maintenance

#### Update Services

Use `update.sh` (see [Update and rollback](#update-and-rollback)); it
pulls, re-renders configuration, rebuilds what changed and restarts. Do not
run the compose files or `setup-node-services.sh` by hand on a production
host: the compose files need the data-directory variables from
`deploy/.deploy.env` exported, and the enterprise stack shares one compose
project, so a bare `docker compose up` from the wrong directory can
recreate or remove the wrong containers.

#### Backup

```bash
cd ~/ethora-install-shared
sudo deploy/scripts/export-stateful-snapshots.sh --label nightly \
    --output-dir /home/ubuntu/backups/$(date -u +%Y%m%dT%H%M%SZ)
```

plus `deploy/config/deploy.yml`, `deploy/.deploy.env` and a tar of
`~/ethora-data/minio`. Restore procedures, a stopped-stack snapshot
alternative, cron and retention: [BACKUP_AND_RESTORE.md](../docs/runbooks/BACKUP_AND_RESTORE.md).

#### Monitoring

- Use PM2 monitoring: `pm2 monit`
- Check Docker stats: `docker stats`
- Monitor Nginx: `sudo tail -f /var/log/nginx/access.log`

#### System Maintenance

The maintenance script checks all services and automatically restarts any that are down:

```bash
# Check and restart services
sudo ./scripts/maintain.sh

# Check only (dry run, don't restart)
sudo ./scripts/maintain.sh --dry-run
```

**Schedule automatic maintenance** (recommended for production):

```bash
# Add to crontab to run every 5 minutes
sudo crontab -e
# Add this line:
*/5 * * * * /path/to/ethora-monoserver/deploy/scripts/maintain.sh >> /var/log/ethora-maintain.log 2>&1
```

The maintenance script checks:
- **Docker services**: MongoDB, MySQL, Redis, MinIO, Ejabberd, Centrifugo, Crawler
- **PM2 services**: Backend, Frontend (dev mode), AI Service, Docs Parse Service

## Support

1. Run `deploy/scripts/health-check.sh`; it names the failing component.
2. Look the symptom up in [TROUBLESHOOTING.md](../docs/runbooks/TROUBLESHOOTING.md).
3. Send the health-check output, the install or update log and
   `pm2 logs <service> --lines 500 --nostream`. Never send `deploy.yml` or
   `.deploy.env`; they hold every secret of the install.
