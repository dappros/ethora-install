# Ethora on Vultr: Marketplace image

`packer/ethora.pkr.hcl` builds the snapshot for a Vultr Marketplace app.
Same content as the AWS AMI and the DigitalOcean snapshot (Docker, the
compose bundle pre-pulled, the first-boot setup page in compose mode; shared
steps in `deploy/cloud/provision.sh`, run from `packer/ethora.sh`); the
Vultr conventions come from [vultr/vultr-marketplace](https://github.com/vultr/vultr-marketplace):
their cloud-init build, a cloud-init per-instance script, their
`clean_system` at the end (`packer/files/vultr-helper.sh`, MIT).

## Build

```bash
export VULTR_API_KEY=...            # API key of the vendor account
packer init  deploy/vultr/packer
packer build -var install_ref=main deploy/vultr/packer
```

Or without a local Packer:

```bash
docker run --rm -v "$PWD/deploy/vultr/packer:/work" -w /work \
  -e VULTR_API_KEY hashicorp/packer:light build -var install_ref=main .
```

The build instance (`vc2-2c-4gb`, `ewr`) is created in the vendor account,
provisioned in about fifteen minutes, snapshotted as
`ethora-core-<ref>-<stamp>` and destroyed. `os_id` defaults to 2284, Ubuntu
24.04 LTS; confirm against `curl -s https://api.vultr.com/v2/os` before the
first bake. Vendor accounts also have the `marketplace-*` plans, usable as
`-var plan_id=marketplace-2c-4gb`.

## First boot

Vultr's metadata has no instance id, so the setup page's password is
generated per instance by the cloud-init per-instance script and written to
`/etc/ethora/setup-web.env`, which the `ethora-setup` unit reads. The
message of the day shows the URL and the password at SSH login; the page
accepts one install and then switches itself off. `ufw` is on with 22, 80,
443 and 8888. Afterwards: settings in
`/root/ethora-install-shared/deploy/compose/.env`, update with `git pull &&
docker compose pull && docker compose up -d` in that directory, data in the
Docker volumes `ethora_*`.

## Submitting

Vendor portal: https://my.vultr.com/marketplace/ (after the vendor
application). Create the app, paste the listing text from
[MARKETPLACE_LISTING.md](MARKETPLACE_LISTING.md), attach the snapshot as
the app image, and set the instructions. Vultr reviews the image on a fresh
instance; the message of the day and the setup page are what they see.
Later versions: rebake, attach the new snapshot, submit for review again.
