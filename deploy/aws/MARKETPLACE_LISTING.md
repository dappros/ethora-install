# AWS Marketplace listing: Ethora Core (free AMI)

Everything the AWS Marketplace Management Portal asks for when creating a
single-AMI server product, ready to paste. Portal:
https://aws.amazon.com/marketplace/management/ (this is a different site from
Partner Central; the same AWS account works for both).

## Before the form

1. **Seller registration.** In the portal open Settings. A complete public
   profile (legal name, logo, description, support contact) is all a free
   product needs; tax and bank details are only required before the first
   paid listing.
2. **AMI ingestion role.** The portal copies the AMI into its own account
   through a role in ours. Run once with an admin profile:

   ```bash
   cat > /tmp/trust.json <<'JSON'
   {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"assets.marketplace.amazonaws.com"},"Action":"sts:AssumeRole"}]}
   JSON
   aws iam create-role --role-name AWSMarketplaceAmiIngestion --assume-role-policy-document file:///tmp/trust.json
   aws iam attach-role-policy --role-name AWSMarketplaceAmiIngestion --policy-arn arn:aws:iam::aws:policy/AWSMarketplaceAmiIngestion
   ```

   The form wants the role ARN:
   `arn:aws:iam::<account id>:role/AWSMarketplaceAmiIngestion`.
3. **The AMI** must be in us-east-2 (or copied to us-east-1, the portal
   accepts any region), unencrypted, with `ubuntu` as the SSH user and no
   passwords, which the Packer build guarantees. Current id is in
   `deploy/aws/packer/packer-manifest.json` after a bake.

## Product form (Server product, single AMI)

**Product title** (72 chars max)

    Ethora Core: self-hosted chat and messaging server

**Short description**

    Chat, messaging and admin server you run on your own instance: API, web
    chat and admin panel, XMPP server with mobile and web SDKs. Free edition,
    no license key, five-minute first boot.

**Long description**

    Ethora is a chat and messaging platform you run yourself. This AMI
    contains a complete Ethora Core server: the API, the web chat and admin
    panel, an XMPP server (ejabberd with the Ethora modules) and the databases
    they need (MongoDB, MySQL, Redis, MinIO object storage), plus TLS from
    Let's Encrypt.

    First boot takes about five minutes. Open the setup page on port 8888,
    enter your domain and e-mail, and the instance configures itself, obtains
    certificates and creates your admin account. No domain yet? The page
    accepts a magic DNS name (203-0-113-10.sslip.io) for a test install.
    Unattended installs are possible through instance user data; a
    CloudFormation template is provided.

    Ethora Core is free: no license key, no expiry, no call-home. Per-server
    limits of 5 apps and 500 user accounts apply, raised to 10 and 5,000 by
    registering for free from the admin panel. Ethora Enterprise (push
    notifications, AI agents, compliance logging, SSO, multi-tenant hosting,
    unlimited apps and users) runs on the same instance with a license key
    from Dappros.

    Build apps on it with the Ethora SDKs for iOS, Android, React and React
    Native, the REST API (Swagger included) and the MCP server for AI
    assistants. Updates are one command over SSH; your data stays in a
    single directory you can snapshot.

**Highlights** (three, 500 chars each)

    1. Complete server in one instance: API, web chat and admin panel, XMPP,
       databases and object storage, TLS included. Five minutes from launch to
       first login through the built-in setup page.
    2. Free forever: Ethora Core needs no license key and never expires.
       Register from the admin panel to raise the per-server limits; add an
       Enterprise key from Dappros for the paid modules on the same instance.
    3. Build on it: REST API with Swagger, SDKs for iOS, Android, React and
       React Native, MCP server for AI assistants. One-command updates; your
       data lives in one directory you can snapshot.

**Product logo URL**: a public https URL to a square PNG, at least 110 x 110
(the ethora.com favicon or logo).

**Categories** (up to three): Collaboration & Productivity; Application
Development; Content Management.

**Search keywords**: chat, messaging, xmpp, self-hosted, community, ejabberd,
mobile sdk, react, ai agents.

