# Ethora install

Install and update a self-hosted [Ethora](https://ethora.com) server from
the published container images. One command installs, one updates. This
repository is published automatically from the Ethora integration
repository, one branch per release line (`2610`, `2609`, ...).

**Ethora Core** is what these images give you: the API, the admin panel and
web chat, and the XMPP server with the Ethora modules, plus their databases
(MongoDB, MySQL, Redis, MinIO, Centrifugo). AI agents, push notifications,
the SDK playground and the hosted MCP server are enterprise modules;
[contact Dappros](mailto:sales@ethora.com) for those.

## Before you start

1. A server: Ubuntu 22.04 or 24.04, x86-64 or arm64, 2 vCPU and 4 GB RAM
   minimum (8 GB recommended), 40 GB disk, a public IP, ports 80 and 443
   open (and 5222, 5443 if you want XMPP clients other than the web app).
   A user with `sudo`. The installer installs Docker, nginx, certbot and the
   few tools it needs.
2. A root domain for the install, for example `chat.example.com`, with these
   DNS records pointing at the server (all plain A or AAAA records, no proxy):
   `api.`, `app.`, `xmpp.`, `files.` under that root. `setup.sh` prints the
   exact names before it writes anything.
3. A license key. Get a 14-day trial at
   [https://license.ethora.com/trial](https://license.ethora.com/trial);
   without a key the install runs every feature for 14 days, then restricts
   creating apps and users until a key is added. Chat keeps working.

## Install

```bash
git clone -b 2610 https://github.com/dappros/ethora-install.git ~/ethora-install-shared
cd ~/ethora-install-shared

deploy/scripts/setup.sh --edition core --all-modes image \
    --domain chat.example.com --admin-email ops@example.com \
    --license-key 'ETHORA1....'

sudo deploy/scripts/install.sh
deploy/scripts/health-check.sh
```

What happens:

- `setup.sh` asks for anything you did not pass (run it with no flags to be
  prompted for everything), derives the hostnames from the root domain,
  generates every secret, prints the admin password once, and writes a
  fully commented `deploy/config/deploy.yml`. Nothing is installed yet;
  edit the file if you want to change a port or a name.
- `install.sh` pulls the images, obtains certificates from Let's Encrypt,
  starts the databases and the three Ethora services, creates the base app
  and the admin account, and runs the health check. Allow 10 to 15 minutes.

Then open `https://app.<your root domain>`, sign in with the admin e-mail
and the printed password, and follow the setup checklist in the admin
panel. The API is at `https://api.<root>` (Swagger at `/api-docs/`).

## Update

```bash
cd ~/ethora-install-shared
sudo deploy/scripts/update.sh --ref 2610
```

Same `--ref` as you run: the latest images of that line. The next line
(`--ref 2611`): an upgrade; read
[docs/RELEASE_NOTES_OPERATORS.md](docs/RELEASE_NOTES_OPERATORS.md) first.
Image versions are `<line>.<n>` (for example `2610.4`); `deploy.yml` pins
the line by default and can pin an exact build.

## Roll back

```bash
sudo deploy/scripts/update.sh --rollback <commit>
```

using the commit printed at the start of the update log. Or set the
previous image build in `deploy.yml` and run `update.sh` on the same ref.

## Directories

| Directory | Purpose |
|---|---|
| `~/ethora-install-shared` | this checkout: scripts and the only `deploy.yml` |
| `~/ethora` | the live install, rebuilt by every deploy |
| `~/ethora-data` | your data (MongoDB, MinIO, MySQL, Redis). Back this up. |

## Documentation

- [docs/OPERATOR_QUICKSTART.md](docs/OPERATOR_QUICKSTART.md): install, update, rollback, checks, license, backup on one page.
- [deploy/README.md](deploy/README.md): the full reference (layout, every configuration key, every service).
- [docs/LICENSING.md](docs/LICENSING.md): how license keys work, the grace window, air-gapped installs.
- [docs/CONTAINER_IMAGES.md](docs/CONTAINER_IMAGES.md): the images, versions, what each replaces.
- [docs/runbooks/](docs/runbooks/): backup and restore, troubleshooting, migrations.
- [docs/legal/](docs/legal/): license agreement, support policy, privacy and telemetry notice.

## Support

Run `deploy/scripts/health-check.sh` first; it names the failing component.
Send its output and the install or update log with your report to
[support@ethora.com](mailto:support@ethora.com). Never send `deploy.yml` or
`.deploy.env`: they hold every secret of the install.
