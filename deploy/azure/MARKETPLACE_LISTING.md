# Azure Marketplace listing: Ethora Core (Azure Virtual Machine offer)

Paste-ready values for Partner Center. Assets (logos 48/90/216/350 px,
screenshots 1280 x 720) are produced from the installer repository's
images and the Ethora logo; keep copies with the listing text.

## Offer setup
- Offer ID: `ethora-core`. Offer alias: Ethora Core.
- Test drive: no. Customer leads: none (can be added later).

## Properties
- Categories: Collaboration (primary), Developer Tools.
- Legal: **Custom** terms. Terms URL: https://ethora.com/legal/ethora-core-license/
  Privacy policy URL: https://ethora.com/privacy-policy/ (the company privacy policy; certification rejected the server telemetry notice as the privacy link)

## Offer listing
- Name: Ethora Core: Self-Hosted Chat and Messaging Server
- Search results summary (100 chars): Self-hosted chat and messaging server with SDKs. Free edition, no license key.
- Short description (256 chars): Deploy a self-hosted chat and messaging server in five minutes and keep every message on your own VM. API, web chat and admin panel, XMPP server, SDKs for iOS, Android, React and React Native. Free: no license key, no per-user fees.
- Description (HTML allowed): use the long description of
  `deploy/aws/MARKETPLACE_LISTING_V2.md` with "AWS" replaced by "Azure",
  "EC2 instance" by "virtual machine", "AWS account" by "Azure subscription",
  and the user data sentence replaced by: "For automated deployments the
  same answers can be passed through cloud-init custom data."
- Search keywords (3): self-hosted chat, xmpp server, chat sdk
- Privacy policy link: https://ethora.com/privacy-policy/
- Useful links: Documentation https://github.com/dappros/ethora-install;
  Support https://ethora.com/legal/support-policy/; Website https://ethora.com
- Support contact: support@ethora.com, Dappros Ltd. Engineering contact: the same.
- CSP program contact: the same (required field).
- Logos: ethora-48.png, ethora-90.png, ethora-216.png, ethora-350.png.
- Screenshots: ethora-admin-apps-1280x720.png (Admin panel, Apps),
  ethora-admin-license-1280x720.png (License page with free registration).

## Preview audience
- Your Azure subscription ID(s), so the offer can be deployed before it is public.

## Plan overview: one plan
- Plan ID: `core-2610`. Plan name: Ethora Core.
- Plan listing summary: Ethora Core on Ubuntu 24.04 LTS, first-boot setup page.
- Plan description: Complete Ethora Core server (API, web chat and admin panel,
  XMPP, MongoDB, MySQL, Redis, MinIO, Centrifugo) with TLS from Let's Encrypt.
  Open http://<public ip>:8888 after deployment (user admin, password = the
  VM id from the VM's Properties), enter the domain and e-mail; five minutes
  later sign in at https://app.<your domain>. Free edition, no license key.
- Pricing and availability: **Free** (customers pay Azure infrastructure only).
  Markets: all. Visibility: public (private only for the preview stage).
- Technical configuration: Azure Compute Gallery image; gallery `ethora`,
  resource group `ethora-images`, definition `ethora-core`, version 2610.16.2 (the compose bundle, chat attachments host on every install; replaces 2610.5.5 and 2610.16.0).
  Operating system: Linux, Ubuntu 24.04. Recommended VM sizes: Standard_B2s,
  Standard_D2s_v4, Standard_D2s_v5, Standard_D2as_v5, Standard_D4s_v5 (no
  NVMe-only sizes: the image definition is SCSI). Open ports: 22 (SSH),
  80 (HTTP), 443 (HTTPS), 8888 (setup page). Properties: supports SSH: yes;
  supports Accelerated Networking: yes; Generation 2.
- Usage instructions (plan technical configuration or listing): the four
  steps from `deploy/aws/MARKETPLACE_LISTING_V2.md`, with "instance id" read
  as "VM id (VM > Properties)", and DNS or `<ip-with-dashes>.sslip.io`.

## Resell through CSP
- Not now.

## Review and publish
- Automated validation, then certification (2 to 5 working days), then
  preview: deploy from the preview link with the preview subscription and
  run the same checks as on AWS (setup page, install, second submit
  refused). Then "Go live".
