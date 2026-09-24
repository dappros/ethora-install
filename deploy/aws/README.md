# Ethora on AWS: AMI build and single-instance launch

Two pieces:

- `packer/ethora.pkr.hcl` bakes the Marketplace AMI: Ubuntu 24.04, Docker,
  Node 24, yq, the `ethora-install-shared` mirror at a release ref, the two
  container images pre-pulled, and the first-boot setup page
  (`deploy/setup-web`) enabled. Nothing is configured in the image.
- `cloudformation/ethora-instance.yaml` launches one instance from that AMI.
  With `RootDomain` set it installs unattended from user-data (the six
  answers become `setup.sh --yes` flags); with it empty the buyer finishes on
  the setup page at `http://<ip>:8888` (user `admin`, password = instance id).

## Build the AMI

```bash
packer init  deploy/aws/packer
packer build \
  -var monoserver_ref=2610 \
  -var git_ssh_key=~/.ssh/ethora-mirror-readonly \
  deploy/aws/packer
```

Without a GHCR token (the default) the builder compiles both images from the
mirror's own source on the instance and tags them with the canonical names,
so neither the bake nor the first boot needs registry access. Add
`-var ghcr_user=<user> -var ghcr_token=<token with read:packages>` to pull
the published images instead. The deploy key (a read-only deploy key on
`ethora-install-shared`) and any token are used only during the build and
are removed before the image is sealed. `packer-manifest.json` records the
AMI id.

No local Packer install is needed:

```bash
docker run --rm -v "$PWD/deploy/aws/packer:/work" -w /work \
  -v ~/.aws:/root/.aws:ro -v ~/.ssh/ethora-mirror-readonly:/keys/mirror:ro \
  -e AWS_PROFILE=<profile> hashicorp/packer:light build -var git_ssh_key=/keys/mirror .
```

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

Point `api.`, `app.`, `xmpp.` and `files.<RootDomain>` at the instance's
public IP (or Elastic IP) before Let's Encrypt runs; with `TlsMode=none` the
stack comes up over HTTP for testing.

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

Not yet exercised: these templates have not been run against an AWS account
from this repo. The first `packer build` and stack launch are the acceptance
test.
