# Ethora on AWS: AMI build and single-instance launch

Two pieces:

- `packer/ethora.pkr.hcl` bakes the Marketplace AMI: Ubuntu 24.04 with
  security updates, Docker, Node 24, the public installer
  (`github.com/dappros/ethora-install` at a ref, `main` = current stable
  line), every image of the compose bundle (`deploy/compose`) pre-pulled
  from Docker Hub, and the first-boot setup page (`deploy/setup-web`, compose
  mode) enabled. The steps shared with Azure, DigitalOcean and Vultr are in
  `deploy/cloud/provision.sh`. Nothing is configured in the image and
  nothing private is on it.
- `cloudformation/ethora-instance.yaml` launches one instance from that AMI.
  With `RootDomain` set it installs unattended from user-data
  (`deploy/cloud/install.sh`: `configure.sh`, `docker compose up -d`, the
  bundle's verify); with it empty the buyer finishes on the setup page at
  `http://<ip>:8888` (user `admin`, password = instance id).

What runs on the instance is exactly the compose bundle: Caddy for TLS and
routing, the three Ethora images, MongoDB, MySQL, Redis, MinIO, Centrifugo,
data in Docker volumes. Settings live in
`/home/ubuntu/ethora-install-shared/deploy/compose/.env`; update with
`git pull && docker compose pull && docker compose up -d` in that directory;
backup and restore as in `deploy/compose/README.md`.

## Build the AMI

```bash
packer init  deploy/aws/packer
packer build -var region=us-east-2 -var install_ref=main deploy/aws/packer
```

No credentials of ours are involved: the installer repository and the
images are public. `-var install_ref=2610` bakes a specific line; the images
pre-pulled are whatever that line's compose file names (`docker compose
config --images`), so the list never drifts. `packer-manifest.json` records
the AMI id.

Run Packer from an EC2 host in the target region (a small Ubuntu instance
with Packer installed and the same IAM credentials, deleted or wiped after
the bake). The bake keeps an SSH session open to the builder for about
fifteen minutes while it pulls images; from an office or home network that
session drops with "Script disconnected unexpectedly" and the build fails,
while from inside the region it completes every time. Copy `packer/` and the
credentials over, run the two commands above, then remove `~/.aws` from the
host. `-var vpc_id=... -var subnet_id=...` pick the network for the builder
when the account has no default VPC.

### Marketplace hardening (applied by the last build step)

Password SSH login off, root login off, root account locked, SSH host keys
removed (regenerated on first boot), no authorized keys (AWS injects the
buyer's key pair), no Docker, git or npm credentials, apt cache, logs, shell
history and cloud-init state cleared, machine-id reset. Every package is at
its latest security update at bake time; rebake for a new listing version.

### AWS permissions

The credentials that run the bake and the stack need EC2 rights (run and
terminate the builder, create the image and snapshot, security groups, key
pairs) and CloudFormation rights for the launch. `iam/ami-builder-policy.json`
is a scoped policy for a dedicated `ethora-ami-builder` user or role; attach
it rather than using an admin or a backup-scoped user.

## Launch

Console: CloudFormation → create stack → upload `ethora-instance.yaml`, fill
the parameters. CLI:

```bash
aws cloudformation create-stack --stack-name ethora \
  --template-body file://deploy/aws/cloudformation/ethora-instance.yaml \
  --parameters ParameterKey=AmiId,ParameterValue=ami-xxxx \
               ParameterKey=KeyName,ParameterValue=my-key \
               ParameterKey=VpcId,ParameterValue=vpc-xxxx ParameterKey=SubnetId,ParameterValue=subnet-xxxx \
               ParameterKey=AdminCidr,ParameterValue=203.0.113.4/32 \
               ParameterKey=RootDomain,ParameterValue=chat.example.com \
               ParameterKey=AdminEmail,ParameterValue=ops@example.com
```

Point `api.`, `app.`, `xmpp.`, `files.` and `secure-files.<RootDomain>` at
the instance's public IP before Let's Encrypt runs (one wildcard record
covers them), or use `<ip-with-dashes>.sslip.io` as the root for a test.

Because the address of a plain instance is only known after launch, the
unattended path works best with an Elastic IP you allocate first: pass its
allocation id as `ElasticIpAllocationId`, create the DNS records for that
address (or use `<ip-with-dashes>.sslip.io` as `RootDomain` for a test
install, which needs no DNS at all), and the stack attaches the address at
first boot before anything asks for a certificate. Without the parameter,
leave `RootDomain` empty, read `PublicIp` from the stack outputs, create the
records, then finish on the setup page.

The install itself takes about five minutes on the AMI (every image is
pre-pulled; Let's Encrypt is the slow part). The setup page accepts one
install: a second submit while it runs, or after it has finished, is
refused with HTTP 409, and the page switches itself off fifteen minutes
after a successful install and does not start again on later boots.
Further changes go through `deploy/compose/.env` and `docker compose up -d
--force-recreate` over SSH. The host-installer image (nginx, certbot,
`deploy.yml`) was exercised end to end on 2026-09-28; the compose-bundle
image replaced it on 2026-10-09.

## AWS Marketplace AMI checklist (what the Packer build already does)

- No default passwords: the ubuntu user has none; the setup page password is
  the instance id.
- No SSH keys baked in; `PasswordAuthentication no`; AWS injects the buyer's
  key pair.
- No credentials left: deploy key and `~/.docker/config.json` removed, docker
  logged out.
- cloud-init cleaned, machine-id reset, logs and history truncated.
- Runs on a supported base (Ubuntu 24.04 LTS) with ENA.

Still on you before listing: run the AWS Marketplace AMI scanner on the
built image (no critical CVEs), write the product load form, and decide the
pricing model (BYOL first, then contract dimensions). See
`docs/CONTAINER_IMAGES.md` and `docs/LICENSING.md` for what the image runs and
how the license key is enforced.

When rebaking for a new listing version: the setup page and the bundle in
the image are whatever the public installer's `main` held at bake time;
`git pull` in the checkout brings them forward on a running instance, but
the first-boot page only ever runs the baked copy.
