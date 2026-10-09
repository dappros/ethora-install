# Bake the Ethora Core AMI for AWS Marketplace.
#
#   packer init  deploy/aws/packer
#   packer build -var install_ref=main deploy/aws/packer
#
# What the image contains: Ubuntu 24.04 with security updates applied,
# Docker (with the compose plugin), Node 24 (for the first-boot page), the
# public installer (github.com/dappros/ethora-install at install_ref) under
# /home/ubuntu/ethora-install-shared, every image the compose bundle
# (deploy/compose) runs pre-pulled from Docker Hub, and the first-boot setup
# page enabled in compose mode (deploy/setup-web). Nothing is configured and
# nothing private is on the image: the buyer answers the setup page, or
# CloudFormation passes the answers through user-data to
# deploy/cloud/install.sh, and no registry is contacted at first boot. The
# steps shared with the other clouds are deploy/cloud/provision.sh.
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
  default = "t3.large" # only for the bake; buyers launch whatever size they like
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
  ssh_keep_alive_interval     = "10s"
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
    base_ami_name = "{{ .SourceAMIName }}"
  }
}

build {
  sources = ["source.amazon-ebs.ethora"]

  # The shared steps (deploy/cloud/provision.sh), one upload per step.
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars = ["ETHORA_STEP=base", "INSTALL_REF=${var.install_ref}", "INSTALL_REPO=${var.install_repo}", "ETHORA_USER=ubuntu", "ETHORA_HOME=/home/ubuntu"]
  }
  # Image pulls run detached and are waited for from a disconnect-tolerant
  # step: several gigabytes of layers took the builder's SSH session down
  # when pulled inside the provisioner itself.
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars = ["ETHORA_STEP=pull-start", "ETHORA_USER=ubuntu", "ETHORA_HOME=/home/ubuntu", "PULL_RUNNER=nohup"]
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
    environment_vars = ["ETHORA_STEP=finish", "ETHORA_USER=ubuntu", "ETHORA_HOME=/home/ubuntu", "ETHORA_SWAP=2G"]
  }
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
    environment_vars = ["ETHORA_STEP=clean", "ETHORA_USER=ubuntu", "ETHORA_HOME=/home/ubuntu"]
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
      "sudo rm -rf /root/.ssh /home/ubuntu/.ssh/authorized_keys /home/ubuntu/.ssh/known_hosts",
      # identity
      "sudo cloud-init clean --logs --seed",
      "sudo truncate -s 0 /etc/machine-id && sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "history -c || true",
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