**Resources / links**

    Documentation: https://github.com/dappros/ethora-install
    Product page: https://ethora.com
    SDKs and API: https://ethora.com/docs

**Support description**

    Ethora Core comes with community support through the installer
    repository's issues (https://github.com/dappros/ethora-install) and
    e-mail support at support@ethora.com after the free registration from the
    admin panel. Support policy: https://ethora.com/legal/support-policy.
    Enterprise customers have an SLA under their agreement. Run
    deploy/scripts/health-check.sh on the instance before writing; it names
    the failing component. Never send deploy.yml or .deploy.env, they hold
    your secrets.

**Support URL**: https://ethora.com/legal/support-policy

## Usage instructions (4000 chars max)

    1. Launch the instance with a key pair and a security group that allows
       TCP 80 and 443 from anywhere, TCP 22 and TCP 8888 from your own
       address. Recommended size t3.medium or larger (2 vCPU, 4 GB RAM),
       40 GB gp3 volume.
    2. Create DNS A records for api., app., xmpp. and files.<your domain>
       pointing at the instance's public IP (an Elastic IP is recommended).
       For a test install skip DNS and use <ip-with-dashes>.sslip.io as the
       domain, for example 203-0-113-10.sslip.io.
    3. Open http://<public ip>:8888. User: admin. Password: the instance id
       (i-0123...). Enter the domain, your e-mail and, if you have one, an
       Enterprise license key. Submit once; the page shows the install log,
       then the admin URL and the generated admin password.
    4. About five minutes later, open https://app.<your domain> and sign in
       with your e-mail and that password. The setup page switches itself
       off and does not accept a second submit; later changes are made in
       /home/ubuntu/ethora-install-shared/deploy/config/deploy.yml followed
       by sudo deploy/scripts/update.sh over SSH.
    Unattended: pass the same answers as instance user data (see the
    CloudFormation template in the documentation repository) and the
    instance installs itself without the page.
    Your data is in /home/ubuntu/ethora-data; snapshot the volume or run
    deploy/scripts/backup.sh. Updates: git pull in
    /home/ubuntu/ethora-install-shared, then sudo deploy/scripts/update.sh
    --ref main.

## Legal and pricing

- **EULA**: custom. URL: https://ethora.com/legal/ethora-core-license (the
  Ethora Core Software License; the GitHub copy at
  https://ethora.com/legal/ethora-core-license/
  works until the page is up). The Standard Contract for AWS Marketplace is
  not suitable: it grants broader rights than the Core license.
- **Refund policy** (required text even for free products):

      Ethora Core is free software; there is no software charge to refund.
      AWS infrastructure charges are governed by AWS's own terms.

- **Pricing model**: Free. Hourly and annual $0 (the portal still asks for
  the two numbers). Instance types: allow the t3, m6i, c6i, m7i families
  from t3.medium up; the template's list is a good start.
- **Regions**: all commercial regions, "make available in future regions"
  on. The portal copies the AMI itself.

## AMI section

- AMI id: the current bake (see packer-manifest.json).
- IAM access role ARN: the ingestion role above.
- OS: Ubuntu 24.04 LTS, x86_64. SSH user name: `ubuntu`.
- Scanning ports: 22 (SSH, admin only), 80 (HTTP redirect and ACME), 443
  (HTTPS and WebSocket XMPP), 8888 (first-boot setup page, admin only).
  Nothing else listens on the outside; XMPP goes over WSS on 443.
- Usage instructions per version: "First release of the 2610 line" plus the
  operator notes from docs/RELEASE_NOTES_OPERATORS.md for later versions.

## After submission

- The portal scans the AMI (CVEs, credentials, SSH config) and shows the
  result in the request's status; a failure lists the finding to fix and
  rebake.
- Choose **Limited** visibility first: the product is live only for our
  account, so the subscribe and launch flow can be tested end to end. Then
  request **Public** from the same page.
- Later options, each a separate submission: a CloudFormation delivery
  option (the template goes into an S3 bucket the portal can read), and an
  Ethora Enterprise product with contract pricing.
