# Ethora Core image for the Azure Marketplace (Azure Virtual Machine offer).
#
#   set -a; . ~/k/azure-sp.env; set +a       # ARM_CLIENT_ID/SECRET/TENANT_ID/SUBSCRIPTION_ID
#   packer init  deploy/azure/packer
#   packer build -var install_ref=main deploy/azure/packer
#
# Same content as the AWS AMI: Ubuntu 24.04 (Canonical's Gen2 Marketplace
# image) with every update, Docker, Node 24, the public installer at a
# release ref under /home/ubuntu/ethora-install-shared, every image of the
# compose bundle pre-pulled, the first-boot setup page on port 8888 in
# compose mode (password = the VM id from the instance metadata service,
# shown in the portal under the VM's properties). The shared steps are
# deploy/cloud/provision.sh. Azure specifics: no swap file on the OS disk
# (the certification tool flags it; swap comes from the resource disk
# through waagent.conf), the Azure Linux agent stays, and the build ends
# with waagent deprovisioning so the image is generalized. The result is a
# version of the gallery image definition ethora-images/ethora/ethora-core,
# which is what Partner Center's plan technical configuration takes.

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = ">= 2.1.0"
    }
  }
}

variable "client_id" {
  type      = string
  default   = env("ARM_CLIENT_ID")
  sensitive = true
}
variable "client_secret" {
  type      = string
  default   = env("ARM_CLIENT_SECRET")
  sensitive = true
}
variable "tenant_id" {
  type    = string
  default = env("ARM_TENANT_ID")
}
variable "subscription_id" {
  type    = string
  default = env("ARM_SUBSCRIPTION_ID")
}
variable "location" {
  type    = string
  default = "eastus"
}
variable "vm_size" {
  type    = string
  default = "Standard_D2s_v5"  # subscriptions differ in quota and capacity; the first bake used -var vm_size=Standard_D2ads_v7
}
variable "gallery_resource_group" {
  type    = string
  default = "ethora-images"
}
variable "gallery_name" {
  type    = string
  default = "ethora"
}
variable "image_definition" {
  type    = string
  default = "ethora-core"
}
variable "image_version" {
  type        = string
  default     = ""
  description = "Gallery image version (x.y.z). Empty = 2610.<build>.<minute of day> from the timestamp; set it to the build number for a listing (2610.5.0)."
}
variable "install_ref" {
  type    = string
  default = "main"
}
variable "install_repo" {
  type    = string
  default = "https://github.com/dappros/ethora-install.git"
}

locals {
  version = var.image_version != "" ? var.image_version : formatdate("YYYY.MMDD.hhmm", timestamp())
}

source "azure-arm" "ethora" {
  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id

  location = var.location
  vm_size  = var.vm_size

  os_type         = "Linux"
  image_publisher = "Canonical"
  image_offer     = "ubuntu-24_04-lts"
  image_sku       = "server"

  ssh_username                      = "packer"
  temp_resource_group_name          = "ethora-packer-${local.version}"
  managed_image_resource_group_name = var.gallery_resource_group
  managed_image_name                = "ethora-core-${local.version}"

  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.gallery_resource_group
    gallery_name         = var.gallery_name
    image_name           = var.image_definition
    image_version        = local.version
    replication_regions  = [var.location]
    storage_account_type = "Standard_LRS"
  }

  azure_tags = {
    product = "ethora-core"
    ref     = var.install_ref
  }
}

build {
  sources = ["source.azure-arm.ethora"]

  # The shared steps (deploy/cloud/provision.sh). execute_command: the
  # environment goes in front of sudo, never inside a quoted bash -c string.
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars = ["ETHORA_STEP=base", "INSTALL_REF=${var.install_ref}", "INSTALL_REPO=${var.install_repo}", "ETHORA_USER=ubuntu", "ETHORA_HOME=/home/ubuntu"]
  }
  # A nohup'd child of a sudo session dies with the session on this image:
  # the pulls run as a transient systemd unit and are waited for from a
  # disconnect-tolerant step.
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars = ["ETHORA_STEP=pull-start", "ETHORA_USER=ubuntu", "ETHORA_HOME=/home/ubuntu", "PULL_RUNNER=systemd-run"]
  }
  provisioner "shell" {
    script            = "${path.root}/../../cloud/provision.sh"
    execute_command   = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars  = ["ETHORA_STEP=pull-wait"]
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
  }
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    pause_before     = "10s"
    environment_vars = ["ETHORA_STEP=finish", "ETHORA_USER=ubuntu", "ETHORA_HOME=/home/ubuntu"]
  }
  # Swap from the resource disk, not the OS disk (Azure guidance).
  provisioner "shell" {
    inline_shebang  = "/bin/bash -e"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    inline = [
      "passwd -l ubuntu",
      "sed -i 's/^ResourceDisk.EnableSwap=.*/ResourceDisk.EnableSwap=y/; s/^ResourceDisk.SwapSizeMB=.*/ResourceDisk.SwapSizeMB=2048/' /etc/waagent.conf",
      "grep -E '^ResourceDisk.(EnableSwap|SwapSizeMB)=' /etc/waagent.conf",
    ]
  }
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars = ["ETHORA_STEP=clean", "ETHORA_USER=ubuntu", "ETHORA_HOME=/home/ubuntu"]
  }

  # Marketplace hardening, then Azure generalisation. Nothing after this may log in.
  provisioner "shell" {
    inline_shebang  = "/bin/bash -e"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    inline = [
      "set -eux",
      "sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config",
      "sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config",
      "passwd -l root",
      "rm -rf /root/.ssh /home/ubuntu/.ssh",
      # Azure: remove the provisioning user and the agent's instance state; cloud-init resets on next boot.
      "cloud-init clean --logs --seed",
      "waagent -force -deprovision+user",
      "export HISTSIZE=0; sync",
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
