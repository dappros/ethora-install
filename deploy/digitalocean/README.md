# Ethora on DigitalOcean: 1-Click image

`packer/ethora.pkr.hcl` builds the Droplet 1-Click snapshot for the
DigitalOcean Marketplace. Same content as the AWS AMI
(`deploy/aws/packer`), arranged the way DigitalOcean's
[marketplace-partners](https://github.com/digitalocean/marketplace-partners)
repository asks for: root is the login user, `ufw` is enabled, a message of
the day shows the setup URL and password, and the build ends with their
cleanup and image-check scripts (`packer/scripts/`, Apache 2.0).

## Build

```bash
export DIGITALOCEAN_TOKEN=...        # read/write personal access token
packer init  deploy/digitalocean/packer
packer build -var install_ref=main deploy/digitalocean/packer
```

Twenty minutes: the base droplet (`s-2vcpu-4gb`, `nyc3`) is created in the
account that owns the token, provisioned, zero-filled by the cleanup
script, snapshotted as `ethora-core-<ref>-<stamp>` and destroyed. The
snapshot name goes into the vendor portal. Run it from anywhere; unlike
the AWS bake, the DigitalOcean SSH session has not dropped from an office
network. Without a local Packer:

```bash
docker run --rm -v "$PWD/deploy/digitalocean/packer:/work" -w /work \
  -e DIGITALOCEAN_TOKEN hashicorp/packer:light build -var install_ref=main .
```

The image check at the end prints `[PASS]`, `[WARN]` and `[FAIL]` lines;
any `[FAIL]` fails the build. Warnings about log files are expected and
accepted by the Marketplace team.

## What a buyer sees

1. Creates the droplet from the Marketplace (4 GB plan minimum).
2. Logs in as root over SSH, or just reads the droplet's IP: the message of
   the day gives `http://<ip>:8888`, user `admin`, password = the droplet id
   (also visible in the control panel URL).
3. Enters domain and e-mail on the page. About five minutes later the
   install is done; the page shows the admin URL and password and switches
   itself off. Second submits are refused.
4. Later changes: `/root/ethora-install-shared/deploy/config/deploy.yml`
   then `deploy/scripts/update.sh`. Data in `/root/ethora-data`.

Paths differ from the AWS image (`/root/...` instead of `/home/ubuntu/...`)
because DigitalOcean 1-Clicks run as root by convention; the installer
derives the live and data directories from the checkout's location, so
nothing else changes.

## Submitting

Vendor portal: https://cloud.digitalocean.com/vendorportal (after the
vendor application is approved). The listing text is in
[MARKETPLACE_LISTING.md](MARKETPLACE_LISTING.md). Updates to an existing
listing can be pushed by API (`PATCH /api/v1/vendor-portal/apps/<id>`)
with the new snapshot name; a new version of the image is a rebake plus
that call.
