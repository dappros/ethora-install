# Cloud images: the shared parts

Every cloud image (AWS AMI in `deploy/aws`, Azure in `deploy/azure`,
DigitalOcean in `deploy/digitalocean`, Vultr in `deploy/vultr`) and the Akamai
StackScript (`deploy/linode`) install Ethora Core the same way: the compose
bundle (`deploy/compose`) on Docker, data in Docker volumes, TLS by Caddy.
Two scripts here carry everything they share; the per-cloud Packer templates
only add what differs (login user, swap, firewall, hardening, generalisation).

| Script | When | What |
|---|---|---|
| `provision.sh` | at bake time, once per step (`ETHORA_STEP=base`, `pull-start`, `pull-wait`, `finish`, `clean`) | updates, Docker, Node (for the setup page), the public installer cloned at `INSTALL_REF`, every image of the bundle pre-pulled (`docker compose config --images`, so the list never drifts), the setup page enabled in compose mode, optional swap and ufw, cleanup of credentials and logs |
| `install.sh` | at first boot: from the setup page (`deploy/setup-web`, `SETUP_MODE=compose`), from CloudFormation user data, from the StackScript, or by hand over SSH | `deploy/compose/configure.sh --yes` with the answers, `docker compose up -d`, waits for the first-boot init and for `https://app.<root>/`, runs the bundle's verify, writes `/etc/ethora/setup-done` and a message of the day |

```bash
# by hand on any Ubuntu host with Docker (what the setup page does)
git clone --depth 1 https://github.com/dappros/ethora-install.git ~/ethora-install-shared
sudo ~/ethora-install-shared/deploy/cloud/install.sh --domain chat.example.com --admin-email you@example.com
```

Afterwards the install is a plain compose project in
`~/ethora-install-shared/deploy/compose`: `.env` holds the settings (then
`docker compose up -d --force-recreate`), `git pull && docker compose pull &&
docker compose up -d` updates it, and `deploy/compose/README.md` has the
backup and restore steps.

Tests: `deploy/scripts/tests/cloud-install.test.sh` (dry runs of both
scripts and of the setup page in compose mode).
