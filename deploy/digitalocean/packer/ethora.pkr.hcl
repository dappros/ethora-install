# Ethora Core 1-Click image for the DigitalOcean Marketplace.
#
#   export DIGITALOCEAN_TOKEN=...      # read/write personal access token
#   packer init  deploy/digitalocean/packer
#   packer build -var install_ref=main deploy/digitalocean/packer
#
# Same content as the AWS AMI (deploy/aws/packer): Ubuntu 24.04 with every
# update, Docker, Node 24, the public installer at a release ref under
# /root/ethora-install-shared, every image of the compose bundle pre-pulled,
# the first-boot setup page on port 8888 in compose mode. The shared steps
# are deploy/cloud/provision.sh. DigitalOcean specifics: root is the login
# user (their convention), ufw is enabled, a message of the day points at
# the setup page, and the build ends with DigitalOcean's own cleanup and
# image-check scripts (scripts/, Apache 2.0, from
# github.com/digitalocean/marketplace-partners). The result is a snapshot in
# the account that ran the build; submit its name in the vendor portal.

packer {
  required_plugins {
    digitalocean = {
      source  = "github.com/digitalocean/digitalocean"
      version = ">= 1.4.0"
    }
  }
}

variable "do_token" {
  type      = string
  default   = env("DIGITALOCEAN_TOKEN")
  sensitive = true
}
variable "region" {
  type    = string
  default = "nyc3"
}
variable "size" {
  type    = string
  default = "s-2vcpu-4gb"
}
variable "base_image" {
  type    = string
  default = "ubuntu-24-04-x64"
}
variable "install_ref" {
  type        = string
  default     = "main"
  description = "Branch or tag of the public installer to bake (main = current stable line)."
}
variable "install_repo" {
  type    = string
  default = "https://github.com/dappros/ethora-install.git"
}

locals {
  stamp = formatdate("YYYYMMDD-hhmm", timestamp())
}

source "digitalocean" "ethora" {
  api_token     = var.do_token
  image         = var.base_image
  region        = var.region
  size          = var.size
  ssh_username  = "root"
  droplet_name  = "ethora-core-build-${local.stamp}"
  snapshot_name = "ethora-core-${var.install_ref}-${local.stamp}"
  tags          = ["ethora-build"]
}

build {
  sources = ["source.digitalocean.ethora"]

  # The shared steps (deploy/cloud/provision.sh); root is the login user here.
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    environment_vars = ["ETHORA_STEP=base", "INSTALL_REF=${var.install_ref}", "INSTALL_REPO=${var.install_repo}", "ETHORA_USER=root", "ETHORA_HOME=/root", "ETHORA_UFW=yes"]
  }
  # Image pulls run detached and are waited for from a disconnect-tolerant
  # step (several gigabytes of layers; the SSH session may drop meanwhile).
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    environment_vars = ["ETHORA_STEP=pull-start", "ETHORA_USER=root", "ETHORA_HOME=/root", "PULL_RUNNER=nohup"]
  }
  provisioner "shell" {
    script            = "${path.root}/../../cloud/provision.sh"
    environment_vars  = ["ETHORA_STEP=pull-wait"]
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
  }
  # Swap for the 4 GB plan; the firewall is required by the image check.
  provisioner "shell" {
    script           = "${path.root}/../../cloud/provision.sh"
    pause_before     = "10s"
    environment_vars = ["ETHORA_STEP=finish", "ETHORA_USER=root", "ETHORA_HOME=/root", "ETHORA_SWAP=2G", "ETHORA_UFW=yes"]
  }

  # Message of the day pointing at the setup page.
  provisioner "file" {
    source      = "${path.root}/files/etc/"
    destination = "/etc/"
  }
  provisioner "shell" {
    inline = [
      "chmod +x /etc/update-motd.d/99-one-click",
      # the base image ships DigitalOcean's droplet agent; their image check refuses it
      "apt-get purge -y droplet-agent >/dev/null 2>&1 || true",
      "rm -rf /opt/digitalocean",
      "ETHORA_STEP=clean ETHORA_USER=root ETHORA_HOME=/root bash /root/ethora-install-shared/deploy/cloud/provision.sh",
      "cloud-init clean --logs --seed",
      "truncate -s 0 /etc/machine-id && rm -f /var/lib/dbus/machine-id && ln -s /etc/machine-id /var/lib/dbus/machine-id",
    ]
  }

  # DigitalOcean's own cleanup (updates, logs, keys, history, zero-fill) and
  # the image check the Marketplace team runs. A [FAIL] line fails the build.
  provisioner "shell" {
    scripts = ["${path.root}/scripts/90-cleanup.sh"]
  }
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "find /var/log -type f -exec truncate -s 0 {} +",
      "bash /root/ethora-install-shared/deploy/digitalocean/packer/scripts/99-img-check.sh 2>&1 | tee /tmp/img-check.log || true",
      "if grep -q 'FAIL]' /tmp/img-check.log; then echo 'image check failed'; exit 1; fi",
      "rm -f /tmp/img-check.log",
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
