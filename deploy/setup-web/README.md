# Ethora first-boot setup (web)

One page, two engines, picked by `SETUP_MODE`:

- `compose` (the cloud images): the two answers of
  `deploy/compose/configure.sh`, plus a licence key and a few advanced
  fields; the page runs `deploy/cloud/install.sh`, which configures and
  starts the compose bundle, waits for it and runs the bundle's verify.
- `host` (default): the six questions of `deploy/scripts/setup.sh`; the page
  calls `setup.sh --yes …`, then `install.sh --yes` (the host installer).

Either way the log is streamed. Zero dependencies (Node ≥ 20 built-ins
only) so it runs on a fresh image.

- Basic auth. Password: `SETUP_PASSWORD`, else the EC2 instance id (IMDSv2),
  else a random one printed to the journal. This is the AWS Marketplace rule
  of no default passwords.
- Single use. On a successful install it writes `/etc/ethora/setup-done`,
  shuts down fifteen minutes later, and the unit's `ConditionPathExists`
  keeps it from starting on later boots. Reconfigure afterwards over SSH:
  `deploy/compose/.env` then `docker compose up -d --force-recreate`
  (compose mode), or `setup.sh --from deploy/config/deploy.yml …` (host mode).
- Prefills from an existing `deploy/compose/.env` or `deploy/config/deploy.yml`
  (a retry after a failed install); host mode also accepts a pasted
  `deploy.yml` to start from (`--from`).
- Never returns the generated file or secrets; the generated admin password
  is shown once on the success page (it is also in the settings file).

Run by hand:

```bash
sudo ETHORA_SOURCE_ROOT=/home/ubuntu/ethora-install-shared SETUP_PASSWORD=change-me \
  node deploy/setup-web/server.js        # http://<host>:8888, user "admin"
```

As a unit (what the cloud images do, compose mode):

```bash
sudo deploy/setup-web/install-setup-web.sh --mode compose
```

Restrict port 8888 to your own IP in the security group; the page is meant to
be opened once and then gone. `SETUP_TLS_CERT`/`SETUP_TLS_KEY` serve https.
