# Ethora on Azure: Marketplace image

`packer/ethora.pkr.hcl` builds the image for an Azure Marketplace "Azure
Virtual Machine" offer. Same content as the AWS AMI (Docker, the compose
bundle pre-pulled, the first-boot setup page in compose mode; shared steps
in `deploy/cloud/provision.sh`); Azure needs the image as a version of an
Azure Compute Gallery image definition, generalized with the Azure Linux
agent. What runs on the VM is the compose bundle: settings in
`/home/ubuntu/ethora-install-shared/deploy/compose/.env`, data in Docker
volumes, update with `git pull && docker compose pull && docker compose up
-d` in that directory.

## One-time setup (subscription owner)

```bash
SUB=<subscription id>
az ad sp create-for-rbac --name ethora-image-builder --role Contributor --scopes "/subscriptions/$SUB"
az group create --name ethora-images --location eastus
az sig create --resource-group ethora-images --gallery-name ethora
az sig image-definition create -g ethora-images -r ethora -i ethora-core \
  --publisher Dappros --offer ethora-core --sku 2610 --os-type Linux --os-state Generalized --hyper-v-generation V2
az provider register -n Microsoft.Network --wait; az provider register -n Microsoft.KeyVault --wait
```

The service principal's `appId`, `password` and `tenant` become
`ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`; the subscription
`ARM_SUBSCRIPTION_ID`. New subscriptions have zero quota for most VM
families and capacity restrictions vary by region: `az vm list-usage -l
eastus` shows the families with quota, `az vm list-skus -l eastus` the
restrictions; pass a size that has both with `-var vm_size=...`.

## Build

```bash
set -a; . ~/k/azure-sp.env; set +a
packer init  deploy/azure/packer
packer build -var install_ref=main -var image_version=2610.5.1 -var vm_size=Standard_D2ads_v7 deploy/azure/packer
```

Or with `docker run ... hashicorp/packer:light` as for the other clouds.
`image_version` is the gallery version (three integers; use the build
number, `2610.5.1`, then `.2` for a rebake of the same build). The build
takes twenty to thirty minutes and leaves a managed image and the gallery
version in `ethora-images`; the temporary resource group is deleted.

## First boot

The setup page's password is the VM id, which the portal shows under the
VM's Properties (and `az vm show --query vmId`). The page accepts one
install and switches itself off. No firewall inside the image: the offer's
plan lists the open ports (22, 80, 443, 8888) and the buyer's network
security group opens them. Swap comes from the resource disk through
`waagent.conf`, not from the OS disk.

## VM sizes

The gallery image definition declares no NVMe disk controller, so sizes
that are NVMe-only (the v6 and v7 `ads`/`ds` families used for the bake)
cannot boot from it: "cannot boot with OS image or disk". Recommend and
test SCSI-capable sizes (B2s, D2s_v4, D2s_v5, D2as_v5, D4s_v5). The Packer
build VM may be any size with quota; the captured image is the same. To
allow NVMe sizes later, create a new image definition with
`--features DiskControllerTypes=SCSI,NVMe` and bake into it.

Baked 2026-10-09 as 2610.16.0 from ethora-install main (five hosts,
secure-files served by the API; still the host installer). The compose-bundle
image replaces it from the next bake. Verified 2026-10-01 on version 2610.5.4
with a Standard_D2s_v4 VM: setup page with the VM id as password, install in
under four minutes with sslip.io and Let's Encrypt, second submit refused,
health check green, a room created and messages delivered in the web app.

## Submitting

Partner Center > Marketplace offers > New offer > Azure Virtual Machine.
Listing text: [MARKETPLACE_LISTING.md](MARKETPLACE_LISTING.md). Plan >
Technical configuration: Azure Compute Gallery image, pick the gallery
`ethora` in resource group `ethora-images` and the version. Before
submitting, run Microsoft's certification tool on a VM created from the
gallery version (Certification Test Tool, downloaded inside the VM, or the
automated validation that Partner Center runs on submit); the build
already meets its checks (no password auth, no root login, agent present,
cloud-init, no swap on the OS disk, generalized).
