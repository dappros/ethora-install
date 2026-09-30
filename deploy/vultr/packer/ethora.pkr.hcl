# Ethora Core image for the Vultr Marketplace.
#
#   export VULTR_API_KEY=...
#   packer init  deploy/vultr/packer
#   packer build -var install_ref=main deploy/vultr/packer
#
# Same content as the AWS AMI and the DigitalOcean snapshot: Ubuntu 24.04
# with every update, Docker, Node 24, yq, the public installer at a release
# ref under /root/ethora-install-shared, every image pre-pulled, the
# first-boot setup page on port 8888. Vultr specifics, from
# github.com/vultr/vultr-marketplace (helper script MIT, in files/): their
# cloud-init build, a per-instance script that generates the setup page
# password at first boot (Vultr metadata has no instance id the page could
# use), and clean_system at the end. The result is a snapshot in the vendor
# account; assign it to the Marketplace app in the vendor portal.

packer {
  required_plugins {
    vultr = {
      source  = "github.com/vultr/vultr"
      version = ">= 2.5.0"
    }
  }
}

variable "vultr_api_key" {
  type      = string
  default   = env("VULTR_API_KEY")
  sensitive = true
}
variable "os_id" {
  type        = number
  default     = 2284
  description = "Vultr OS id of Ubuntu 24.04 LTS x64 (check: curl https://api.vultr.com/v2/os)."
}
variable "plan_id" {
  type    = string
  default = "vc2-2c-4gb"
}
variable "region_id" {
  type    = string
  default = "ewr"
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

source "vultr" "ethora" {
  api_key              = var.vultr_api_key
  os_id                = var.os_id
  plan_id              = var.plan_id
  region_id            = var.region_id
  snapshot_description = "ethora-core-${var.install_ref}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  ssh_username         = "root"
  state_timeout        = "40m"
}

build {
  sources = ["source.vultr.ethora"]

  provisioner "file" {
    source      = "${path.root}/files/"
    destination = "/root/ethora-build/"
  }

  provisioner "shell" {
    environment_vars = [
      "INSTALL_REF=${var.install_ref}",
      "INSTALL_REPO=${var.install_repo}",
      "IMAGES=${join(" ", var.images)}",
    ]
    script       = "${path.root}/ethora.sh"
    remote_folder = "/root"
    remote_file   = "ethora.sh"
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
