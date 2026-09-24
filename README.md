# Ethora install

The deploy system for a self-hosted [Ethora](https://ethora.com) instance:
one command to install from the published container images, one to update.
This repository is published automatically from the Ethora integration
repository; one branch per release line (`2610`, `2609`, ...), the highest
being the current line.

## Install

Ubuntu 22.04 or 24.04, a user with `sudo`, DNS records for your hosts, and
a license key (get a trial at the address your Ethora contact gave you;
without a key everything runs for 14 days).

```bash
git clone -b 2610 https://github.com/dappros/ethora-install.git ~/ethora-install-shared
cd ~/ethora-install-shared

deploy/scripts/setup.sh --domain chat.example.com --admin-email ops@example.com \
    --license-key 'ETHORA1....' --all-modes image --yes

sudo deploy/scripts/install.sh
deploy/scripts/health-check.sh
```

`setup.sh` derives every host from the root domain (`api.`, `app.`, `xmpp.`,
`files.`, ...), generates all secrets and writes a fully commented
`deploy/config/deploy.yml`. `--all-modes image` makes every service run from
the published images (`ghcr.io/dappros/ethora-*`); nothing is compiled on
the host. Allow 10 to 15 minutes, most of it image pulls.

The admin panel is at `https://app.<root domain>`, the API at
`https://api.<root domain>` (Swagger at `/api-docs/`).

## Update

```bash
cd ~/ethora-install-shared
sudo deploy/scripts/update.sh --ref 2610
```

Same `--ref`: latest fixes on that line. Next line: upgrade; read
[docs/RELEASE_NOTES_OPERATORS.md](docs/RELEASE_NOTES_OPERATORS.md) first.

## Documentation

- [docs/OPERATOR_QUICKSTART.md](docs/OPERATOR_QUICKSTART.md): install, update, rollback, checks, license, backup on one page.
- [deploy/README.md](deploy/README.md): the full reference (layout, configuration keys, every service).
- [docs/LICENSING.md](docs/LICENSING.md): how license keys work, the grace window, air-gapped installs.
- [docs/CONTAINER_IMAGES.md](docs/CONTAINER_IMAGES.md): the images, what each replaces, image mode internals.
- [docs/runbooks/](docs/runbooks/): backup and restore, troubleshooting, migrations.

## What is where

| Directory | Purpose |
|---|---|
| `~/ethora-install-shared` | this checkout: scripts and the only `deploy.yml` |
| `~/ethora` | the live install, rebuilt by every deploy |
| `~/ethora-data` | your data (MongoDB, MinIO, MySQL, Redis). Back this up. |

Source-mode installs (building the components on the host) need the
component repositories and are documented for enterprise customers
separately; this repository covers image mode.

## Support

Run `deploy/scripts/health-check.sh` first; it names the failing component.
Send its output and the install or update log with your report. Never send
`deploy.yml` or `.deploy.env`: they hold every secret of the install.
