# Ethora operator quick start

The commands to install, update, roll back and check an Ethora instance you
operate yourself. This page is meant to be sent as a link; the full
reference is [`deploy/README.md`](../deploy/README.md).

The examples assume Ubuntu 22.04 or 24.04, a user named `ubuntu` with
`sudo`, DNS records for your hosts pointing at the machine, and read
access to the `ethora-install-shared` repository through a deploy key at
`/home/ubuntu/.ssh/id_ed25519`. Replace `2609` with the release line you
were given.

## Directories

| Directory | Purpose |
|---|---|
| `~/ethora-install-shared` | the checkout you run commands from, and the only place `deploy.yml` lives |
| `~/ethora` | the live install, rebuilt by every deploy |
| `~/ethora-data` | your data (MongoDB, MinIO, MySQL, Redis). Back this up. |

## Install

```bash
git clone -b 2609 git@github.com:dappros/ethora-install-shared.git ~/ethora-install-shared
cd ~/ethora-install-shared

deploy/scripts/setup.sh --domain chat.example.com --admin-email ops@example.com --yes

sudo deploy/scripts/install.sh
deploy/scripts/health-check.sh
```

`setup.sh` writes `deploy/config/deploy.yml`, derives every host from the
root domain (`api.`, `app.`, `xmpp.`, `files.`, `playground.`, `uptime.`),
generates all secrets and prints the admin password once. Run it without
`--yes` to be prompted, or edit `deploy/config/deploy.yml` afterwards:
the file is fully commented. Allow 20 to 40 minutes for the install.

The admin panel is at `https://app.<your root domain>`, the API at
`https://api.<your root domain>` with Swagger at `/api-docs/`.

Before sharing the URL: sign in as the admin, change the password and enrol
in two-step verification under Account > Security, then require it for
administrators on the base app (App settings > Sign-on options). Details in
[deploy/README.md](../deploy/README.md#first-login-secure-the-superadmin-account).

Lost the admin password or authenticator, or no email set up for reset
links? From the deploy directory: `sudo ./scripts/admin-reset.sh list`, then
`temp-password`, `clear-mfa`, `set-email` or `create` with `--email`. See
[deploy/README.md](../deploy/README.md#recover-or-manage-the-superadmin-from-the-host).

**Docker Compose instead of the installer.** `deploy/compose/` runs the
same Core images as one compose project with Caddy for TLS; nothing is
installed on the host beyond Docker. `./configure.sh --domain ... --admin-email ...`
then `docker compose up -d`; update with `docker compose pull && docker compose up -d`.
Its README covers backup and restore of the named volumes.

## Update

```bash
cd ~/ethora-install-shared
sudo GIT_SSH_COMMAND="ssh -i /home/ubuntu/.ssh/id_ed25519 -o IdentitiesOnly=yes" \
    deploy/scripts/update.sh --ref 2609
```

- Same `--ref` as you run: picks up the latest fixes on that release line.
- Next release line (for example `--ref 2610`): upgrades. Read the
  [release notes for operators](RELEASE_NOTES_OPERATORS.md) for that line
  first; it lists new `deploy.yml` keys and anything that needs a decision.
- `GIT_SSH_COMMAND` on the `sudo` line is required: the fetch runs as root,
  which has no key.
- Allow 10 to 20 minutes. Services restart near the end; chat clients
  reconnect on their own.
- Configuration changes use the same command: edit `deploy/config/deploy.yml`,
  then run `update.sh` with the ref you are on.

## Roll back

```bash
sudo GIT_SSH_COMMAND="ssh -i /home/ubuntu/.ssh/id_ed25519 -o IdentitiesOnly=yes" \
    deploy/scripts/update.sh --rollback <commit sha>
```

The update log prints the commit the host ran before it fetched
(`Source SHA before fetch`). Data is never rolled back; every data
migration is written so the previous release keeps working.

## Check

```bash
deploy/scripts/health-check.sh     # every service, license state, public URLs
pm2 list                           # Node services
docker ps                          # databases, XMPP, MinIO, Centrifugo
pm2 logs backend --lines 200       # API log
```

## License

No key is needed. Without one the install is Ethora Core: 5 apps and 500
user accounts per server, no expiry. Register for free from the admin
panel (License page) to raise that to 10 apps and 5,000 accounts and get
e-mail support. An enterprise key goes in `deploy/config/deploy.yml` under
`license.key` or is pasted on the same page; a renewed key is applied by
editing the file and running `update.sh`, or by pasting it.

## Back up

Nightly, from cron or by hand:

```bash
cd ~/ethora-install-shared
sudo deploy/scripts/export-stateful-snapshots.sh --label nightly --output-dir /home/ubuntu/backups/$(date -u +%Y%m%dT%H%M%SZ)
```

plus a copy of `deploy/config/deploy.yml`, `deploy/.deploy.env` and
`~/ethora-data/minio`. Restore steps and a stopped-stack alternative:
[backup and restore](runbooks/BACKUP_AND_RESTORE.md).

## Getting help

Send the output of `deploy/scripts/health-check.sh`, the update or install
log (`update.sh` prints it to the terminal; redirect it to a file for long
runs), and `pm2 logs backend --lines 500 --nostream` for the failing
service. Never send `deploy.yml` or `.deploy.env` as-is; they contain
every secret of the install.
