# Ethora first-boot setup (web)

The web skin of `deploy/scripts/setup.sh`. Same six questions, same engine:
the page calls `setup.sh --yes …`, then `install.sh --yes`, and streams the
log. Zero dependencies (Node ≥ 20 built-ins only) so it runs on a fresh AMI.

- Basic auth. Password: `SETUP_PASSWORD`, else the EC2 instance id (IMDSv2),
  else a random one printed to the journal. This is the AWS Marketplace rule
  of no default passwords.
- Single use. On a successful install it writes `/etc/ethora/setup-done`,
  shuts down ten minutes later, and the unit's `ConditionPathExists` keeps
  it from starting on later boots. Reconfigure afterwards with `setup.sh
  --from deploy/config/deploy.yml …` over SSH.
- Prefills from an existing `deploy/config/deploy.yml`; accepts a pasted
  `deploy.yml` to start from (`--from`).
- Never returns the generated file or secrets; the generated admin password
  is shown once on the success page (it is also in `deploy.yml`).

Run by hand:

```bash
sudo ETHORA_SOURCE_ROOT=/home/ubuntu/ethora-install-shared SETUP_PASSWORD=change-me \
  node deploy/setup-web/server.js        # http://<host>:8888, user "admin"
```

As a unit (what the AMI does):

```bash
sudo deploy/setup-web/install-setup-web.sh
```

Restrict port 8888 to your own IP in the security group; the page is meant to
be opened once and then gone. `SETUP_TLS_CERT`/`SETUP_TLS_KEY` serve https.
