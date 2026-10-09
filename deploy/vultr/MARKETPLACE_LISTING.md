# Vultr Marketplace listing: Ethora Core

**App name**: Ethora Core

**Short description**: Self-hosted chat and messaging server: API, web chat and admin panel, XMPP, SDKs. Free, no license key.

**Description**

    Ethora is a chat and messaging platform you run yourself. This app installs
    a complete Ethora Core server: the API, the web chat and admin panel, an
    XMPP server (ejabberd with the Ethora modules) and the databases they need
    (MongoDB, MySQL, Redis, MinIO object storage), with TLS certificates from
    Let's Encrypt.

    After deploying, open http://<instance ip>:8888 (user admin, password shown
    at SSH login), enter your domain and e-mail, and the server configures
    itself in about five minutes. No DNS records yet? Use
    <ip-with-dashes>.sslip.io as the domain.

    Ethora Core is free: no license key, no expiry, no call-home. Per-server
    limits of 5 apps and 500 user accounts apply, raised to 10 and 5,000 by
    registering for free from the admin panel. Ethora Enterprise (push
    notifications, AI agents, compliance logging, SSO, multi-tenant hosting,
    unlimited apps and users) runs on the same instance with a license key
    from Dappros.

    Build on it with the open-source Ethora SDKs for iOS, Android, React and
    React Native, the REST API (Swagger included) and the MCP server for AI
    assistants.

**Instructions** (shown after deployment)

    1. Log in over SSH as root, or read the instance IP from the panel. The
       login banner shows the setup URL http://<ip>:8888, user admin, and the
       password (also in /etc/ethora/setup-web.env).
    2. Point DNS A records for api., app., xmpp., files. and
       secure-files.<your domain> at the instance (or one wildcard record),
       or use <ip-with-dashes>.sslip.io as the domain.
    3. Open the setup page, enter the domain, your e-mail and optionally an
       Enterprise license key, submit once. About five minutes later open
       https://app.<your domain> and sign in with the password the page shows.
    4. Later changes: /root/ethora-install-shared/deploy/compose/.env, then
       docker compose up -d --force-recreate in that directory. Update:
       git pull && docker compose pull && docker compose up -d. Data: the
       Docker volumes ethora_* (backup steps in deploy/compose/README.md).

**Minimum plan**: 2 vCPU, 4 GB RAM (vc2-2c-4gb). **Ports**: 22, 80, 443, 8888.
**Support URL**: https://ethora.com/legal/support-policy/
**Documentation**: https://github.com/dappros/ethora-install
**Licence**: https://ethora.com/legal/ethora-core-license/
**Software included**: Ethora Core 2610.5 (Ethora Core Software License), ejabberd (GPL-2.0), MongoDB 6.0.8 (SSPL-1.0), MySQL 8.1.0 (GPL-2.0), Redis (RSALv2/SSPLv1), MinIO (AGPL-3.0), Centrifugo (Apache-2.0), Docker Engine (Apache-2.0), Caddy (Apache-2.0), Node.js 24 (MIT).
