# Ethora Core 1-Click image for the DigitalOcean Marketplace.
#
#   export DIGITALOCEAN_TOKEN=...      # read/write personal access token
#   packer init  deploy/digitalocean/packer
#   packer build -var install_ref=main deploy/digitalocean/packer
#
# Same content as the AWS AMI (deploy/aws/packer): Ubuntu 24.04 with every
# update, Docker, Node 24, yq, the public installer at a release ref under
# /root/ethora-install-shared, every image an install needs pre-pulled, the
# first-boot setup page on port 8888. DigitalOcean specifics: root is the
# login user (their convention), ufw is enabled, a message of the day points
# at the setup page, and the build ends with DigitalOcean's own cleanup and
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
  description = "Pre-pulled at bake time; must match the deploy.yml defaults of install_ref."
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

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
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
      # --- base packages and every pending update (the image check refuses pending security updates) ---
      "apt-get update -y",
      "apt-get -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade -y",
      "apt-get install -y ca-certificates curl gnupg git jq unzip rsync acl nginx certbot python3-certbot-nginx ufw",
      # --- docker (official repo) ---
      "install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list",
      "apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin",
      # --- node 24 (the first-boot page is a Node script) + yq v4 ---
      "curl -fsSL https://deb.nodesource.com/setup_24.x | bash -",
      "apt-get install -y nodejs",
      "wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture) && chmod +x /usr/local/bin/yq",
      # --- the public installer at the release ref, in root's home (DigitalOcean users log in as root) ---
      "git clone --branch \"$INSTALL_REF\" --depth 1 \"$INSTALL_REPO\" /root/ethora-install-shared",
      "git -C /root/ethora-install-shared log -1 --format='%h %s' | tee /root/ethora-install-shared/.image-source",
    ]
  }

  # Image pulls run detached and are waited for from disconnect-tolerant
  # steps (several gigabytes of layers; the SSH session may drop meanwhile).
  provisioner "shell" {
    inline_shebang   = "/bin/bash -e"
    environment_vars = ["IMAGES=${join(" ", var.images)}"]
    inline = [
      "rm -f /tmp/ethora-pulls.done /tmp/ethora-pulls.log",
      "nohup bash -c 'for i in $IMAGES; do echo \"== $i\"; docker pull \"$i\" || echo \"PULL FAILED: $i\"; done; echo done > /tmp/ethora-pulls.done' > /tmp/ethora-pulls.log 2>&1 &",
      "echo 'pulls started in the background'",
    ]
  }
  provisioner "shell" {
    inline_shebang    = "/bin/bash -e"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    inline            = ["while [ ! -f /tmp/ethora-pulls.done ]; do sleep 15; tail -1 /tmp/ethora-pulls.log 2>/dev/null | cut -c1-100; done"]
  }
  provisioner "shell" {
    inline_shebang   = "/bin/bash -e"
    pause_before     = "10s"
    environment_vars = ["IMAGES=${join(" ", var.images)}"]
    inline = [
      "while [ ! -f /tmp/ethora-pulls.done ]; do sleep 15; done",
      "grep 'PULL FAILED' /tmp/ethora-pulls.log && exit 1 || true",
      "for i in $IMAGES; do docker image inspect \"$i\" >/dev/null || { echo \"missing image: $i\"; exit 1; }; done",
      "docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}'",
      "rm -f /tmp/ethora-pulls.done /tmp/ethora-pulls.log",
      # --- first-boot setup page (single use, password = droplet id) ---
      "/root/ethora-install-shared/deploy/setup-web/install-setup-web.sh --no-enable",
      "systemctl enable ethora-setup.service",
      # --- swap for the 4 GB plan ---
      "fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab",
      # --- firewall (required by the Marketplace image check) ---
      "ufw limit ssh",
      "ufw allow 80/tcp",
      "ufw allow 443/tcp",
      "ufw allow 8888/tcp",
      "ufw --force enable",
    ]
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
      "rm -rf /root/.docker /root/.gitconfig /root/.npm /root/.cache",
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
