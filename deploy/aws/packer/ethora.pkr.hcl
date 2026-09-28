# Bake the Ethora Core AMI for AWS Marketplace.
#
#   packer init  deploy/aws/packer
#   packer build -var install_ref=main deploy/aws/packer
#
# What the image contains: Ubuntu 24.04 with security updates applied,
# Docker, Node 24 (for the first-boot page), yq, the public installer
# (github.com/dappros/ethora-install at install_ref) under
# /home/ubuntu/ethora-install-shared, every image an install needs
# pre-pulled from Docker Hub (the three Ethora Core images, our MinIO copy,
# MongoDB, MySQL, Redis, Centrifugo), and the first-boot setup page enabled
# (deploy/setup-web). Nothing is configured and nothing private is on the
# image: the buyer answers the setup page, or CloudFormation passes the
# answers through user-data, and no registry is contacted at first boot.
#
# Marketplace rules applied at the end of the build: no SSH keys or host
# keys left behind (AWS injects the buyer's key pair; host keys regenerate
# on first boot), no passwords, password SSH login off, root login off,
# shell history, logs, apt cache and cloud-init state cleared, machine-id
# reset.

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
variable "install_ref" {
  type        = string
  default     = "main"
  description = "branch of dappros/ethora-install to bake: main = current stable line, or a line such as 2610"
}
variable "install_repo" {
  type    = string
  default = "https://github.com/dappros/ethora-install.git"
}
# Everything an Ethora Core install pulls; pre-pulled so first boot works
# with no registry access. The Ethora tags must match the installer's
# deploy.yml defaults for install_ref.
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
# Where the builder instance runs. Empty = the account's default VPC; set
# both to build in a VPC without one (the builder needs a public IP).
variable "vpc_id" {
  type    = string
  default = ""
}
variable "subnet_id" {
  type    = string
  default = ""
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
  ami_name = "${var.ami_name_prefix}-core-${var.install_ref}-${local.ts}"
}

source "amazon-ebs" "ethora" {
  region          = var.region
  instance_type   = var.instance_type
  ami_name        = local.ami_name
  ami_description = "Ethora Core (${var.install_ref}): self-hosted chat server with API, web chat, admin panel and XMPP. Open http://<ip>:8888 after launch (user admin, password = instance id)."
  ssh_username    = "ubuntu"
  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true

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
    ethora_ref    = var.install_ref
    ethora_images = join(",", var.images)
    base_ami_name = "{{ .SourceAMIName }}"
  }
}

build {
  sources = ["source.amazon-ebs.ethora"]

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    environment_vars = [
      "INSTALL_REF=${var.install_ref}",
      "INSTALL_REPO=${var.install_repo}",
      "IMAGES=${join(" ", var.images)}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    inline = [
      "set -euxo pipefail",
      # --- base packages and every pending security update (Marketplace scans the AMI) ---
      "sudo apt-get update -y",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y ca-certificates curl gnupg git jq unzip",
      # --- docker (official repo) ---
      "sudo install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null",
      "sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin",
      "sudo usermod -aG docker ubuntu",
      # --- node 24 (the first-boot page is a Node script) + yq v4 ---
      "curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -",
      "sudo apt-get install -y nodejs",
      "sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture) && sudo chmod +x /usr/local/bin/yq",
      # --- the public installer at the release ref ---
      "git clone --branch \"$INSTALL_REF\" --depth 1 \"$INSTALL_REPO\" /home/ubuntu/ethora-install-shared",
      "sudo chown -R ubuntu:ubuntu /home/ubuntu/ethora-install-shared",
      "git -C /home/ubuntu/ethora-install-shared log -1 --format='%h %s' | tee /home/ubuntu/ethora-install-shared/.ami-source",
      # --- every image an install needs, so first boot touches no registry ---
      "for i in $IMAGES; do sudo docker pull --quiet \"$i\"; done",
      "sudo docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}'",
      # --- first-boot setup page (single use, password = instance id) ---
      "sudo /home/ubuntu/ethora-install-shared/deploy/setup-web/install-setup-web.sh --no-enable",
      "sudo systemctl enable ethora-setup.service",
      # --- swap helps t3.medium installs ---
      "sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab",
    ]
  }

  # Marketplace hardening. Runs last; nothing after this may log in.
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "set -eux",
      # SSH: keys only, no root, and host keys regenerated per instance
      "sudo sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config",
      "sudo sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo passwd -l root",
      # no stored credentials of any kind
      "sudo rm -rf /root/.docker /home/ubuntu/.docker /root/.ssh /home/ubuntu/.ssh/authorized_keys /home/ubuntu/.ssh/known_hosts",
      "sudo rm -rf /root/.gitconfig /home/ubuntu/.gitconfig /root/.npm /home/ubuntu/.npm",
      # caches, logs, identity
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*",
      "sudo cloud-init clean --logs --seed",
      "sudo truncate -s 0 /etc/machine-id && sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo find /var/log -type f -exec truncate -s 0 {} +",
      "sudo rm -f /root/.bash_history /home/ubuntu/.bash_history; history -c || true",
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
