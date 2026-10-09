# Ethora on Akamai (Linode): StackScript

`ethora-core.stackscript.sh` installs Ethora Core at first boot of an Ubuntu
24.04 Linode (4 GB plan or larger) from the public installer: Docker, then
the compose bundle through `deploy/cloud/install.sh`, the way the AWS
CloudFormation template's unattended path does. It is what the Akamai
Marketplace listing runs, and anyone can use it directly: Linode Cloud
Manager > StackScripts > Create, paste the file, deploy a Linode from it
and fill in the four fields (root domain, admin e-mail, optional password
and license key). Leaving the domain empty installs on
`<ip-with-dashes>.sslip.io`, which needs no DNS.

The install takes about ten minutes (image downloads included); progress
is in `/var/log/ethora-stackscript.log`, the admin password in
`/root/ethora-admin-password.txt`, and the login banner shows the URL when
done. Afterwards: settings in `/root/ethora-install-shared/deploy/compose/.env`,
update with `git pull && docker compose pull && docker compose up -d` in that
directory, data in the Docker volumes `ethora_*`.

## Marketplace submission

Akamai's app partner programme: https://www.linode.com/marketplace/app-partners/.
Their team builds the listing from the deployment (StackScript or their
Ansible layout), the description and the documentation link. Description
and software list: reuse `deploy/vultr/MARKETPLACE_LISTING.md`; the
instructions are the four fields above and the login banner.

## Testing the script elsewhere

It only needs the UDF values as environment variables:

```bash
sudo ROOT_DOMAIN= ADMIN_EMAIL=you@example.com bash ethora-core.stackscript.sh
```
