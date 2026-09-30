# AWS Marketplace listing, revision 3 (after the Public review)

Paste into Edit product information. Everything here is true of the product as shipped; no figures we have not measured.

## Product title

Ethora Core: Self-Hosted Chat and Messaging Server with SDKs

## Short description

Deploy a self-hosted chat and messaging server in five minutes and keep every message on your own instance. API, web chat and admin panel, XMPP server, SDKs for iOS, Android, React and React Native. Free: no license key, no per-user fees.

## Long description

## Run your own chat and messaging server on AWS

Ethora Core is a self-hosted chat and messaging platform: you own the data, the infrastructure and the user experience. This AMI deploys the complete stack on a single EC2 instance: the API, the web chat and admin panel, XMPP messaging (ejabberd with the Ethora modules), and the databases it needs (MongoDB, MySQL, Redis, MinIO object storage), with TLS certificates from Let's Encrypt.

### Running in five minutes

First boot takes about five minutes. Open the setup page on port 8888, enter your domain and e-mail, and the instance configures itself, obtains certificates and creates your admin account. No DNS records yet? The page accepts a magic DNS name (for example 203-0-113-10.sslip.io) that resolves to the instance without any DNS setup. Unattended installs work through instance user data, and a CloudFormation template is provided.

### Built for teams adding chat to their own products

- In-app messaging for web and mobile products: one-to-one and group chat, presence, media and file sharing, embedded with the Ethora SDKs for iOS, Android, React and React Native.
- Communities and customer messaging where data residency matters: users, apps and messages stay on your instance, in your AWS account.
- AI assistants that work with your platform: the Ethora MCP server lets tools such as Claude and Cursor create apps, users and rooms through the API. AI agents that take part in conversations are part of Ethora Enterprise.

The REST API ships with Swagger documentation on the instance. Unlike cloud chat APIs billed per monthly active user, Ethora Core has no usage fees.

### Security and data control

All client traffic is encrypted in transit with TLS certificates provisioned automatically. Being self-hosted, message data, user credentials and application data remain inside your AWS account; deploy in your VPC and restrict the security group to what you need (80 and 443 public; 22 and 8888 only from your own address). The deployment secrets live in deploy.yml and .deploy.env on the instance; keep them private.

### Free to use, upgrade in place

Ethora Core is free: no license key, no expiry, no call-home. Per-server limits of 5 apps and 500 user accounts apply, raised to 10 apps and 5,000 users by registering for free from the admin panel. Ethora Enterprise runs on the same instance with a license key from Dappros and adds push notifications, AI agents, compliance logging, single sign-on, multi-tenant hosting, and unlimited apps and users.

### Maintenance and backups

Updates are one command over SSH. All persistent data lives in a single directory you can snapshot. The installer and its documentation are public at github.com/dappros/ethora-install.

### Getting started

Launch the AMI, complete the five-minute setup, and sign in to the admin panel. Questions about Enterprise: sales@ethora.com.

## Highlights

1. Complete chat server with full data ownership: API, web chat and admin panel, XMPP server, databases, object storage and TLS in one deployment on your own instance. Messages never leave your AWS account, and all data sits in one directory you can snapshot for backup or migration.

2. No per-user fees, no license key, no expiry: the free edition has no monthly-active-user billing, no call-home and no time limit. Register from the admin panel to raise the per-server limits from 5 apps and 500 users to 10 apps and 5,000 users, or add an Enterprise key from Dappros to unlock the paid modules on the same instance without redeploying.

3. Developer-ready: REST API with Swagger documentation, SDKs for iOS, Android, React and React Native, and an MCP server that lets AI assistants work with the platform. One-command updates, five-minute first boot, public installer and documentation.

## Support description

Support channels

- Community support through the installer repository's issues: https://github.com/dappros/ethora-install
- E-mail support at support@ethora.com after the free registration from the admin panel.

Before writing, run deploy/scripts/health-check.sh on the instance; it names the failing component, and its output plus the install or update log is what we need. Never send deploy.yml or .deploy.env: they contain your deployment secrets.

Enterprise customers with a Dappros license key are supported under their agreement, which includes an SLA. Support policy: https://ethora.com/legal/support-policy/

Ethora Core is free on AWS Marketplace; there is no software charge. Questions about AWS infrastructure charges go to AWS Support; anything else to support@ethora.com.

## Categories

Collaboration & Productivity; Application Development.

## Search keywords

self-hosted chat server, xmpp messaging platform, in-app chat sdk, data sovereignty messaging, react native chat, ejabberd server, chat api, mobile messaging sdk, mcp server, community platform, group chat, enterprise messaging

## Additional resources

- Installation guide and deployment scripts: https://github.com/dappros/ethora-install
- SDKs and sample apps for iOS, Android, React and React Native: https://github.com/dappros/ethora
- Product overview, architecture and pricing: https://ethora.com

## Promotional media

Upload from the installer repository: img/admin-apps.png (admin panel, Apps page) and img/admin-license.png (License page with the free registration).

## Not adopted from the assistant's suggestions, and why

- "AI SDK Server" in the title, and AI agents in the use cases: agents are Enterprise; Core ships the MCP integration only.
- Keywords "sendbird alternative" (competitor name, not allowed in Marketplace keywords), "open source messaging" (Core is proprietary; the SDKs are open source), "hipaa chat" (no certification to back it).
- Category "Security": for security products.
- Throughput, concurrency, customer counts, certifications, response-time commitments: not measured or not held; do not add numbers to the listing that cannot be shown on request.
- Free Trial: not applicable to a free product. Quick Launch (CloudFormation delivery): yes, as the next version once the template is in S3.
