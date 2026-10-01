# Ethora Core image for the Azure Marketplace (Azure Virtual Machine offer).
#
#   set -a; . ~/k/azure-sp.env; set +a       # ARM_CLIENT_ID/SECRET/TENANT_ID/SUBSCRIPTION_ID
#   packer init  deploy/azure/packer
#   packer build -var install_ref=main deploy/azure/packer
#
# Same content as the AWS AMI: Ubuntu 24.04 (Canonical's Gen2 Marketplace
# image) with every update, Docker, Node 24, yq, the public installer at a
# release ref under /home/ubuntu/ethora-install-shared, every image an
# install needs pre-pulled, the first-boot setup page on port 8888
# (password = the VM id from the instance metadata service, shown in the
# portal under the VM's properties). Azure specifics: no swap file on the OS
# disk (the certification tool flags it; swap comes from the resource disk
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
variable "images" {
  type = list(string)
  default = [
    "docker.io/dappros/ethora-api:2610",
    "docker.io/dappros/ethora-frontend:2610",
    "docker.io/dappros/ethora-xmpp:2610",
    "docker.io/dappros/minio:RELEASE.2025-09-07T16-13-09Z",
    "mongo:6.0.8",
    "mysql:8.1.0",
    "redis:latest",
    "centrifugo/centrifugo:v6",
  ]
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

  # execute_command: the environment goes in front of sudo, never inside a quoted
  # bash -c string (IMAGES contains spaces; the quotes broke the command and the
  # build hung without output).
  provisioner "shell" {
    inline_shebang  = "/bin/bash -e"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars = [
      "INSTALL_REF=${var.install_ref}",
      "INSTALL_REPO=${var.install_repo}",
      "DEBIAN_FRONTEND=noninteractive",
      "NEEDRESTART_MODE=a",
      "NEEDRESTART_SUSPEND=1",
    ]
    inline = [
      "set -euxo pipefail",
      "cloud-init status --wait >/dev/null || true",
      "systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true",
      "systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true",
      "while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done",
      # --- the buyer's login user (Azure creates the one from the portal; ubuntu keeps the docs' paths) ---
      "id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo ubuntu",
      "passwd -l ubuntu",
      # --- base packages and every pending update ---
      "apt-get update -y",
      "apt-get -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade -y",
      "apt-get install -y ca-certificates curl gnupg git jq unzip rsync acl nginx certbot python3-certbot-nginx ffmpeg",
      # --- docker (official repo) ---
      "install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list",
      "apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin",
      "usermod -aG docker ubuntu",
      # --- node 24 + yq v4 ---
      "curl -fsSL https://deb.nodesource.com/setup_24.x | bash -",
      "apt-get install -y nodejs",
      "wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture) && chmod +x /usr/local/bin/yq",
      # --- the public installer at the release ref ---
      "git clone --branch \"$INSTALL_REF\" --depth 1 \"$INSTALL_REPO\" /home/ubuntu/ethora-install-shared",
      # record the source before handing the tree to ubuntu (git refuses a root user in another user's repository)
      "git -C /home/ubuntu/ethora-install-shared log -1 --format='%h %s' | tee /home/ubuntu/ethora-install-shared/.image-source",
      "chown -R ubuntu:ubuntu /home/ubuntu/ethora-install-shared",
    ]
  }

  provisioner "shell" {
    inline_shebang   = "/bin/bash -e"
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars = ["IMAGES=${join(" ", var.images)}"]
    inline = [
      "rm -f /tmp/ethora-pulls.done /tmp/ethora-pulls.log",
      # A transient systemd unit: a nohup'd child of a sudo session dies with the session on this image.
      "systemd-run --unit=ethora-pulls --collect --property=StandardOutput=file:/tmp/ethora-pulls.log --property=StandardError=file:/tmp/ethora-pulls.log --setenv=IMAGES=\"$IMAGES\" bash -c 'for i in $IMAGES; do echo \"== $i\"; docker pull \"$i\" || echo \"PULL FAILED: $i\"; done; echo done > /tmp/ethora-pulls.done'",
      "echo 'pulls started as unit ethora-pulls'",
    ]
  }
  provisioner "shell" {
    inline_shebang    = "/bin/bash -e"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    inline            = ["for _ in $(seq 1 240); do [ -f /tmp/ethora-pulls.done ] && break; sleep 15; tail -1 /tmp/ethora-pulls.log 2>/dev/null | cut -c1-100; done; [ -f /tmp/ethora-pulls.done ] || { echo 'pulls did not finish in an hour'; systemctl status ethora-pulls --no-pager | tail -5; exit 1; }"]
  }
  provisioner "shell" {
    inline_shebang   = "/bin/bash -e"
    pause_before     = "10s"
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars = ["IMAGES=${join(" ", var.images)}"]
    inline = [
      "while [ ! -f /tmp/ethora-pulls.done ]; do sleep 15; done",
      "grep 'PULL FAILED' /tmp/ethora-pulls.log && exit 1 || true",
      "for i in $IMAGES; do docker image inspect \"$i\" >/dev/null || { echo \"missing image: $i\"; exit 1; }; done",
      "docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}'",
      "rm -f /tmp/ethora-pulls.done /tmp/ethora-pulls.log",
      # --- first-boot setup page (single use, password = Azure VM id) ---
      "/home/ubuntu/ethora-install-shared/deploy/setup-web/install-setup-web.sh --no-enable",
      "systemctl enable ethora-setup.service",
      # --- swap from the resource disk, not the OS disk (Azure guidance) ---
      "sed -i 's/^ResourceDisk.EnableSwap=.*/ResourceDisk.EnableSwap=y/; s/^ResourceDisk.SwapSizeMB=.*/ResourceDisk.SwapSizeMB=2048/' /etc/waagent.conf",
      "grep -E '^ResourceDisk.(EnableSwap|SwapSizeMB)=' /etc/waagent.conf",
    ]
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
      "rm -rf /root/.docker /home/ubuntu/.docker /root/.ssh /home/ubuntu/.ssh /root/.gitconfig /home/ubuntu/.gitconfig /root/.npm /home/ubuntu/.npm",
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*",
      "find /var/log -type f -exec truncate -s 0 {} +",
      "rm -f /root/.bash_history /home/ubuntu/.bash_history",
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
