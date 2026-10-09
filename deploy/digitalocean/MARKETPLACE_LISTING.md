# DigitalOcean Marketplace listing: Ethora Core (Droplet 1-Click)

Paste-ready values for the vendor portal form.

**App name**: Ethora Core

**Tagline** (short): Self-hosted chat and messaging server: API, web chat and admin panel, XMPP, SDKs. Free.

**Categories**: Messaging; Developer Tools; Communities.

**Description**

    Ethora is a chat and messaging platform you run yourself. This 1-Click
    installs a complete Ethora Core server: the API, the web chat and admin
    panel, an XMPP server (ejabberd with the Ethora modules) and the databases
    they need (MongoDB, MySQL, Redis, MinIO object storage), with TLS from
    Let's Encrypt.

    After creating the droplet, open http://<droplet ip>:8888 (user admin,
    password = the droplet id), enter your domain and e-mail, and the server
    configures itself in about five minutes. No domain yet? Use
    <ip-with-dashes>.sslip.io for a test install.

    Ethora Core is free: no license key, no expiry, no call-home. Per-server
    limits of 5 apps and 500 user accounts apply, raised to 10 and 5,000 by
    registering for free from the admin panel. Ethora Enterprise (push
    notifications, AI agents, compliance logging, SSO, multi-tenant hosting,
    unlimited apps and users) runs on the same droplet with a license key
    from Dappros.

    Build on it with the open-source Ethora SDKs for iOS, Android, React and
    React Native, the REST API (Swagger included) and the MCP server for AI
    assistants.

**Software included** (name, version, licence)

| Software | Version | Licence |
|---|---|---|
| Ethora Core (API, admin panel, XMPP modules) | 2610.5 | Ethora Core Software License |
| ejabberd | 26.04 | GPL-2.0 |
| MongoDB | 6.0.8 | SSPL-1.0 |
| MySQL | 8.1.0 | GPL-2.0 |
| Redis | 7 | RSALv2 / SSPLv1 |
| MinIO | RELEASE.2025-09-07 | AGPL-3.0 |
| Centrifugo | 6 | Apache-2.0 |
| Docker Engine | 28 | Apache-2.0 |
| Caddy | 2.10 | Apache-2.0 |
| Node.js | 24 | MIT |

Check the exact ejabberd, Docker and Caddy versions against the snapshot
before submitting (`docker image inspect`, `dpkg -l`).

**Getting started** (shown on the listing and after creation)

    1. Create the droplet (4 GB RAM or more). Point DNS A records for api.,
       app., xmpp., files. and secure-files.<your domain> at its IP (or one
       wildcard record), or skip DNS and use
       <ip-with-dashes>.sslip.io as the domain for a test install.
    2. Open http://<droplet ip>:8888. User: admin. Password: the droplet id
       (the number in the control panel URL, also printed at SSH login).
    3. Enter the domain and your e-mail, optionally an Enterprise license
       key, and submit once. The page shows the install log, then the admin
       URL and the generated admin password.
    4. About five minutes later, open https://app.<your domain> and sign in.
       The setup page switches itself off; later changes are made in
       /root/ethora-install-shared/deploy/compose/.env followed by
       docker compose up -d --force-recreate over SSH, updates with
       git pull && docker compose pull && docker compose up -d. Your data
       lives in the Docker volumes ethora_* (backup steps in
       deploy/compose/README.md).

**Support URL**: https://ethora.com/legal/support-policy/
**Documentation URL**: https://github.com/dappros/ethora-install
**Licence URL**: https://ethora.com/legal/ethora-core-license/
**Minimum plan**: Basic, 2 vCPU / 4 GB (`s-2vcpu-4gb`).
**Ports opened by the image (ufw)**: 22, 80, 443, 8888.
**Managed database integration**: none (leave every engine unchecked).
**Snapshot**: the name printed by the Packer build (`ethora-core-main-<stamp>`).
