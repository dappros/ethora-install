# Release notes for operators

What changes for the person running an install when moving between
release lines: new `deploy.yml` keys, new services or ports, host
requirements, data migrations, and anything that needs a decision before
the upgrade. Application features are listed only where they have an
operational side.

Release lines are branches named by year and month. Upgrading is
`update.sh --ref <line>` from the previous line; skipping a line is
supported, read every section in between. New `deploy.yml` keys always
have a default, so an unedited file keeps working; the notes say when the
default is not what you want.

## 2610 (development line, September 2026)

**Licensing.** The backend enforces a signed license key. New `deploy.yml`
block `license:` (`key`, `key_file`, `call_home`, `server_url`,
`grace_days`). Without a key every feature works for 14 days, then
creating apps and users is restricted and the admin panel is locked until
a key is installed; chat is never gated. Get a key before upgrading a
production install. Reference: [LICENSING.md](LICENSING.md).

**Image mode.** Every Node service can run from a prebuilt container
instead of being built on the host: `services.<name>.mode: source | image`
and `services.<name>.image` for `backend`, `frontend`, `ai_service`,
`push`, `playground`, `mcp` and `ejabberd`. Default stays `source`; nothing changes
unless you switch. Verified on our QA, not yet used on customer instances.
Reference: [CONTAINER_IMAGES.md](CONTAINER_IMAGES.md).

**Setup engine.** `deploy/scripts/setup.sh` writes `deploy.yml` from a few
answers (root domain, admin email, license key, TLS, AI, modules) and can
reconfigure an existing file with `--from`. Optional; hand-edited files
keep working.

**Monitoring alerts.** `services.monitoring.alerts.emails` and the
`smtp_*` keys configure Grafana alert e-mail. Leave empty to disable;
earlier 2610 builds crash-looped Grafana on an empty address, fixed
before the line was promoted.

**Alert screenshots.** `services.monitoring.screenshots` (default
`false`) attaches a panel screenshot to alert e-mails. It runs a headless
Chromium renderer container that needs about 400 MB of RAM; leave it off
on 4 GB hosts.

**MinIO image source.** MinIO no longer publishes to Docker Hub; the
enterprise compose file pulls `quay.io/minio/minio` at the release
already deployed everywhere. Hosts with the image cached see a container
recreate on the next update; fresh installs on the previous lines fail to
pull unless they carry the same fix (applied to 2609 as well).

**End-to-end encryption, per app.** `features.e2ee` in `deploy.yml` is now
the install gate only. Each app opts in separately through **App Settings >
Chats > End-to-End Encryption**, off by default, so turning the deploy flag
on surfaces the choice to app owners without encrypting anyone's chats. The
API refuses `POST /v1/chats/private` with `e2ee: true` on an app that has
not opted in (`403 E2EE_DISABLED`), including for server-to-server callers.
Encrypted rooms stay encrypted for life: switching an app back off stops new
ones being created and cannot decrypt existing ones — and nothing in an
encrypted room is moderatable, searchable, exportable or recoverable by the
operator. No migration: apps that predate the setting read as off.

**Host.** No new ports. Node.js 24 as in 2609.

## 2609 (production line, promoted 2026-09-15)

**Node.js 24.** `install.sh` installs Node 24 and `update.sh` switches a
host from Node 20 on its first run (`ensure_node_major`). Builds take the
same time; PM2 restarts under the new runtime. Nothing to do by hand.

**Hosted MCP server.** New optional service `mcp` (PM2 name `mcp`,
default port 3030, host `mcp.<root domain>`), `deploy.yml` block
`services.mcp:` (`enabled`, `port`, `enable_dangerous_tools`,
`oauth_issuer`, `openai_apps_challenge`), new nginx vhost and certificate
when enabled. Default `enabled: false`. Reference:
[`deploy/README.md`, Hosted MCP server](../deploy/README.md#hosted-mcp-server-optional).

**Feedback channel.** `feedback:` block (`email_to`, `slack_webhook_url`,
`retention_days`). Feedback submitted from the apps and MCP tools is
stored 180 days by default and forwarded when a destination is set.

**Rate limits.** `rate_limits:` block to override the auth and feedback
limits per install. Empty values keep the built-in limits.

**Translation.** `translate.languages` lists the languages offered for
message translation (needs an AI provider key).

**AI defaults.** `services.ai_service.chat_model` default moved to
`gpt-5.6-luna`; per-agent override in the admin panel. `platform_*` and
`gateway_*` keys under `ai_service` configure the platform-provided AI
quota and gateway for installs without their own key.

**Optional e-mail verification.** Verification is optional platform-wide;
only the OAuth consent step (MCP) guides users through it. No config.

**Data migrations.** `run-migrations.sh` runs from `install.sh` and
`update.sh`; the `source-agent-id-v2` migration attributes indexed sources
to agents. Automatic, idempotent, safe to run while serving.

## 2608 (August 2026)

**Clean path layout.** Source, target and data directories must be
distinct; `preflight-paths.sh` stops a deploy whose layout overlaps or
whose data sits inside a tree. Installs from before this line need the
one-time move in [MIGRATE_TO_CLEAN_PATHS.md](MIGRATE_TO_CLEAN_PATHS.md).
This is the one upgrade that can require manual work; budget ten
minutes plus a restart.

**Data directory variables.** `MONGO_DATA_DIR`, `MINIO_DATA_DIR`,
`MYSQL_DATA_DIR`, `REDIS_DATA_DIR` are persisted in `deploy/.deploy.env`
and the compose file refuses to start without them (fail-closed), so a
database can no longer start against the wrong directory.

**Message archive endpoint.** `services.ejabberd.track_message_url`
points ejabberd's archival module at the API so unread counts and message
search work. Empty keeps archival off.

**Analytics keys.** `frontend.posthog_key`, `frontend.posthog_host`.
Empty by default.

**Config gap report.** `report-config-gaps.sh` lists `deploy.yml` keys the
current template has and your file does not.

## 2607 (July 2026)

**Soft delete and portable bundles.** Lifecycle status on apps and users,
a cascade purge worker inside `backend-jobs`, JSON / ZIP export and import
of apps and agents. No new services, ports or keys. Reference:
[SOFT_DELETE_AND_BUNDLES.md](SOFT_DELETE_AND_BUNDLES.md).

**Per-agent source ownership.** Carries the `source-agent-id` data
migration; automatic on update, and the application reads correctly before
and after it completes.

**Secure files host.** `domains.secure_files` serves authenticated chat
attachments from its own host and certificate. Blank keeps the feature
off; add the DNS record before enabling.

## Earlier lines

`2606` and earlier predate these notes. The [MIGRATE_TO_CLEAN_PATHS.md](MIGRATE_TO_CLEAN_PATHS.md)
guide covers the path layout change that every older install meets first;
after that, upgrade one line at a time and run `health-check.sh` between
them.
