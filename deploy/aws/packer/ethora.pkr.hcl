# Bake the Ethora AMI for AWS Marketplace.
#
#   packer init  deploy/aws/packer
#   packer build -var monoserver_ref=2610 \
#                -var git_ssh_key=~/.ssh/ethora-mirror-readonly \
#                deploy/aws/packer                       # images built on the builder
#   ... add -var ghcr_user=<user> -var ghcr_token=<read:packages token> to pull instead
#
# What the image contains: Ubuntu 24.04, Docker, Node 24, yq, the
# ethora-install-shared mirror at <monoserver_ref> under
# /home/ubuntu/ethora-install-shared, the ethora-api and ethora-frontend
# images pre-pulled, and the first-boot setup page enabled
# (deploy/setup-web). Nothing is configured: the buyer answers six questions
# on first boot, or passes them through CloudFormation user-data.
#
# Marketplace rules applied at the end of the build: no SSH keys left behind
# (AWS injects the buyer's key pair), no default passwords, password SSH
# login off, shell history and cloud-init state cleared, machine-id reset.

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}
variable "instance_type" {
  type    = string
  default = "t3.medium"
}
variable "monoserver_ref" {
  type    = string
  default = "2610"
}
variable "mirror_repo" {
  type    = string
  default = "git@github.com:dappros/ethora-install-shared.git"
}
variable "git_ssh_key" {
  type        = string
  description = "path to a read-only deploy key for mirror_repo"
}
# Image source. With a GHCR token the published images are pulled; without
# one (default) both images are built from the mirror's own source on the
# builder instance and tagged with the canonical names, so the AMI needs no
# registry access at bake time and none at first boot.
variable "ghcr_user" {
  type    = string
  default = ""
}
variable "ghcr_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "GitHub token with read:packages; empty = build images from source"
}
variable "api_image" {
  type    = string
  default = "ghcr.io/dappros/ethora-api:2610"
}
variable "frontend_image" {
  type    = string
  default = "ghcr.io/dappros/ethora-frontend:2610"
}
variable "ami_name_prefix" {
  type    = string
  default = "ethora"
}
variable "volume_size_gb" {
  type    = number
  default = 40
}

locals {
  ts       = formatdate("YYYYMMDD-hhmm", timestamp())
  ami_name = "${var.ami_name_prefix}-${var.monoserver_ref}-${local.ts}"
}

source "amazon-ebs" "ethora" {
  region          = var.region
  instance_type   = var.instance_type
  ami_name        = local.ami_name
  ami_description = "Ethora ${var.monoserver_ref}: chat, AI agents and admin panel. Open http://<ip>:8888 after launch (user admin, password = instance id)."
  ssh_username    = "ubuntu"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Marketplace requires ENA + no product-specific credentials; both hold for Noble.
  ena_support = true
  tags = {
    Name          = local.ami_name
    ethora_ref    = var.monoserver_ref
    ethora_api    = var.api_image
    ethora_web    = var.frontend_image
    base_ami_name = "{{ .SourceAMIName }}"
  }
}

build {
  sources = ["source.amazon-ebs.ethora"]

  # Temporary deploy key for the private mirror; removed before the image is sealed.
  provisioner "file" {
    source      = var.git_ssh_key
    destination = "/tmp/ethora-deploy-key"
  }

  provisioner "shell" {
    environment_vars = [
      "MONOSERVER_REF=${var.monoserver_ref}",
      "MIRROR_REPO=${var.mirror_repo}",
      "GHCR_USER=${var.ghcr_user}",
      "GHCR_TOKEN=${var.ghcr_token}",
      "API_IMAGE=${var.api_image}",
      "FRONTEND_IMAGE=${var.frontend_image}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    inline = [
      "set -euxo pipefail",
      # --- base packages ---
      "sudo apt-get update -y",
      "sudo apt-get install -y ca-certificates curl gnupg git jq unzip",
      # --- docker (official repo) ---
      "sudo install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null",
      "sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",
      "sudo usermod -aG docker ubuntu",
      # --- node 24 (same major install.sh pins) + yq ---
      "curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -",
      "sudo apt-get install -y nodejs",
      "sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture) && sudo chmod +x /usr/local/bin/yq",
      # --- the install mirror at the release ref ---
      "chmod 600 /tmp/ethora-deploy-key",
      "mkdir -p /home/ubuntu/.ssh && ssh-keyscan github.com >> /home/ubuntu/.ssh/known_hosts 2>/dev/null",
      "GIT_SSH_COMMAND='ssh -i /tmp/ethora-deploy-key -o IdentitiesOnly=yes' git clone --branch \"$MONOSERVER_REF\" --depth 1 \"$MIRROR_REPO\" /home/ubuntu/ethora-install-shared",
      "sudo chown -R ubuntu:ubuntu /home/ubuntu/ethora-install-shared",
      "git -C /home/ubuntu/ethora-install-shared log -1 --format='%h %s' | tee /home/ubuntu/ethora-install-shared/.ami-source",
      # --- the two images: pulled from GHCR when a token is given, else built
      #     from the mirror source right here (amd64 native) and tagged with the
      #     canonical names so deploy.yml's defaults resolve without a pull ---
      "if [ -n \"$GHCR_TOKEN\" ]; then echo \"$GHCR_TOKEN\" | sudo docker login ghcr.io -u \"$GHCR_USER\" --password-stdin && sudo docker pull \"$API_IMAGE\" && sudo docker pull \"$FRONTEND_IMAGE\" && sudo docker logout ghcr.io; else M=/home/ubuntu/ethora-install-shared; S=$(git -C $M rev-parse --short HEAD); sudo docker build --build-arg BYTECODE=1 --build-arg ETHORA_BUILD_VERSION=$(date -u +%y.%m.%d)-$S --build-arg ETHORA_BUILD_COMMIT=$S --build-arg ETHORA_BUILD_TIME=$(date -u +%FT%TZ) --build-arg ETHORA_BUILD_BRANCH=$MONOSERVER_REF -t \"$API_IMAGE\" $M/ethora-backend/services/api && sudo docker build --build-arg VITE_BUILD_VERSION=$(date -u +%y.%m.%d)-$S --build-arg VITE_BUILD_COMMIT=$S --build-arg VITE_BUILD_BRANCH=$MONOSERVER_REF -t \"$FRONTEND_IMAGE\" $M/ethora-app-reactjs; fi",
      "sudo docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}'",
      # build cache is not part of the product
      "sudo docker builder prune -af >/dev/null 2>&1 || true",
      # --- first-boot setup page (single use, password = instance id) ---
      "sudo /home/ubuntu/ethora-install-shared/deploy/setup-web/install-setup-web.sh --no-enable",
      "sudo systemctl enable ethora-setup.service",
      # --- swap helps t3.medium installs ---
      "sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab",
    ]
  }

  # Marketplace hardening. Runs last; nothing after this may log in.
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo rm -f /tmp/ethora-deploy-key",
      "sudo sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config",
      "sudo sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config",
      "sudo rm -rf /root/.docker /home/ubuntu/.docker",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*",
      "sudo cloud-init clean --logs --seed",
      "sudo truncate -s 0 /etc/machine-id && sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo find /var/log -type f -exec truncate -s 0 {} +",
      "history -c; sudo rm -f /root/.bash_history /home/ubuntu/.bash_history",
      # AWS injects the buyer's key pair at launch; the build key must not persist.
      "sudo rm -f /root/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys",
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
