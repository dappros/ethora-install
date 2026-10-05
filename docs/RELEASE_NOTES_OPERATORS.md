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

**Seed superadmin is bootstrap only.** The `admin:` block in `deploy.yml`
(`email`, `password`) now creates the first administrator once, when the
base app has no superadmin, and is never read again: changing it later does
nothing, and an update no longer re-creates a seed account you deleted.
Leave `admin.password` empty; `setup.sh` fills in a generated one and the
installer keeps it in `deploy/.deploy.env`. The old template value
`admin123` is refused and flagged by the end-of-deploy configuration gap
report. Recovery and extra superadmins: `deploy/scripts/admin-reset.sh`.
Also applied to 2609.

**Licensing and editions.** New `deploy.yml` block `license:` (`key`,
`key_file`, `call_home`, `server_url`, `grace_days`), all optional. Without
a key an install is Ethora Core (unregistered): Core features, 5 apps and
500 user accounts per server, no expiry, nothing locked. Registering from
the admin panel License page (free) raises the caps to 10 and 5,000. An
enterprise key unlocks the paid modules (AI agents need it) and lifts the
caps. Existing installs upgrading to 2610 with more than 5 apps or 500
users keep working; they cannot create more until they register or install
a key, so get the key before upgrading a production install. Chat is never
gated. Reference: [LICENSING.md](LICENSING.md).

**Image mode.** Every Node service can run from a prebuilt container
instead of being built on the host: `services.<name>.mode: source | image`
and `services.<name>.image` for `backend`, `frontend`, `ai_service`,
`push`, `playground`, `mcp` and `ejabberd`. Default stays `source`; nothing changes
unless you switch. Verified on our QA, not yet used on customer instances.
Reference: [CONTAINER_IMAGES.md](CONTAINER_IMAGES.md).

**Editions.** `deploy.yml` gains `edition: core | full`. Core (written by
`setup.sh --edition core`) enables only the API, admin panel and XMPP and
pulls the public Docker Hub images; it is what the public installer
distributes. Existing files without the key are `full`.

**Image versions.** Builds are numbered `<line>.<n>` (`2610.4`); the git tag
of the same name marks the commit. `deploy.yml` can pin a build instead of
the moving line tag.

**Setup engine.** `deploy/scripts/setup.sh` writes `deploy.yml` from a few
answers (root domain, admin email, license key, TLS, AI, modules) and can
reconfigure an existing file with `--from`. Optional; hand-edited files
keep working.

**ejabberd MySQL schema: MUC index width.** Existing databases are altered
on the next update (`scripts/ensure-ejabberd-sql-schema.sh`, online, no
restart): the unique indexes of `muc_room`, `muc_online_room`,
`muc_online_users` and `muc_registered` move from a 75- to a
191-character prefix. The old width made every 1:1 room of the same first
member one row, so ejabberd lost such rooms on restart. The
`reconcile-muc-rooms` data migration then recreates the rooms that exist
in Mongo but not in ejabberd and sets the missing affiliations; it logs
one line per room it touches. Runbook: TROUBLESHOOTING.md 7d.

**PM2 process metrics.** With monitoring on (`local` or `remote`),
`setup-node-services.sh` also starts `pm2-exporter` under pm2
(`deploy/monitoring/pm2-exporter/pm2-exporter.js`, host port 9209, no
dependencies): CPU, memory, restarts and status per pm2 process (backend,
backend-jobs, push, ai-service, ...). Prometheus scrapes it as job `pm2` and
the dashboards gain "PM2 — CPU % by process" and "PM2 — memory (MB) by
process". The exporter answers loopback and private-range clients only;
keep port 9209 closed in the firewall. With monitoring off it is removed.

**Monitoring modes.** `services.monitoring.mode: off | local | remote`
replaces `enabled` (still honoured: `enabled: true` is `local`). `local`
is the stack as before, on the host. `remote` keeps only the agents on
the host and pushes metrics, and with `logs.enabled` the logs, to the
central monitoring server set in `services.monitoring.remote` (URL,
token and tenant name from that server's config).

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

**Stats email.** The daily and weekly report to
`analytics.daily_report_receivers` now opens with activity figures (signups,
active people, messages from people and from agents, AI agent replies, API /
MCP calls, files) compared with the trailing week, then the top apps by
messages, API calls, agent replies and new users, then the signup tables.
Logins are listed per person rather than per login; the per-login rows stay
in the CSV attachment. Anonymous widget visitors are counted, not listed, and
synthetic uptime traffic is excluded. The AI block reads the ai-service
database: new optional `AI_SERVICE_MONGO_URI` in the backend env (rendered by
the template; defaults to the `aiservice` db on the main Mongo). To check a
report against real data without waiting for the cron:
`node dist/scripts/deploy/report-preview.js [--weekly] [--date YYYY-MM-DD] --out /tmp/report.html`
from `ethora-backend/services/api`.

**Website widget: visitors on demand.** The hosted widget (`assistant.js`,
served from every line) creates its anonymous visitor account, XMPP account
and room when the launcher is first hovered or opened, not on every page
view, and a returning visitor gets the same account and conversation back
(the API returns their existing room on resume; both lines carry the API
change). Expect far fewer `isVisitor` users and widget rooms per day; the
stats email counts the remaining ones separately.

**AI agents: room replay.** The ai-service no longer persists widget rooms
to an agent's joined-room list and replays at most `AI_BOT_MAX_REPLAY_ROOMS`
(default 200) persisted rooms when an agent comes online; refused joins are
logged as `room join refused`. Installs that ran a widget before this change
should run, from `ethora-backend/services/api`,
`node dist/scripts/deploy/prune-bot-widget-rooms.js --dry-run` and then
without the flag, to drop the accumulated rooms; a long list made the agent
miss new conversations after a restart once it passed ejabberd's
`max_user_conferences`.

**Host.** No new ports. Node.js 24 as in 2609.

## 2609 (production line, promoted 2026-09-15)

**Seed superadmin is bootstrap only** (from 2026-10-02 on this line). The
`admin:` block in `deploy.yml` creates the first administrator once, when the
base app has no superadmin, and is never read again; an update no longer
re-creates a seed account you deleted. Leave `admin.password` empty (a
generated one is kept in `deploy/.deploy.env`); `admin123` is refused.
Recovery and extra superadmins: `deploy/scripts/admin-reset.sh`.

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
