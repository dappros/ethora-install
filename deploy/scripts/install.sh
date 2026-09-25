#!/bin/bash

# Ethora Enterprise Deployment Installer
# This script automates the deployment of the Ethora system

set -e  # Exit on error

# Non-interactive apt installs on fresh Ubuntu images can hang on `needrestart`
# (whiptail prompt), leaving dpkg locked indefinitely.
# Default to auto-restart mode and no UI to keep installs deterministic.
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"
export NEEDRESTART_UI="${NEEDRESTART_UI:-none}"
export APT_LISTCHANGES_FRONTEND="${APT_LISTCHANGES_FRONTEND:-none}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Determine source/root directories - can be overridden by config
# Default source: parent of deploy directory (assumes deploy/ is at repo root level)
DEFAULT_SOURCE_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
DEFAULT_ROOT_DIR="$DEFAULT_SOURCE_ROOT"
ROOT_DIR="$DEFAULT_ROOT_DIR"
SOURCE_ROOT="$DEFAULT_SOURCE_ROOT"

# Configuration file
CONFIG_FILE="$DEPLOY_DIR/config/deploy.yml"

# Data-dir vars for docker compose. Every stateful volume in
# docker-compose.enterprise.yml is fail-closed (${MONGO_DATA_DIR:?...}), so
# compose cannot interpolate the file at all - not even for `down` - unless these
# are exported. install.sh runs compose both before setup-env.sh has persisted
# them (teardown/cleanup on a fresh box) and after, so load them at each point.
# shellcheck source=deploy/scripts/load-data-env.sh
source "$SCRIPT_DIR/load-data-env.sh"
load_data_dir_env() {
    ethora_load_data_env "$DEPLOY_DIR" || error "Could not resolve the stateful data directories."
}

# Logging
LOG_FILE="$DEPLOY_DIR/deploy.log"

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

ensure_runtime_tree_owned_by_deploy_user() {
    local deploy_user=""
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        deploy_user="$SUDO_USER"
    else
        return 0
    fi

    local targets=(
        "$ROOT_DIR/ethora-backend/services/api"
        "$ROOT_DIR/ethora-backend/services/ai/ai-service"
        "$ROOT_DIR/ethora-backend/services/ai/docs-parse"
        "$ROOT_DIR/ethora-backend/services/push"
        "$ROOT_DIR/ethora-app-reactjs"
        "$ROOT_DIR/ethora-chat-component"
        "$ROOT_DIR/ethora-sdk-playground"
        "$ROOT_DIR/ethora-ai-chat-widget"
        "$ROOT_DIR/ethora-mcp-server"
    )

    for target in "${targets[@]}"; do
        [ -e "$target" ] || continue
        chown -R "$deploy_user":"$deploy_user" "$target" 2>/dev/null || chown -R "$deploy_user" "$target" 2>/dev/null || true
        chmod -R u+rwX "$target" 2>/dev/null || true
    done
}

# Copy a directory with a progress indicator when possible.
# Prefers rsync (gives a single-line progress indicator via --info=progress2),
# falls back to cp if rsync is not available.
copy_dir_with_progress() {
    local src_dir="$1"
    local dest_dir="$2"
    local label="$3"
    shift 3
    # Any extra args will be passed to rsync (e.g. --exclude patterns)
    local extra_rsync_args=("$@")

    if [ -z "$src_dir" ] || [ -z "$dest_dir" ]; then
        error "copy_dir_with_progress: missing source or destination"
    fi
    if [ ! -d "$src_dir" ]; then
        error "copy_dir_with_progress: source directory not found: $src_dir"
    fi

    # Ensure destination directory exists (we copy contents into it).
    mkdir -p "$dest_dir" || error "Failed to create destination directory: $dest_dir"

    log "Copying ${label:-directory} (this may take a minute)..."

    if command -v rsync &> /dev/null; then
        # Try the nicer progress output first; fall back if rsync is older.
        rsync -a --info=progress2 "${extra_rsync_args[@]}" "$src_dir"/ "$dest_dir"/ \
          || rsync -a --progress "${extra_rsync_args[@]}" "$src_dir"/ "$dest_dir"/ \
          || error "Failed to copy ${label:-directory} with rsync"
    else
        warn "rsync not found; copying without progress indicator (install rsync for progress output)."
        cp -a "$src_dir"/. "$dest_dir"/ 2>/dev/null || cp -r "$src_dir"/. "$dest_dir"/ || error "Failed to copy ${label:-directory}"
    fi
}

is_backend_complete() {
    local dir="$1"
    # We require key subfolders used by docker-compose.enterprise.yml
    [ -d "$dir" ] \
      && [ -d "$dir/backend" ] \
      && [ -f "$dir/backend/package.json" ] \
      && [ -d "$dir/crawler" ]
}

# Source repo check: allow both legacy and new backend layouts.
is_backend_source_complete() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        return 1
    fi
    if [ -d "$dir/services/api" ] && [ -f "$dir/services/api/package.json" ]; then
        return 0
    fi
    if [ -d "$dir/backend" ] && [ -f "$dir/backend/package.json" ]; then
        return 0
    fi
    return 1
}

# An uninitialized submodule leaves an empty directory behind, so `[ -d ... ]`
# is not a usable test for "are this component's sources here?". Every such
# check must look for the package manifest instead - otherwise the emptiness is
# copied forward until npm fails with a bare ENOENT on package.json, several
# steps away from the actual cause.
is_node_project_complete() {
    local dir="$1"
    [ -n "$dir" ] && [ -f "$dir/package.json" ]
}

# Node submodules whose absence is worth reporting. Backend is checked
# separately because it has two possible layouts.
OPTIONAL_NODE_SUBMODULES=(
    "ethora-uptime"
    "ethora-sdk-playground"
    "ethora-chat-component"
    "ethora-ai-chat-widget"
    "ethora-mcp-server"
)

ensure_submodules_present() {
    local repo_root="$1"
    if [ -z "$repo_root" ] || [ ! -d "$repo_root" ]; then
        return 0
    fi
    if [ ! -d "$repo_root/.git" ]; then
        return 0
    fi

    local name
    local missing="false"
    if ! is_backend_source_complete "$repo_root/ethora-backend"; then
        missing="true"
    fi
    for name in "${OPTIONAL_NODE_SUBMODULES[@]}"; do
        if [ -d "$repo_root/$name" ] && ! is_node_project_complete "$repo_root/$name"; then
            missing="true"
        fi
    done

    if [ "$missing" != "true" ]; then
        return 0
    fi

    warn "Detected missing submodule contents. Running: git submodule update --init --recursive"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        sudo -u "$SUDO_USER" -H bash -lc "git -C \"$repo_root\" submodule update --init --recursive" \
          || warn "Submodule init failed (continuing; install may fail if sources are missing)."
    else
        bash -lc "git -C \"$repo_root\" submodule update --init --recursive" \
          || warn "Submodule init failed (continuing; install may fail if sources are missing)."
    fi

    # A partial init is the interesting case: one unreachable submodule (no SSH
    # key, no network) leaves its directory empty while everything else checks
    # out fine, and the install then dies much later inside npm. Name what is
    # still missing while we are still at the step that can explain it.
    local still_missing=()
    for name in "${OPTIONAL_NODE_SUBMODULES[@]}"; do
        if [ -d "$repo_root/$name" ] && ! is_node_project_complete "$repo_root/$name"; then
            still_missing+=("$name")
        fi
    done
    if [ ${#still_missing[@]} -gt 0 ]; then
        warn "Submodules still without sources after init: ${still_missing[*]}"
        warn "Retry with: git -C \"$repo_root\" submodule update --init ${still_missing[*]}"
    fi
}

is_frontend_complete() {
    local dir="$1"
    [ -d "$dir" ] && [ -f "$dir/package.json" ] && [ -f "$dir/vite.config.ts" ]
}

is_ejabberd_complete() {
    local dir="$1"
    [ -d "$dir" ] && [ -f "$dir/docker-compose.yml" ] && [ -d "$dir/docker" ]
}

# Check if running as root or with sudo
check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root or with sudo"
    fi
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # First, ensure yq is available (needed to read config)
    # We require yq v4 (scripts use `yq eval ...`). If a host has yq v3 installed, validation will fail.
    ensure_yq_v4() {
        local have_yq="false"
        if command -v yq &> /dev/null; then
            have_yq="true"
        fi

        local needs_install="false"
        if [ "$have_yq" != "true" ]; then
            needs_install="true"
        else
            # yq v4 prints: "yq (...) version v4.x.x"
            if ! yq --version 2>/dev/null | grep -qE 'version v4\.'; then
                warn "Detected yq, but not v4. Re-installing yq v4 (required for deploy scripts)."
                needs_install="true"
            fi
        fi

        if [ "$needs_install" == "true" ]; then
            warn "Installing yq v4..."
            # Install the correct yq binary for host arch (important for Apple Silicon / ARM64 VMs).
            local arch
            arch="$(uname -m 2>/dev/null || echo "")"
            local yq_arch="amd64"
            if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
                yq_arch="arm64"
            fi
            wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}"
            chmod +x /usr/local/bin/yq
        fi

        if ! command -v yq &> /dev/null; then
            error "Failed to install yq. Please install yq v4 manually (see https://github.com/mikefarah/yq/#install)."
        fi
        if ! yq --version 2>/dev/null | grep -qE 'version v4\.'; then
            error "yq v4 is required. Your current yq is: $(yq --version 2>/dev/null || echo 'unknown')."
        fi
    }

    ensure_yq_v4

    # Validate deploy.yml syntax early to avoid long installs + confusing prompts later.
    # This catches common YAML issues (bad indentation, stray tabs, missing keys).
    if [ ! -f "$CONFIG_FILE" ]; then
        error "Configuration file not found: $CONFIG_FILE. Please copy deploy.yml.template to deploy.yml and configure it."
    fi
    if ! yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1; then
        error "Invalid YAML in $CONFIG_FILE. Fix the file formatting (indentation/keys) and re-run install."
    fi

    # Ensure rsync is available (used for progress indicator when copying repos)
    if ! command -v rsync &> /dev/null; then
        warn "rsync not found. Installing..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y rsync >/dev/null 2>&1 || error "Failed to install rsync via apt-get. Please install rsync manually."
        elif command -v dnf &> /dev/null; then
            dnf install -y rsync >/dev/null 2>&1 || error "Failed to install rsync via dnf. Please install rsync manually."
        elif command -v yum &> /dev/null; then
            yum install -y rsync >/dev/null 2>&1 || error "Failed to install rsync via yum. Please install rsync manually."
        elif command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm rsync >/dev/null 2>&1 || error "Failed to install rsync via pacman. Please install rsync manually."
        else
            error "rsync is required for progress output during copy, but no supported package manager was found. Please install rsync manually and re-run."
        fi

        if command -v rsync &> /dev/null; then
            log "rsync installed successfully"
        fi
    fi

    # Ensure ACL tools are available (used to grant nginx access to /home/<user>/... deploy paths).
    # Without this we fall back to chmod o+rx, which is more permissive and noisier in logs.
    if ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            warn "setfacl/getfacl not found. Installing 'acl' package..."
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y acl >/dev/null 2>&1 || warn "Failed to install 'acl' package; will fall back to chmod during frontend setup."
        fi
    fi

    # Helper: install common packages on Debian/Ubuntu
    apt_install() {
        local pkgs=("$@")
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1
    }

    # Helper: ensure docker-compose command exists.
    # On modern Docker installs, compose is a plugin exposed as `docker compose` (not `docker-compose`).
    # Our deploy scripts use `docker-compose`, so we provide a small wrapper if needed.
    ensure_docker_compose_wrapper() {
        if command -v docker-compose >/dev/null 2>&1; then
            return 0
        fi
        if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
            cat >/usr/local/bin/docker-compose <<'EOF'
#!/bin/sh
exec docker compose "$@"
EOF
            chmod +x /usr/local/bin/docker-compose
        fi
    }

    install_docker_ubuntu() {
        # Install Docker Engine + Compose plugin (recommended upstream repo)
        if ! command -v apt-get >/dev/null 2>&1; then
            return 1
        fi

        apt_install ca-certificates curl gnupg lsb-release >/dev/null 2>&1 || true
        install -m 0755 -d /etc/apt/keyrings
        if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
        fi

        # shellcheck disable=SC1091
        . /etc/os-release
        local codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo noble)}"
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
          >/etc/apt/sources.list.d/docker.list

        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 \
          || error "Failed to install Docker from Docker apt repo"

        systemctl enable --now docker >/dev/null 2>&1 || true

        # Allow the invoking user to run docker without sudo (optional, but nice)
        if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
            usermod -aG docker "$SUDO_USER" >/dev/null 2>&1 || true
        fi

        ensure_docker_compose_wrapper
    }

    install_node_ubuntu() {
        if ! command -v apt-get >/dev/null 2>&1; then
            return 1
        fi
        # Install Node.js via NodeSource
        #
        # NOTE: the platform targets Node 24. Node 18 causes noisy EBADENGINE
        # warnings and can break the frontend dev server; Node 20 still runs the
        # backend but is no longer what the deploy is exercised on.
        # NodeSource setup script may require gnupg and friends on minimal images.
        apt_install curl ca-certificates gnupg >/dev/null 2>&1 || true
        local node_setup="setup_24.x"
        if [ "${INSTALL_NODE_MAJOR:-}" != "" ]; then
            node_setup="setup_${INSTALL_NODE_MAJOR}.x"
        fi
        local node_log="/tmp/ethora-node-install.$$.log"
        : >"$node_log" || true

        # Helper: retry apt operations if dpkg/apt is locked (unattended-upgrades on fresh Ubuntu).
        apt_retry() {
            local cmd="$1"
            local tries="${2:-12}"
            local i=1
            while true; do
                # shellcheck disable=SC2086
                bash -lc "$cmd" >>"$node_log" 2>&1 && return 0
                if grep -qiE "Could not get lock|dpkg.*lock|Unable to acquire the dpkg frontend lock" "$node_log"; then
                    if [ "$i" -ge "$tries" ]; then
                        return 1
                    fi
                    sleep 5
                    i=$((i+1))
                    continue
                fi
                return 1
            done
        }

        # Configure NodeSource repo (keep logs for troubleshooting).
        curl -fsSL "https://deb.nodesource.com/${node_setup}" | bash - >>"$node_log" 2>&1 || {
            echo "[install.sh] NodeSource setup failed; last output:" >&2
            tail -n 120 "$node_log" >&2 || true
            error "Failed to configure NodeSource repo for Node.js (${node_setup})"
        }

        # Some setups don't run apt update in the setup script (or it fails transiently).
        apt_retry "DEBIAN_FRONTEND=noninteractive apt-get update -y" 12 || {
            echo "[install.sh] apt-get update failed; last output:" >&2
            tail -n 120 "$node_log" >&2 || true
            error "Failed to update apt package lists while installing Node.js"
        }

        apt_retry "DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs" 12 || {
            echo "[install.sh] Node.js install failed; last output:" >&2
            tail -n 160 "$node_log" >&2 || true
            error "Failed to install Node.js"
        }
    }

    install_nginx_certbot_ubuntu() {
        if ! command -v apt-get >/dev/null 2>&1; then
            return 1
        fi
        apt_install nginx certbot python3-certbot-nginx >/dev/null 2>&1 || error "Failed to install nginx/certbot"
        # Do NOT start nginx here: certbot standalone needs port 80 free and validate.sh checks it.
        # Nginx will be configured and started later by setup-nginx.sh (and certbot stops/starts it as needed).
        systemctl stop nginx >/dev/null 2>&1 || true
    }

    install_pm2_global() {
        # PM2 is used to run backend/frontend processes; best effort.
        if command -v npm >/dev/null 2>&1; then
            npm install -g pm2 >/dev/null 2>&1 || {
                # Same ENOTEMPTY/rename issue can happen on some systems; attempt cleanup + retry.
                rm -rf /usr/lib/node_modules/pm2 /usr/local/lib/node_modules/pm2 /usr/lib/node_modules/.pm2-* /usr/local/lib/node_modules/.pm2-* 2>/dev/null || true
                npm cache clean --force >/dev/null 2>&1 || true
                npm install -g pm2 --force >/dev/null 2>&1 || true
            }
        fi
    }

    install_ffmpeg_ubuntu() {
        # ffmpeg provides both `ffmpeg` and `ffprobe`. The backend's
        # files/chat-media upload paths shell out to ffmpeg (video preview
        # frame extraction) and ffprobe (audio/video duration). Without
        # these binaries, audio uploads 500 and video previews fail.
        if ! command -v apt-get >/dev/null 2>&1; then
            return 1
        fi
        apt_install ffmpeg >/dev/null 2>&1 || error "Failed to install ffmpeg"
    }
    
    # Check if we're in localhost mode (now that yq is available)
    local is_localhost=false
    if [ -f "$CONFIG_FILE" ]; then
        local api_domain=$(yq eval '.domains.api' "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ "$api_domain" == "localhost" ]; then
            is_localhost=true
            log "Localhost mode detected - skipping SSL and Nginx requirements"
        fi
    fi

    get_node_major() {
        node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo ""
    }

    ensure_min_node_version() {
        local required_major="$1"
        local current_major
        current_major="$(get_node_major)"

        if [ -z "$current_major" ]; then
            return 1
        fi
        if [ "$current_major" -lt "$required_major" ]; then
            warn "Node.js ${current_major} detected, but this deployment requires Node.js >= ${required_major}. Upgrading Node..."
            INSTALL_NODE_MAJOR="$required_major" install_node_ubuntu
        fi
    }

    # If we're going to use certbot standalone, port 80 must be free during issuance.
    # nginx may be running already (fresh installs often auto-start it), so stop it early.
    if [ "$is_localhost" != "true" ]; then
        local ssl_method_cfg
        ssl_method_cfg="$(yq eval '.ssl.method' "$CONFIG_FILE" 2>/dev/null || echo "certbot")"
        if [ "$ssl_method_cfg" == "certbot" ]; then
            systemctl stop nginx 2>/dev/null || true
        fi
    fi
    
    # Auto-install missing prerequisites when possible (Ubuntu/Debian).
    # This keeps install.sh "one-shot" on fresh servers.
    if command -v apt-get >/dev/null 2>&1; then
        if ! command -v docker >/dev/null 2>&1; then
            warn "docker not found. Installing Docker Engine..."
            install_docker_ubuntu
        fi

        ensure_docker_compose_wrapper

        if ! command -v docker-compose >/dev/null 2>&1; then
            warn "docker-compose not found. Installing Docker Compose plugin/wrapper..."
            # If docker is installed but compose plugin is missing, install it
            if ! docker compose version >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
            fi
            ensure_docker_compose_wrapper
        fi

        if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
            warn "node/npm not found. Installing Node.js..."
            install_node_ubuntu
        fi
        # Enforce Node >= 24 always (matches the version the deploy is exercised
        # on; also reduces EBADENGINE spam on localhost).
        ensure_min_node_version 24 || true

        # nginx/certbot only required in production (non-localhost)
        if [ "$is_localhost" != "true" ]; then
            if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                warn "nginx/certbot not found. Installing..."
                install_nginx_certbot_ubuntu
            fi
        fi

        # ffmpeg/ffprobe — required by backend file upload paths for video
        # preview generation and audio/video duration probing. The audio
        # upload route 500s without ffprobe present.
        if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
            warn "ffmpeg/ffprobe not found. Installing..."
            install_ffmpeg_ubuntu
        fi

        install_pm2_global
    fi

    # Check for required commands
    local missing=()
    local required_cmds=("docker" "docker-compose" "node" "npm" "rsync" "ffmpeg" "ffprobe")
    
    # Add nginx and certbot only if not localhost mode
    if [ "$is_localhost" != "true" ]; then
        required_cmds+=("certbot" "nginx")
    fi
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            missing+=($cmd)
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing required commands: ${missing[*]}. Please install them first."
    fi

    # ARM64 note: our Ejabberd service is pinned to linux/amd64 for consistency.
    # On Apple Silicon / ARM hosts, Docker must have binfmt/qemu configured for amd64 emulation.
    local host_arch
    host_arch="$(uname -m 2>/dev/null || echo "")"
    if [ "$host_arch" = "aarch64" ] || [ "$host_arch" = "arm64" ]; then
        if ! docker run --rm --platform linux/amd64 alpine:3.19 uname -m >/dev/null 2>&1; then
            warn "ARM64 host detected, but linux/amd64 emulation is not working."
            warn "Ejabberd (xmpp) uses platform=linux/amd64; enable binfmt/qemu, then re-run install."
            warn "Fix (Linux): sudo docker run --privileged --rm tonistiigi/binfmt --install all"
            warn "Fix (Docker Desktop): enable 'Use Rosetta for x86/amd64 emulation' (Apple Silicon)."
            # In localhost installs we can safely try to enable binfmt automatically.
            # This requires privileged containers, so we only auto-run when explicitly allowed.
            if [ "${AUTO_INSTALL_BINFMT:-}" = "true" ] || [ "$is_localhost" = "true" ]; then
                warn "Attempting to enable binfmt/qemu automatically (AUTO_INSTALL_BINFMT=true or localhost mode)..."
                docker run --privileged --rm tonistiigi/binfmt --install all >/dev/null 2>&1 || true
                if ! docker run --rm --platform linux/amd64 alpine:3.19 uname -m >/dev/null 2>&1; then
                    error "linux/amd64 emulation is still not working on this ARM64 host. Please enable binfmt/qemu (see messages above) and re-run install."
                else
                    log "linux/amd64 emulation enabled successfully"
                fi
            fi
        fi
    fi
    
    log "Prerequisites check passed"
}

# Ensure swap exists on small instances (prevents "stuck" builds due to memory pressure).
# Idempotent: if any swap is already enabled, does nothing.
ensure_swapfile() {
    # Allow opt-out for specialized hosts (e.g., custom swap, immutable images).
    if [ "${ETHORA_ENABLE_SWAP:-true}" != "true" ]; then
        log "Swap auto-setup disabled (ETHORA_ENABLE_SWAP=false)"
        return 0
    fi

    if ! command -v swapon >/dev/null 2>&1 || ! command -v mkswap >/dev/null 2>&1; then
        warn "swapon/mkswap not found; skipping swap auto-setup"
        return 0
    fi

    # If any swap is already active, do nothing.
    if swapon --show 2>/dev/null | awk 'NR>1 {print}' | grep -q .; then
        log "Swap is already enabled; skipping swap auto-setup"
        return 0
    fi

    # Read total memory (MB)
    local mem_kb mem_mb
    mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    mem_mb="$((mem_kb / 1024))"
    if [ "$mem_mb" -le 0 ]; then
        warn "Unable to determine MemTotal; skipping swap auto-setup"
        return 0
    fi

    # Only auto-create swap on small hosts (default threshold: 8 GiB RAM).
    local threshold_mb
    threshold_mb="${ETHORA_SWAP_THRESHOLD_MB:-8192}"
    if [ "$mem_mb" -gt "$threshold_mb" ]; then
        log "Host RAM ${mem_mb}MB > ${threshold_mb}MB; skipping swap auto-setup"
        return 0
    fi

    # Pick swap size (MB): min(4096, max(2048, MemTotalMB))
    local desired_mb
    desired_mb="$mem_mb"
    if [ "$desired_mb" -lt 2048 ]; then desired_mb=2048; fi
    if [ "$desired_mb" -gt 4096 ]; then desired_mb=4096; fi

    # Ensure we have enough free disk on /
    local avail_mb
    avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d '\r' || echo 0)"
    if [ -z "$avail_mb" ]; then avail_mb=0; fi
    # Keep at least 1 GiB headroom after allocating swap.
    if [ "$avail_mb" -lt $((desired_mb + 1024)) ]; then
        warn "Not enough free disk to allocate ${desired_mb}MB swap on /. Available=${avail_mb}MB. Skipping swap auto-setup."
        return 0
    fi

    local swap_path="/swapfile"
    log "Enabling swap (${desired_mb}MB) at ${swap_path} (helps with TS builds on small instances)..."

    if [ ! -f "$swap_path" ]; then
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "${desired_mb}M" "$swap_path" || return 0
        else
            # Fallback: dd (slower)
            dd if=/dev/zero of="$swap_path" bs=1M count="$desired_mb" status=progress 2>/dev/null || return 0
        fi
    fi

    chmod 600 "$swap_path" 2>/dev/null || true
    mkswap "$swap_path" >/dev/null 2>&1 || true
    swapon "$swap_path" >/dev/null 2>&1 || true

    if swapon --show 2>/dev/null | awk 'NR>1 {print}' | grep -q "^${swap_path}"; then
        # Persist across reboot if not already present
        if ! grep -qE "^${swap_path}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab 2>/dev/null; then
            echo "${swap_path} none swap sw 0 0" >> /etc/fstab || true
        fi
        log "Swap enabled successfully"
    else
        warn "Swap setup attempted but swap is still not active (continuing)"
    fi
}

# Parse configuration file
parse_config() {
    log "Parsing configuration file..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        error "Configuration file not found: $CONFIG_FILE. Please copy deploy.yml.template to deploy.yml and configure it."
    fi
    
    # Load path configuration.
    CONFIG_SOURCE_DIR=$(yq eval '.paths.source' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -n "$CONFIG_SOURCE_DIR" ] && [ "$CONFIG_SOURCE_DIR" != "null" ]; then
        case "$CONFIG_SOURCE_DIR" in
            /*) ;;
            *) error "paths.source must be an absolute path: $CONFIG_SOURCE_DIR" ;;
        esac
        if [ ! -d "$CONFIG_SOURCE_DIR" ]; then
            error "Configured source directory does not exist: $CONFIG_SOURCE_DIR"
        fi
        SOURCE_ROOT="$(cd "$CONFIG_SOURCE_DIR" && pwd)"
        if [ "$SOURCE_ROOT" != "$DEFAULT_SOURCE_ROOT" ]; then
            error "This installer was run from $DEFAULT_SOURCE_ROOT, but deploy.yml declares paths.source=$SOURCE_ROOT. Run install.sh from $SOURCE_ROOT/deploy so code and config stay in sync."
        fi
    fi

    # Allow CLI override for the install target (useful for scripted reinstall workflows)
    if [ -n "${CONFIG_BASE_DIR_OVERRIDE:-}" ] && [ "$CONFIG_BASE_DIR_OVERRIDE" != "null" ]; then
        CONFIG_BASE_DIR="$CONFIG_BASE_DIR_OVERRIDE"
    else
        CONFIG_BASE_DIR=$(yq eval '.paths.base' "$CONFIG_FILE" 2>/dev/null || echo "")
    fi
    if [ -n "$CONFIG_BASE_DIR" ] && [ "$CONFIG_BASE_DIR" != "null" ]; then
        if [ -d "$CONFIG_BASE_DIR" ]; then
            ROOT_DIR="$(cd "$CONFIG_BASE_DIR" && pwd)"
            log "Using custom base directory: $ROOT_DIR"
        else
            log "Creating custom base directory: $CONFIG_BASE_DIR"
            mkdir -p "$CONFIG_BASE_DIR" || error "Failed to create base directory: $CONFIG_BASE_DIR"
            ROOT_DIR="$(cd "$CONFIG_BASE_DIR" && pwd)"
        fi
    else
        ROOT_DIR="$SOURCE_ROOT"
    fi
    
    # Calculate all paths relative to base directory
    export ROOT_DIR
    export SOURCE_ROOT
    export BACKEND_DIR="$ROOT_DIR/ethora-backend"
    export FRONTEND_DIR="$ROOT_DIR/ethora-app-reactjs"
    export EJABBERD_DIR="$ROOT_DIR/ejabberd-docker"
    export UPTIME_DIR="$ROOT_DIR/ethora-uptime"
    export PLAYGROUND_DIR="$ROOT_DIR/ethora-sdk-playground"
    export WIDGET_DIR="$ROOT_DIR/ethora-ai-chat-widget"
    export MCP_DIR="$ROOT_DIR/ethora-mcp-server"

    # Ensure git submodules are present in the source repo (if this is a git checkout).
    ensure_submodules_present "$SOURCE_ROOT"

    # Run modes decide which component sources must exist. An image-mode
    # service (deploy.yml services.<x>.mode: image) needs no source tree at
    # all: the installer only prepares the directory that its rendered .env
    # and exported bundles land in. That is what a Docker Hub install is: the
    # deploy scripts plus images, no component checkouts.
    BACKEND_MODE_CFG="$(yq eval '.services.backend.mode // "source"' "$CONFIG_FILE" 2>/dev/null || echo source)"; [ "$BACKEND_MODE_CFG" = "null" ] && BACKEND_MODE_CFG="source"
    FRONTEND_MODE_CFG="$(yq eval '.services.frontend.mode // "source"' "$CONFIG_FILE" 2>/dev/null || echo source)"; [ "$FRONTEND_MODE_CFG" = "null" ] && FRONTEND_MODE_CFG="source"
    EJABBERD_MODE_CFG="$(yq eval '.services.ejabberd.mode // "source"' "$CONFIG_FILE" 2>/dev/null || echo source)"; [ "$EJABBERD_MODE_CFG" = "null" ] && EJABBERD_MODE_CFG="source"
    export BACKEND_MODE_CFG FRONTEND_MODE_CFG EJABBERD_MODE_CFG

    # If backend sources are still missing, fail early with a helpful message.
    if [ "$BACKEND_MODE_CFG" != "image" ] && ! is_backend_source_complete "$SOURCE_ROOT/ethora-backend"; then
        if [ -d "$SOURCE_ROOT/.git" ]; then
            error "Backend source is missing in $SOURCE_ROOT/ethora-backend. Run: git submodule update --init --recursive"
        else
            error "Backend source is missing in $SOURCE_ROOT/ethora-backend. If you used a ZIP download, please clone via git --recurse-submodules."
        fi
    fi
    
    # If using custom base path, copy directories from source if they don't exist
    if [ -n "$CONFIG_BASE_DIR" ] && [ "$CONFIG_BASE_DIR" != "null" ]; then
        log "Preparing deployment directories at target path..."

        # Guardrail: remove common accidental "misplaced copies" in the SOURCE tree.
        # These files are sometimes copied into src/ root by mistake (should be under src/pages or src/components),
        # and then TypeScript fails with imports like '../http' not found or './Icons/*' not found.
        #
        # We remove them if the correct file exists, or if the file clearly looks like a misplaced page (../http import).
        if [ -f "$SOURCE_ROOT/ethora-app-reactjs/src/pages/Chat.tsx" ] && [ -f "$SOURCE_ROOT/ethora-app-reactjs/src/Chat.tsx" ]; then
            warn "Removing misplaced file in source tree: $SOURCE_ROOT/ethora-app-reactjs/src/Chat.tsx"
            rm -f "$SOURCE_ROOT/ethora-app-reactjs/src/Chat.tsx" 2>/dev/null || true
        fi
        if [ -f "$SOURCE_ROOT/ethora-app-reactjs/src/pages/_Chat.tsx" ] && [ -f "$SOURCE_ROOT/ethora-app-reactjs/src/_Chat.tsx" ]; then
            warn "Removing misplaced file in source tree: $SOURCE_ROOT/ethora-app-reactjs/src/_Chat.tsx"
            rm -f "$SOURCE_ROOT/ethora-app-reactjs/src/_Chat.tsx" 2>/dev/null || true
        fi
        if [ -f "$SOURCE_ROOT/ethora-app-reactjs/src/components/Sorting.tsx" ] && [ -f "$SOURCE_ROOT/ethora-app-reactjs/src/Sorting.tsx" ]; then
            warn "Removing misplaced file in source tree: $SOURCE_ROOT/ethora-app-reactjs/src/Sorting.tsx"
            rm -f "$SOURCE_ROOT/ethora-app-reactjs/src/Sorting.tsx" 2>/dev/null || true
        fi
        for f in "$SOURCE_ROOT/ethora-app-reactjs/src/Chat.tsx" \
                 "$SOURCE_ROOT/ethora-app-reactjs/src/_Chat.tsx" \
                 "$SOURCE_ROOT/ethora-app-reactjs/src/Sorting.tsx"; do
            if [ -f "$f" ] && grep -q "from '\\.\\./http'" "$f" 2>/dev/null; then
                warn "Removing misplaced file in source tree: $f"
                rm -f "$f" 2>/dev/null || true
            fi
        done
        
        if [ "$BACKEND_MODE_CFG" = "image" ] && ! is_backend_source_complete "$SOURCE_ROOT/ethora-backend"; then
            log "Backend runs from an image and no source is present: preparing $BACKEND_DIR for its rendered configuration only"
            mkdir -p "$BACKEND_DIR/services/api" "$BACKEND_DIR/services/push" "$BACKEND_DIR/services/ai/ai-service" "$BACKEND_DIR/services/ai/docs-parse"
        else
            # Copy/sync backend (ensure it's complete; partial copies can break docker-compose before mongo even starts)
            if ! is_backend_complete "$BACKEND_DIR"; then
                if [ -d "$BACKEND_DIR" ]; then
                    warn "Backend directory exists but looks incomplete. Re-syncing from source..."
                else
                    log "Copying backend from $SOURCE_ROOT/ethora-backend to $BACKEND_DIR..."
                fi
                # Avoid copying runtime data directories from the source repo
                copy_dir_with_progress "$SOURCE_ROOT/ethora-backend" "$BACKEND_DIR" "backend" --exclude "docker/data/**" --exclude "docker/data" --exclude "docker-data/**" --exclude "docker-data"
                log "Backend prepared successfully"
            else
                log "Backend directory already exists at $BACKEND_DIR"
                # Keep target up-to-date with source code on re-runs, but do NOT clobber runtime artifacts.
                # This fixes cases where /home/.../deptest has older code than /home/.../ethora-monoserver.
                copy_dir_with_progress "$SOURCE_ROOT/ethora-backend" "$BACKEND_DIR" "backend (sync)" --delete \
                  --exclude "**/node_modules" \
                  --exclude "**/node_modules/**" \
                  --exclude "**/dist" \
                  --exclude "**/dist/**" \
                  --exclude "**/bin" \
                  --exclude "**/bin/**" \
                  --exclude "**/.env" \
                  --exclude "docker/data/**" --exclude "docker/data" \
                  --exclude "docker-data/**" --exclude "docker-data"
            fi
        
        fi

        if [ "$FRONTEND_MODE_CFG" = "image" ] && ! is_frontend_complete "$SOURCE_ROOT/ethora-app-reactjs"; then
            log "Frontend runs from an image and no source is present: preparing $FRONTEND_DIR for the exported bundle only"
            mkdir -p "$FRONTEND_DIR/dist" "$FRONTEND_DIR/public"
        else
            # Copy/sync frontend (ensure it's complete)
            if ! is_frontend_complete "$FRONTEND_DIR"; then
                if [ -d "$FRONTEND_DIR" ]; then
                    warn "Frontend directory exists but looks incomplete. Re-syncing from source..."
                else
                    log "Copying frontend from $SOURCE_ROOT/ethora-app-reactjs to $FRONTEND_DIR..."
                fi
                copy_dir_with_progress "$SOURCE_ROOT/ethora-app-reactjs" "$FRONTEND_DIR" "frontend"
                log "Frontend prepared successfully"
            else
                log "Frontend directory already exists at $FRONTEND_DIR"
                # Sync source updates without overwriting local installs/build outputs.
                copy_dir_with_progress "$SOURCE_ROOT/ethora-app-reactjs" "$FRONTEND_DIR" "frontend (sync)" --delete \
                  --exclude "node_modules" \
                  --exclude "node_modules/**" \
                  --exclude "dist" \
                  --exclude "dist/**" \
                  --exclude ".env"
            fi

            # Guardrail: remove accidental "misplaced copies" in the TARGET tree too.
            if [ -f "$FRONTEND_DIR/src/pages/Chat.tsx" ] && [ -f "$FRONTEND_DIR/src/Chat.tsx" ]; then
                warn "Removing misplaced file in target tree: $FRONTEND_DIR/src/Chat.tsx"
                rm -f "$FRONTEND_DIR/src/Chat.tsx" 2>/dev/null || true
            fi
            if [ -f "$FRONTEND_DIR/src/pages/_Chat.tsx" ] && [ -f "$FRONTEND_DIR/src/_Chat.tsx" ]; then
                warn "Removing misplaced file in target tree: $FRONTEND_DIR/src/_Chat.tsx"
                rm -f "$FRONTEND_DIR/src/_Chat.tsx" 2>/dev/null || true
            fi
            if [ -f "$FRONTEND_DIR/src/components/Sorting.tsx" ] && [ -f "$FRONTEND_DIR/src/Sorting.tsx" ]; then
                warn "Removing misplaced file in target tree: $FRONTEND_DIR/src/Sorting.tsx"
                rm -f "$FRONTEND_DIR/src/Sorting.tsx" 2>/dev/null || true
            fi
            for f in "$FRONTEND_DIR/src/Chat.tsx" \
                     "$FRONTEND_DIR/src/_Chat.tsx" \
                     "$FRONTEND_DIR/src/Sorting.tsx"; do
                if [ -f "$f" ] && grep -q "from '\\.\\./http'" "$f" 2>/dev/null; then
                    warn "Removing misplaced file in target tree: $f"
                    rm -f "$f" 2>/dev/null || true
                fi
            done
        
        fi

        if [ "$EJABBERD_MODE_CFG" = "image" ] && ! is_ejabberd_complete "$SOURCE_ROOT/ejabberd-docker"; then
            log "ejabberd runs from an image and no source is present: preparing $EJABBERD_DIR for the files extracted from the image"
            mkdir -p "$EJABBERD_DIR/docker"
        else
            # Copy/sync ejabberd (avoid copying docker-data)
            if ! is_ejabberd_complete "$EJABBERD_DIR"; then
                if [ -d "$EJABBERD_DIR" ]; then
                    warn "Ejabberd directory exists but looks incomplete. Re-syncing from source..."
                else
                    log "Copying ejabberd from $SOURCE_ROOT/ejabberd-docker to $EJABBERD_DIR..."
                fi
                copy_dir_with_progress "$SOURCE_ROOT/ejabberd-docker" "$EJABBERD_DIR" "ejabberd" --exclude "docker-data/**" --exclude "docker-data"
                log "Ejabberd prepared successfully"
            else
                log "Ejabberd directory already exists at $EJABBERD_DIR"
                # Sync config/module updates, but keep runtime docker-data intact.
                copy_dir_with_progress "$SOURCE_ROOT/ejabberd-docker" "$EJABBERD_DIR" "ejabberd (sync)" --delete \
                  --exclude "docker-data/**" --exclude "docker-data"
                # Update Dockerfile and entrypoint to ensure latest version
                if [ -f "$SOURCE_ROOT/ejabberd-docker/docker/Dockerfile" ]; then
                    log "Updating Ejabberd Dockerfile..."
                    cp "$SOURCE_ROOT/ejabberd-docker/docker/Dockerfile" "$EJABBERD_DIR/docker/Dockerfile" || warn "Failed to update Dockerfile"
                fi
                if [ -f "$SOURCE_ROOT/ejabberd-docker/docker/entrypoint.sh" ]; then
                    log "Updating Ejabberd entrypoint script..."
                    cp "$SOURCE_ROOT/ejabberd-docker/docker/entrypoint.sh" "$EJABBERD_DIR/docker/entrypoint.sh" || warn "Failed to update entrypoint"
                    chmod +x "$EJABBERD_DIR/docker/entrypoint.sh" || warn "Failed to make entrypoint executable"
                fi
            fi
        fi

        # Copy/sync uptime (optional). Even when disabled, keeping the folder in the target helps developers
        # enable it later without re-running a full install.
        if [ -d "$SOURCE_ROOT/ethora-uptime" ] && ! is_node_project_complete "$SOURCE_ROOT/ethora-uptime"; then
            warn "Skipping uptime copy: $SOURCE_ROOT/ethora-uptime is an empty directory (submodule not initialized)."
        elif [ -d "$SOURCE_ROOT/ethora-uptime" ]; then
            if [ ! -d "$UPTIME_DIR" ]; then
                log "Copying uptime from $SOURCE_ROOT/ethora-uptime to $UPTIME_DIR..."
                copy_dir_with_progress "$SOURCE_ROOT/ethora-uptime" "$UPTIME_DIR" "uptime" \
                  --exclude "node_modules" --exclude "node_modules/**"
            else
                log "Uptime directory already exists at $UPTIME_DIR"
                copy_dir_with_progress "$SOURCE_ROOT/ethora-uptime" "$UPTIME_DIR" "uptime (sync)" --delete \
                  --exclude "node_modules" --exclude "node_modules/**"
            fi
        fi

        # Copy/sync SDK playground (optional)
        if [ -d "$SOURCE_ROOT/ethora-sdk-playground" ] && ! is_node_project_complete "$SOURCE_ROOT/ethora-sdk-playground"; then
            warn "Skipping SDK playground copy: $SOURCE_ROOT/ethora-sdk-playground is an empty directory (submodule not initialized)."
        elif [ -d "$SOURCE_ROOT/ethora-sdk-playground" ]; then
            if [ ! -d "$PLAYGROUND_DIR" ]; then
                log "Copying ethora-sdk-playground from $SOURCE_ROOT/ethora-sdk-playground to $PLAYGROUND_DIR..."
                copy_dir_with_progress "$SOURCE_ROOT/ethora-sdk-playground" "$PLAYGROUND_DIR" "ethora-sdk-playground" \
                  --exclude "node_modules" --exclude "node_modules/**"
            else
                log "SDK playground directory already exists at $PLAYGROUND_DIR"
                copy_dir_with_progress "$SOURCE_ROOT/ethora-sdk-playground" "$PLAYGROUND_DIR" "ethora-sdk-playground (sync)" --delete \
                  --exclude "node_modules" --exclude "node_modules/**"
            fi
        fi

        if [ "$FRONTEND_MODE_CFG" = "image" ] && ! is_node_project_complete "$SOURCE_ROOT/ethora-chat-component"; then
            log "Chat component source not present; not needed when the frontend runs from an image"
        else
            if ! is_node_project_complete "$SOURCE_ROOT/ethora-chat-component"; then
                if [ -d "$SOURCE_ROOT/ethora-chat-component" ]; then
                    error "Source chat component at $SOURCE_ROOT/ethora-chat-component is an empty directory (submodule not initialized). Run: git -C \"$SOURCE_ROOT\" submodule update --init ethora-chat-component"
                fi
                error "Source chat component directory is missing at $SOURCE_ROOT/ethora-chat-component"
            fi
            if [ ! -d "$ROOT_DIR/ethora-chat-component" ]; then
                log "Copying ethora-chat-component from $SOURCE_ROOT/ethora-chat-component to $ROOT_DIR/ethora-chat-component..."
                copy_dir_with_progress "$SOURCE_ROOT/ethora-chat-component" "$ROOT_DIR/ethora-chat-component" "ethora-chat-component" \
                  --exclude "node_modules" --exclude "node_modules/**" \
                  --exclude "dist" --exclude "dist/**"
            else
                log "Chat component directory already exists at $ROOT_DIR/ethora-chat-component"
                copy_dir_with_progress "$SOURCE_ROOT/ethora-chat-component" "$ROOT_DIR/ethora-chat-component" "ethora-chat-component (sync)" --delete \
                  --exclude "node_modules" --exclude "node_modules/**" \
                  --exclude "dist" --exclude "dist/**"
            fi
        fi

        # Copy/sync widget bundle source (optional)
        widget_enabled_from_config="$(yq eval '.services.widget.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
        if [ "${widget_enabled_from_config:-false}" == "true" ] && ! is_node_project_complete "$SOURCE_ROOT/ethora-ai-chat-widget"; then
            if [ -d "$SOURCE_ROOT/ethora-ai-chat-widget" ]; then
                error "Widget is enabled, but $SOURCE_ROOT/ethora-ai-chat-widget is an empty directory (submodule not initialized). Run: git -C \"$SOURCE_ROOT\" submodule update --init ethora-ai-chat-widget"
            fi
            error "Widget is enabled, but source widget directory is missing at $SOURCE_ROOT/ethora-ai-chat-widget"
        fi
        if is_node_project_complete "$SOURCE_ROOT/ethora-ai-chat-widget"; then
            if [ ! -d "$WIDGET_DIR" ]; then
                log "Copying ethora-ai-chat-widget from $SOURCE_ROOT/ethora-ai-chat-widget to $WIDGET_DIR..."
                copy_dir_with_progress "$SOURCE_ROOT/ethora-ai-chat-widget" "$WIDGET_DIR" "ethora-ai-chat-widget" \
                  --exclude "node_modules" --exclude "node_modules/**" \
                  --exclude "dist" --exclude "dist/**"
            else
                log "Widget directory already exists at $WIDGET_DIR"
                copy_dir_with_progress "$SOURCE_ROOT/ethora-ai-chat-widget" "$WIDGET_DIR" "ethora-ai-chat-widget (sync)" --delete \
                  --exclude "node_modules" --exclude "node_modules/**" \
                  --exclude "dist" --exclude "dist/**" \
                  --exclude ".env.production.local"
            fi
        fi

        # Copy/sync hosted MCP server source (optional)
        mcp_enabled_from_config="$(yq eval '.services.mcp.enabled // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
        if [ "${mcp_enabled_from_config:-false}" == "true" ] && ! is_node_project_complete "$SOURCE_ROOT/ethora-mcp-server"; then
            if [ -d "$SOURCE_ROOT/ethora-mcp-server" ]; then
                error "MCP server is enabled, but $SOURCE_ROOT/ethora-mcp-server is an empty directory (submodule not initialized). Run: git -C \"$SOURCE_ROOT\" submodule update --init ethora-mcp-server"
            fi
            error "MCP server is enabled, but source directory is missing at $SOURCE_ROOT/ethora-mcp-server"
        fi
        if is_node_project_complete "$SOURCE_ROOT/ethora-mcp-server"; then
            if [ ! -d "$MCP_DIR" ]; then
                log "Copying ethora-mcp-server from $SOURCE_ROOT/ethora-mcp-server to $MCP_DIR..."
                copy_dir_with_progress "$SOURCE_ROOT/ethora-mcp-server" "$MCP_DIR" "ethora-mcp-server" \
                  --exclude "node_modules" --exclude "node_modules/**" \
                  --exclude "dist" --exclude "dist/**"
            else
                log "MCP server directory already exists at $MCP_DIR"
                copy_dir_with_progress "$SOURCE_ROOT/ethora-mcp-server" "$MCP_DIR" "ethora-mcp-server (sync)" --delete \
                  --exclude "node_modules" --exclude "node_modules/**" \
                  --exclude "dist" --exclude "dist/**" \
                  --exclude ".env"
            fi
        fi

        # If running via sudo, ensure the target tree is usable by the invoking user (prevents later EACCES issues).
        if [ -n "$SUDO_USER" ] && id "$SUDO_USER" >/dev/null 2>&1; then
            chown -R "$SUDO_USER":"$SUDO_USER" "$ROOT_DIR/ethora-backend" "$ROOT_DIR/ethora-app-reactjs" "$ROOT_DIR/ethora-chat-component" "$ROOT_DIR/ejabberd-docker" "$ROOT_DIR/ethora-uptime" "$ROOT_DIR/ethora-sdk-playground" "$ROOT_DIR/ethora-ai-chat-widget" "$ROOT_DIR/ethora-mcp-server" 2>/dev/null || true
        fi
    fi
    
    log "Using paths:"
    log "  Source: $SOURCE_ROOT"
    log "  Base: $ROOT_DIR"
    log "  Backend: $BACKEND_DIR"
    log "  Frontend: $FRONTEND_DIR"
    log "  Ejabberd: $EJABBERD_DIR"
    log "  Uptime: $UPTIME_DIR"
    log "  Playground: $PLAYGROUND_DIR"
    log "  Widget: $WIDGET_DIR"
    log "  MCP server: $MCP_DIR"
    log "  Canonical deploy config: $CONFIG_FILE"
    if [ "$ROOT_DIR" != "$SOURCE_ROOT" ]; then
        log "  Deploy scripts/config live only at: $SOURCE_ROOT/deploy"
    fi
    
    # Load configuration using yq
    export API_DOMAIN=$(yq eval '.domains.api' "$CONFIG_FILE")
    export WEB_DOMAIN=$(yq eval '.domains.web' "$CONFIG_FILE")
    export XMPP_DOMAIN=$(yq eval '.domains.xmpp' "$CONFIG_FILE")
    export FILES_DOMAIN=$(yq eval '.domains.files' "$CONFIG_FILE")
    export SECURE_FILES_DOMAIN=$(yq eval '.domains.secure_files // ""' "$CONFIG_FILE")
    export PLAYGROUND_DOMAIN=$(yq eval '.domains.playground // ""' "$CONFIG_FILE")
    export WIDGET_DOMAIN=$(yq eval '.domains.widget // ""' "$CONFIG_FILE")
    export MCP_DOMAIN=$(yq eval '.domains.mcp // ""' "$CONFIG_FILE")
    export HOSTED_APPS_ROOT_DOMAIN=$(yq eval '.domains.hosted_apps_root // ""' "$CONFIG_FILE")
    
    export SSL_METHOD=$(yq eval '.ssl.method' "$CONFIG_FILE")
    export SSL_EMAIL=$(yq eval '.ssl.email' "$CONFIG_FILE")
    
    export MONGO_PORT=$(yq eval '.databases.mongo.port' "$CONFIG_FILE")
    export MONGO_DB=$(yq eval '.databases.mongo.database' "$CONFIG_FILE")
    export MYSQL_ROOT_PASSWORD=$(yq eval '.databases.mysql.root_password' "$CONFIG_FILE")
    export REDIS_PORT=$(yq eval '.databases.redis.port' "$CONFIG_FILE")
    
    export BACKEND_PORT=$(yq eval '.services.backend.port' "$CONFIG_FILE")
    export NODE_ENV=$(yq eval '.services.backend.node_env // "production"' "$CONFIG_FILE")
    export API_CLIENT_MAX_BODY_SIZE=$(yq eval '.services.backend.client_max_body_size // "50M"' "$CONFIG_FILE")
    export PUSH_ENABLED="$(yq eval '.services.push.enabled | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; export PUSH_ENABLED="${PUSH_ENABLED:-true}"
    export PUSH_PORT=$(yq eval '.services.push.port // 8098' "$CONFIG_FILE")
    export PLAYGROUND_ENABLED="$(yq eval '.services.playground.enabled | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; export PLAYGROUND_ENABLED="${PLAYGROUND_ENABLED:-true}"
    export PLAYGROUND_PORT=$(yq eval '.services.playground.port // 3020' "$CONFIG_FILE")
    # Hosted MCP server (optional; off unless explicitly enabled). Read raw so
    # an explicit false is not swallowed by yq's `//` alternative.
    mcp_enabled_raw=$(yq eval '.services.mcp.enabled' "$CONFIG_FILE")
    if [ "$mcp_enabled_raw" = "true" ] || [ "$mcp_enabled_raw" = "false" ]; then
        export MCP_ENABLED="$mcp_enabled_raw"
    else
        export MCP_ENABLED="false"
    fi
    export MCP_PORT=$(yq eval '.services.mcp.port // 3030' "$CONFIG_FILE")
    mcp_dangerous_raw=$(yq eval '.services.mcp.enable_dangerous_tools' "$CONFIG_FILE")
    if [ "$mcp_dangerous_raw" = "false" ]; then
        export MCP_ENABLE_DANGEROUS_TOOLS="false"
    else
        export MCP_ENABLE_DANGEROUS_TOOLS="true"
    fi
    # Derive mcp.<root-of-web> when enabled and domains.mcp is blank, so SSL
    # (which runs before setup-env.sh) already knows the host on first install.
    if [ "${MCP_ENABLED}" == "true" ] && { [ -z "${MCP_DOMAIN:-}" ] || [ "${MCP_DOMAIN:-}" == "null" ]; } && \
       [ "$WEB_DOMAIN" != "localhost" ] && [[ "$WEB_DOMAIN" == *.* ]]; then
        export MCP_DOMAIN="mcp.$(echo "$WEB_DOMAIN" | sed 's|^[^.]*\.||')"
    fi
    # AI feature umbrella: when disabled, all AI-related services are forced off (ai-service/docs-parse/crawler).
    # Read it before WIDGET_ENABLED so the widget default below can fall through to it.
    export AI_FEATURE_ENABLED=$(yq eval '.features.ai_service // "false"' "$CONFIG_FILE")
    # Widget enabled: respect explicit value; default to AI feature when omitted.
    # Reason: the admin panel's AI Widget tab needs widget hosting for the
    # embed snippet to point at a real assistant.js, so AI-on installs need
    # widget hosting on by default. Explicit true/false from the operator wins.
    # Read raw without `//` — yq's alternative falls through on explicit false too.
    widget_enabled_raw=$(yq eval '.services.widget.enabled' "$CONFIG_FILE")
    if [ "$widget_enabled_raw" = "true" ] || [ "$widget_enabled_raw" = "false" ]; then
        export WIDGET_ENABLED="$widget_enabled_raw"
    else
        export WIDGET_ENABLED="$AI_FEATURE_ENABLED"
    fi
    export WIDGET_SCRIPT_VERSION=$(yq eval '.services.widget.script_version // ""' "$CONFIG_FILE")
    export HOSTED_APPS_ENABLED=$(yq eval '.services.hosted_apps.enabled // "false"' "$CONFIG_FILE")

    export AI_SERVICE_ENABLED=$(yq eval '.services.ai_service.enabled' "$CONFIG_FILE")
    export AI_SERVICE_PORT=$(yq eval '.services.ai_service.port // 8013' "$CONFIG_FILE")
    export DOCS_PARSE_PORT=$(yq eval '.services.docs_parse_service.port // 8201' "$CONFIG_FILE")
    export DOCS_PARSE_ENABLED=$(yq eval '.services.docs_parse_service.enabled' "$CONFIG_FILE")
    export CRAWLER_ENABLED=$(yq eval '.services.crawler.enabled // "false"' "$CONFIG_FILE")
    export CRAWLER_PORT=$(yq eval '.services.crawler.port // 8000' "$CONFIG_FILE")

    if [ "${AI_FEATURE_ENABLED}" != "true" ]; then
        export AI_SERVICE_ENABLED="false"
        export DOCS_PARSE_ENABLED="false"
        export CRAWLER_ENABLED="false"
    fi
    # Uptime is very useful for local dev. For localhost installs, default it to enabled unless explicitly set.
    # For production installs, keep it opt-in unless explicitly enabled in config.
    export UPTIME_ENABLED="$(yq eval '.services.uptime.enabled' "$CONFIG_FILE")"
    if [ -z "${UPTIME_ENABLED:-}" ] || [ "$UPTIME_ENABLED" == "null" ]; then
        if [ "$API_DOMAIN" == "localhost" ]; then
            export UPTIME_ENABLED="true"
        else
            export UPTIME_ENABLED="false"
        fi
    fi
    export UPTIME_PORT=$(yq eval '.services.uptime.port // 8099' "$CONFIG_FILE")
    export UPTIME_POSTGRES_PORT=$(yq eval '.services.uptime.postgres_port // 5433' "$CONFIG_FILE")
    # Uptime dashboard tiles (instances)
    export UPTIME_PUBLIC_ENABLED="$(yq eval '.services.uptime.public_enabled | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; export UPTIME_PUBLIC_ENABLED="${UPTIME_PUBLIC_ENABLED:-true}"
    export UPTIME_ETHORA_ENABLED=$(yq eval '.services.uptime.ethora_enabled // "false"' "$CONFIG_FILE")

    # Centrifugo (real-time stats); per-deployment config + secrets.
    # Backend reaches it via http://127.0.0.1:${CENTRIFUGO_PORT}/api (host network),
    # the centrifugo container listens on 8000 internally and binds to ${CENTRIFUGO_PORT} on the host.
    export CENTRIFUGO_ENABLED="$(yq eval '.services.centrifugo.enabled | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; export CENTRIFUGO_ENABLED="${CENTRIFUGO_ENABLED:-true}"
    export CENTRIFUGO_PORT=$(yq eval '.services.centrifugo.port // 8001' "$CONFIG_FILE")
    export CENTRIFUGO_TIMEOUT_MS=$(yq eval '.services.centrifugo.timeout_ms // 2000' "$CONFIG_FILE")
    export CENTRIFUGO_API_KEY=$(yq eval '.services.centrifugo.api_key // ""' "$CONFIG_FILE")
    export CENTRIFUGO_HMAC_SECRET=$(yq eval '.services.centrifugo.hmac_secret // ""' "$CONFIG_FILE")
    export CENTRIFUGO_ADMIN_PASSWORD=$(yq eval '.services.centrifugo.admin_password // ""' "$CONFIG_FILE")
    export CENTRIFUGO_ADMIN_SECRET=$(yq eval '.services.centrifugo.admin_secret // ""' "$CONFIG_FILE")

    export XMPP_ADMIN_PASSWORD=$(yq eval '.services.ejabberd.admin_password' "$CONFIG_FILE")
    
    export ADMIN_EMAIL=$(yq eval '.admin.email' "$CONFIG_FILE")
    export ADMIN_PASSWORD=$(yq eval '.admin.password' "$CONFIG_FILE")

    # Base app config (used by initEthoraApp.js)
    export BASE_APP_DISPLAY_NAME=$(yq eval '.base_app.display_name // "Ethora"' "$CONFIG_FILE")
    export BASE_APP_DOMAIN_NAME=$(yq eval '.base_app.domain_name // ""' "$CONFIG_FILE")
    export BASE_APP_OWNER_EMAIL=$(yq eval '.base_app.owner_email // ""' "$CONFIG_FILE")
    export BASE_APP_OWNER_PASSWORD=$(yq eval '.base_app.owner_password // ""' "$CONFIG_FILE")
    export BASE_APP_START_BALANCE=$(yq eval '.base_app.start_balance // 1000000' "$CONFIG_FILE")

    # SDK playground credentials (optional; required for backend SDK calls)
    export PLAYGROUND_APP_ID=$(yq eval '.playground.app_id // ""' "$CONFIG_FILE")
    export PLAYGROUND_APP_SECRET=$(yq eval '.playground.app_secret // ""' "$CONFIG_FILE")

    # If base_app.domain_name is not provided, derive it from domains.web (subdomain).
    # Example: app.chat.example.com -> app
    if [ -z "$BASE_APP_DOMAIN_NAME" ] || [ "$BASE_APP_DOMAIN_NAME" == "null" ]; then
        if [ "$WEB_DOMAIN" == "localhost" ]; then
            export BASE_APP_DOMAIN_NAME="ethora"
        else
            export BASE_APP_DOMAIN_NAME="$(echo "$WEB_DOMAIN" | cut -d'.' -f1)"
        fi
    fi
    
    export JWT_SECRET=$(yq eval '.security.jwt_secret' "$CONFIG_FILE")
    export REFRESH_SECRET=$(yq eval '.security.refresh_secret' "$CONFIG_FILE")
    # Shared secret used by backend endpoints that ejabberd custom modules call (track-member/track-last-message).
    export XMPP_SECRET=$(yq eval '.security.xmpp_secret // ""' "$CONFIG_FILE")
    # Optional overrides for tracking URLs (full URLs)
    export TRACK_MEMBER_URL=$(yq eval '.services.ejabberd.track_member_url // ""' "$CONFIG_FILE")
    export TRACK_LAST_MESSAGE_URL=$(yq eval '.services.ejabberd.track_last_message_url // ""' "$CONFIG_FILE")
    export TRACK_MESSAGE_URL=$(yq eval '.services.ejabberd.track_message_url // ""' "$CONFIG_FILE")
    # MAM history-read audit endpoint (mod_history_access).
    export HISTORY_ACCESS_URL=$(yq eval '.services.ejabberd.history_access_url // ""' "$CONFIG_FILE")
    # Message edit/delete audit endpoint (mod_edit / mod_delete).
    export MESSAGE_AUDIT_URL=$(yq eval '.services.ejabberd.message_audit_url // ""' "$CONFIG_FILE")

    export MINIO_ROOT_USER=$(yq eval '.storage.minio_root_user' "$CONFIG_FILE")
    export MINIO_ROOT_PASSWORD=$(yq eval '.storage.minio_root_password' "$CONFIG_FILE")
    
    # Cloudflare Turnstile (optional)
    export TURNSTILE_SITE_KEY=$(yq eval '.security.turnstile_site_key // ""' "$CONFIG_FILE")
    export TURNSTILE_SECRET_KEY=$(yq eval '.security.turnstile_secret_key // ""' "$CONFIG_FILE")

    # Swagger defaults:
    # - localhost: enabled by default for developer convenience
    # - production: follow deploy.yml feature flags (default: enabled; can be turned off)
    #
    # NOTE:
    # These values are persisted in .deploy.env and used by setup-env.sh to generate backend .env.
    swagger_enabled="$(yq eval '.features.swagger | select(. != null)' "$CONFIG_FILE" 2>/dev/null)"; swagger_enabled="${swagger_enabled:-true}"
    swagger_internal_enabled="$(yq eval '.features.swagger_internal // false' "$CONFIG_FILE" 2>/dev/null || echo "false")"
    if [ "$API_DOMAIN" == "localhost" ]; then
        export ENABLE_SWAGGER="true"
        # Keep internal swagger off unless explicitly enabled.
        if [ "$swagger_internal_enabled" == "true" ]; then
            export ENABLE_SWAGGER_INTERNAL="true"
        else
            export ENABLE_SWAGGER_INTERNAL="false"
        fi
    else
        # Production: strictly follow config flags.
        if [ "$swagger_enabled" == "true" ]; then
            export ENABLE_SWAGGER="true"
        else
            export ENABLE_SWAGGER="false"
        fi
        if [ "$swagger_internal_enabled" == "true" ]; then
            export ENABLE_SWAGGER_INTERNAL="true"
        else
            export ENABLE_SWAGGER_INTERNAL="false"
        fi
    fi

    # Uptime service defaults (container-to-container DB URL)
    if [ "${UPTIME_ENABLED}" == "true" ]; then
        export UPTIME_DATABASE_URL="postgresql://uptime:uptime@uptime-db:5432/uptime"
    else
        export UPTIME_DATABASE_URL=""
    fi

    # Build / version identity (used by API /ping and monitoring)
    # Prefer git commit from the monoserver repo (deploy lives inside it). Works even when installing to a separate base dir.
    if command -v git >/dev/null 2>&1 && [ -d "$DEFAULT_ROOT_DIR/.git" ]; then
        export ETHORA_BUILD_COMMIT="$(git -C "$DEFAULT_ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "")"
    else
        export ETHORA_BUILD_COMMIT=""
    fi
    export ETHORA_BUILD_TIME="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    export ETHORA_BUILD_VERSION="$(date -u +'%y.%m.%d')"
    
    # Frontend service flags (optional, defaults to false)
    export DISABLE_FIREBASE=$(yq eval '.frontend.disable_firebase // "false"' "$CONFIG_FILE")
    export DISABLE_GA=$(yq eval '.frontend.disable_ga // "false"' "$CONFIG_FILE")
    export DISABLE_CLARITY=$(yq eval '.frontend.disable_clarity // "false"' "$CONFIG_FILE")

    # Frontend tracking ids (optional)
    export GA_ID=$(yq eval '.frontend.ga_id // ""' "$CONFIG_FILE")
    export GTM_ID=$(yq eval '.frontend.gtm_id // ""' "$CONFIG_FILE")
    export CLARITY_ID=$(yq eval '.frontend.clarity_id // ""' "$CONFIG_FILE")

    # HubSpot (optional; disabled by default)
    export HUBSPOT_ENABLED=$(yq eval '.integrations.hubspot.enabled // "false"' "$CONFIG_FILE")
    export HUBSPOT_PORTAL_ID=$(yq eval '.integrations.hubspot.portal_id // ""' "$CONFIG_FILE")
    export HUBSPOT_FORM_ID_APP_CREATE=$(yq eval '.integrations.hubspot.form_id_app_create // ""' "$CONFIG_FILE")
    export HUBSPOT_FORM_ID_SIGNUP=$(yq eval '.integrations.hubspot.form_id_signup // ""' "$CONFIG_FILE")
    export HUBSPOT_FORM_ID_TUTORIAL=$(yq eval '.integrations.hubspot.form_id_tutorial // ""' "$CONFIG_FILE")
    export HUBSPOT_REGION=$(yq eval '.integrations.hubspot.region // "na1"' "$CONFIG_FILE")

    # AI providers (optional)
    export AI_API_URL=$(yq eval '.ai.ai_api_url // "https://api.openai.com/v1"' "$CONFIG_FILE")
    export AI_API_KEY=$(yq eval '.ai.ai_api_key // ""' "$CONFIG_FILE")
    export AI_CHAT_MODEL=$(yq eval '.ai.chat_model // "gpt-4.1-mini"' "$CONFIG_FILE")
    export AI_EMBEDDING_MODEL=$(yq eval '.ai.embedding_model // "text-embedding-3-small"' "$CONFIG_FILE")
    if [ -z "$AI_API_KEY" ] || [ "$AI_API_KEY" == "null" ]; then
        export AI_API_KEY=$(yq eval '.ai.openai_api_key // ""' "$CONFIG_FILE")
    fi
    export AI_POSTGRES_PORT=$(yq eval '.services.ai_service.postgres_port // 5434' "$CONFIG_FILE")
    export AI_POSTGRES_DB=$(yq eval '.services.ai_service.postgres_database // "ai_service_embeddings_db"' "$CONFIG_FILE")
    export AI_POSTGRES_USER=$(yq eval '.services.ai_service.postgres_user // "ai_embeddings"' "$CONFIG_FILE")
    export AI_POSTGRES_PASSWORD=$(yq eval '.services.ai_service.postgres_password // ""' "$CONFIG_FILE")
    export AI_PG_URL=$(yq eval '.services.ai_service.pg_url // ""' "$CONFIG_FILE")
    if [ -z "$AI_PG_URL" ] || [ "$AI_PG_URL" == "null" ]; then
        export AI_PG_URL=""
    fi

    # Email TLD validation policy.
    # Default "off" so freshly-installed self-hosted/enterprise stacks accept
    # real-world user lists with uncommon TLDs out of the box. Operators can
    # tighten this per-install via deploy.yml (see services.backend.email_tld_validation).
    export EMAIL_TLD_VALIDATION=$(yq eval '.services.backend.email_tld_validation // "off"' "$CONFIG_FILE")
    export EMAIL_TLD_ALLOWLIST=$(yq eval '.services.backend.email_tld_allowlist // ""' "$CONFIG_FILE")

    # Other optional integrations (explicit enable flags)
    export STRIPE_ENABLED=$(yq eval '.features.stripe // "false"' "$CONFIG_FILE")
    export POSTMARK_ENABLED=$(yq eval '.features.postmark // "false"' "$CONFIG_FILE")
    export STRIPE_SECRET=$(yq eval '.integrations.stripe.secret // ""' "$CONFIG_FILE")
    export STRIPE_PUBLIC=$(yq eval '.integrations.stripe.public // ""' "$CONFIG_FILE")
    export STRIPE_PLAN=$(yq eval '.integrations.stripe.plan // ""' "$CONFIG_FILE")
    export POSTMARK_TOKEN=$(yq eval '.integrations.postmark.token // ""' "$CONFIG_FILE")
    export POSTMARK_FROM_EMAIL=$(yq eval '.integrations.postmark.from_email // "noreply@ethoramail.com"' "$CONFIG_FILE")
    export POSTMARK_FROM_NAME=$(yq eval '.integrations.postmark.from_name // "Ethora Platform"' "$CONFIG_FILE")
    export POSTMARK_SUBJECT_PREFIX=$(yq eval '.integrations.postmark.subject_prefix // "Ethora"' "$CONFIG_FILE")

    # Analytics email reports (optional, requires postmark)
    export ANALYTICS_ENABLED=$(yq eval '.features.analytics // "false"' "$CONFIG_FILE")
    export DAILY_REPORT_RECEIVERS=$(yq eval '.integrations.analytics.daily_report_receivers // ""' "$CONFIG_FILE")
    export MONTHLY_REPORT_RECEIVERS=$(yq eval '.integrations.analytics.monthly_report_receivers // ""' "$CONFIG_FILE")
    export REPORT_DAILY_SCHEDULE=$(yq eval '.integrations.analytics.daily_schedule // "30 8 * * *"' "$CONFIG_FILE")
    export REPORT_WEEKLY_SCHEDULE=$(yq eval '.integrations.analytics.weekly_schedule // "30 8 * * 1"' "$CONFIG_FILE")
    export REPORT_MONTHLY_SCHEDULE=$(yq eval '.integrations.analytics.monthly_schedule // "30 8 1 * *"' "$CONFIG_FILE")
    export REPORT_TIMEZONE=$(yq eval '.integrations.analytics.timezone // ""' "$CONFIG_FILE")
    export LEGAL_CONTACT_EMAIL=$(yq eval '.integrations.analytics.legal_email // ""' "$CONFIG_FILE")
    export ALERT_RECIPIENTS=$(yq eval '.integrations.analytics.alert_email // ""' "$CONFIG_FILE")

    # In-app purchases (optional)
    export IAP_ENABLED=$(yq eval '.features.iap // "false"' "$CONFIG_FILE")

    # Firebase Admin (optional)
    export FIREBASE_ENABLED=$(yq eval '.features.firebase // "false"' "$CONFIG_FILE")
    export FIREBASE_PROJECT_NAME=$(yq eval '.integrations.firebase.project_name // ""' "$CONFIG_FILE")
    export FIREBASE_SERVICE_ACCOUNT_PATH=$(yq eval '.integrations.firebase.service_account_path // ""' "$CONFIG_FILE")
    export FIREBASE_WEB_API_KEY=$(yq eval '.integrations.firebase.web.api_key // ""' "$CONFIG_FILE")
    export FIREBASE_WEB_AUTH_DOMAIN=$(yq eval '.integrations.firebase.web.auth_domain // ""' "$CONFIG_FILE")
    export FIREBASE_WEB_PROJECT_ID=$(yq eval '.integrations.firebase.web.project_id // ""' "$CONFIG_FILE")
    export FIREBASE_WEB_STORAGE_BUCKET=$(yq eval '.integrations.firebase.web.storage_bucket // ""' "$CONFIG_FILE")
    export FIREBASE_WEB_MESSAGING_SENDER_ID=$(yq eval '.integrations.firebase.web.messaging_sender_id // ""' "$CONFIG_FILE")
    export FIREBASE_WEB_APP_ID=$(yq eval '.integrations.firebase.web.app_id // ""' "$CONFIG_FILE")
    export FIREBASE_WEB_MEASUREMENT_ID=$(yq eval '.integrations.firebase.web.measurement_id // ""' "$CONFIG_FILE")

    # Blockchain providers (optional; relevant only when BLOCKCHAIN_ENABLED=true)
    export COINBASE_PRIVATE=$(yq eval '.blockchain.coinbase_private // ""' "$CONFIG_FILE")
    export EXTERNAL_BC_NETWORKNAME=$(yq eval '.blockchain.external_bc_networkname // ""' "$CONFIG_FILE")
    export EXTERNAL_BC_WS=$(yq eval '.blockchain.external_bc_ws // ""' "$CONFIG_FILE")
    export ALCHEMY=$(yq eval '.blockchain.alchemy_url // ""' "$CONFIG_FILE")
    export USDC_CONTRACT_ADDRESS=$(yq eval '.blockchain.usdc_contract_address // ""' "$CONFIG_FILE")
    
    # Reuse previously generated secrets from .deploy.env on re-runs.
    # Important: MySQL root password is only applied on first initialization. If we regenerate it while
    # the MySQL data dir is preserved, ejabberd will get 1045 and nginx will return 502 for /ws and /bosh.
    ENV_FILE="$DEPLOY_DIR/.deploy.env"
    read_existing_env_export() {
        local file="$1"
        local key="$2"
        [ -f "$file" ] || return 1
        # Extract from: export KEY="VALUE"
        grep -E "^export ${key}=" "$file" 2>/dev/null | head -n1 | sed -E "s/^export ${key}=\"(.*)\"$/\\1/"
    }

    EXISTING_MYSQL_ROOT_PASSWORD="$(read_existing_env_export "$ENV_FILE" "MYSQL_ROOT_PASSWORD" || true)"
    if { [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" == "null" ]; } && [ -n "$EXISTING_MYSQL_ROOT_PASSWORD" ]; then
        export MYSQL_ROOT_PASSWORD="$EXISTING_MYSQL_ROOT_PASSWORD"
        log "Reusing existing MySQL root password from $ENV_FILE"
    fi

    EXISTING_AI_POSTGRES_PASSWORD="$(read_existing_env_export "$ENV_FILE" "AI_POSTGRES_PASSWORD" || true)"
    if [ "${AI_SERVICE_ENABLED:-false}" == "true" ] && { [ -z "$AI_PG_URL" ] || [ "$AI_PG_URL" == "null" ]; } && { [ -z "${AI_POSTGRES_PASSWORD:-}" ] || [ "${AI_POSTGRES_PASSWORD:-}" == "null" ]; } && [ -n "$EXISTING_AI_POSTGRES_PASSWORD" ]; then
        export AI_POSTGRES_PASSWORD="$EXISTING_AI_POSTGRES_PASSWORD"
        log "Reusing existing AI Postgres password from $ENV_FILE"
    fi

    # Reuse push/internal secrets on reruns (so clients don't have to reconfigure integrations).
    EXISTING_B2B_PUSH_SECRET="$(read_existing_env_export "$ENV_FILE" "B2B_PUSH_SECRET" || true)"
    if { [ -z "${B2B_PUSH_SECRET:-}" ] || [ "${B2B_PUSH_SECRET:-}" == "null" ]; } && [ -n "$EXISTING_B2B_PUSH_SECRET" ]; then
        export B2B_PUSH_SECRET="$EXISTING_B2B_PUSH_SECRET"
        log "Reusing existing B2B_PUSH_SECRET from $ENV_FILE"
    fi

    EXISTING_INTERNAL_REQUESTS_SECRET="$(read_existing_env_export "$ENV_FILE" "INTERNAL_REQUESTS_SECRET" || true)"
    if { [ -z "${INTERNAL_REQUESTS_SECRET:-}" ] || [ "${INTERNAL_REQUESTS_SECRET:-}" == "null" ]; } && [ -n "$EXISTING_INTERNAL_REQUESTS_SECRET" ]; then
        export INTERNAL_REQUESTS_SECRET="$EXISTING_INTERNAL_REQUESTS_SECRET"
        log "Reusing existing INTERNAL_REQUESTS_SECRET from $ENV_FILE"
    fi

    # If the MySQL data directory exists (bind mount) and we still don't have a password, abort with a clear message.
    # This avoids silently generating a new password that won't match the already-initialized MySQL instance.
    # Never assign the global MYSQL_DATA_DIR here: on a fresh host it would
    # leak into docker compose and initialise MySQL at the legacy path
    # instead of DATA_DIR/mysql (preflight-paths.sh then refuses the next
    # run). Check both the configured and the legacy location read-only.
    local existing_mysql_dir=""
    for candidate in "${MYSQL_DATA_DIR:-}" "$EJABBERD_DIR/docker-data/my-sql"; do
        [ -n "$candidate" ] && [ -d "$candidate" ] && [ "$(ls -A "$candidate" 2>/dev/null | wc -l)" -gt 0 ] && { existing_mysql_dir="$candidate"; break; }
    done
    if [ -n "$existing_mysql_dir" ]; then
        if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" == "null" ]; then
            error "MySQL data directory exists at $existing_mysql_dir but no MySQL root password is set (and none found in $ENV_FILE). Set databases.mysql.root_password in deploy.yml or delete $existing_mysql_dir to reinitialize."
        fi
    fi

    # Generate passwords if not provided
    if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" == "null" ]; then
        export MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
        log "Generated MySQL root password"
    fi
    
    if [ -z "$XMPP_ADMIN_PASSWORD" ] || [ "$XMPP_ADMIN_PASSWORD" == "null" ]; then
        export XMPP_ADMIN_PASSWORD=$(openssl rand -base64 16)
        log "Generated Ejabberd admin password"
    fi
    
    if [ -z "$ADMIN_PASSWORD" ] || [ "$ADMIN_PASSWORD" == "null" ]; then
        if [ "${NON_INTERACTIVE:-false}" == "true" ]; then
            export ADMIN_PASSWORD=$(openssl rand -base64 16)
            log "Generated admin password (non-interactive mode)"
        else
            read -sp "Enter admin password: " ADMIN_PASSWORD
            echo
            export ADMIN_PASSWORD
        fi
    fi
    
    if [ -z "$JWT_SECRET" ] || [ "$JWT_SECRET" == "null" ]; then
        export JWT_SECRET=$(openssl rand -base64 64 | tr -d '\n')
        log "Generated JWT secret"
    fi
    
    if [ -z "$REFRESH_SECRET" ] || [ "$REFRESH_SECRET" == "null" ]; then
        export REFRESH_SECRET=$(openssl rand -base64 64 | tr -d '\n')
        log "Generated refresh secret"
    fi

    if [ -z "${B2B_PUSH_SECRET:-}" ] || [ "${B2B_PUSH_SECRET:-}" == "null" ]; then
        export B2B_PUSH_SECRET=$(openssl rand -base64 32)
        log "Generated B2B push secret"
    fi

    if [ -z "${INTERNAL_REQUESTS_SECRET:-}" ] || [ "${INTERNAL_REQUESTS_SECRET:-}" == "null" ]; then
        export INTERNAL_REQUESTS_SECRET=$(openssl rand -base64 32)
        log "Generated internal requests secret"
    fi

    # XMPP_SECRET (ejabberd <-> backend track/audit shared secret): reuse an
    # existing generated value on re-runs, else auto-generate a strong one. Never
    # fall back to a shipped placeholder - the backend now rejects an empty/unset
    # secret (fail closed), and reuse keeps ejabberd and backend in sync across updates.
    if [ -z "$XMPP_SECRET" ] || [ "$XMPP_SECRET" == "null" ]; then
        _existing_xmpp="$(grep -E '^export XMPP_SECRET=' "$DEPLOY_DIR/.deploy.env" 2>/dev/null | head -n1 | sed -E 's/^export XMPP_SECRET="(.*)"$/\1/')"
        if [ -n "$_existing_xmpp" ]; then
            export XMPP_SECRET="$_existing_xmpp"
            log "Reusing existing XMPP shared secret from .deploy.env"
        else
            export XMPP_SECRET=$(openssl rand -base64 32)
            log "Generated XMPP shared secret"
        fi
    fi

    # Centrifugo secrets: auto-generate per install if not provided in deploy.yml.
    # These are used both by the backend (to sign wsTokens and authenticate to /api) and
    # by the centrifugo container (config.json), so they MUST stay in sync within an install.
    if [ -z "${CENTRIFUGO_API_KEY:-}" ] || [ "${CENTRIFUGO_API_KEY:-}" == "null" ]; then
        export CENTRIFUGO_API_KEY=$(openssl rand -hex 32)
        log "Generated Centrifugo API key"
    fi
    if [ -z "${CENTRIFUGO_HMAC_SECRET:-}" ] || [ "${CENTRIFUGO_HMAC_SECRET:-}" == "null" ]; then
        export CENTRIFUGO_HMAC_SECRET=$(openssl rand -hex 32)
        log "Generated Centrifugo HMAC secret"
    fi
    if [ -z "${CENTRIFUGO_ADMIN_PASSWORD:-}" ] || [ "${CENTRIFUGO_ADMIN_PASSWORD:-}" == "null" ]; then
        export CENTRIFUGO_ADMIN_PASSWORD=$(openssl rand -base64 24)
        log "Generated Centrifugo admin password"
    fi
    if [ -z "${CENTRIFUGO_ADMIN_SECRET:-}" ] || [ "${CENTRIFUGO_ADMIN_SECRET:-}" == "null" ]; then
        export CENTRIFUGO_ADMIN_SECRET=$(openssl rand -hex 32)
        log "Generated Centrifugo admin secret"
    fi

    # Derive tracking URLs if not explicitly provided in deploy.yml
    if [ -z "$TRACK_MEMBER_URL" ] || [ "$TRACK_MEMBER_URL" == "null" ]; then
        if [ "$API_DOMAIN" == "localhost" ]; then
            # Ejabberd runs in Docker and cannot reach the host backend via "localhost".
            # Use host.docker.internal for container -> host calls (supported on modern Docker).
            export TRACK_MEMBER_URL="http://host.docker.internal:${BACKEND_PORT}/v1/chats/track-member"
        else
            export TRACK_MEMBER_URL="https://${API_DOMAIN}/v1/chats/track-member"
        fi
    fi
    if [ -z "$TRACK_LAST_MESSAGE_URL" ] || [ "$TRACK_LAST_MESSAGE_URL" == "null" ]; then
        if [ "$API_DOMAIN" == "localhost" ]; then
            # Ejabberd runs in Docker and cannot reach the host backend via "localhost".
            # Use host.docker.internal for container -> host calls (supported on modern Docker).
            export TRACK_LAST_MESSAGE_URL="http://host.docker.internal:${BACKEND_PORT}/v1/chats/track-last-message"
        else
            export TRACK_LAST_MESSAGE_URL="https://${API_DOMAIN}/v1/chats/track-last-message"
        fi
    fi
    if [ -z "$TRACK_MESSAGE_URL" ] || [ "$TRACK_MESSAGE_URL" == "null" ]; then
        if [ "$API_DOMAIN" == "localhost" ]; then
            export TRACK_MESSAGE_URL="http://host.docker.internal:${BACKEND_PORT}/v1/chats/archive-message"
        else
            export TRACK_MESSAGE_URL="https://${API_DOMAIN}/v1/chats/archive-message"
        fi
    fi
    if [ -z "$HISTORY_ACCESS_URL" ] || [ "$HISTORY_ACCESS_URL" == "null" ]; then
        if [ "$API_DOMAIN" == "localhost" ]; then
            export HISTORY_ACCESS_URL="http://host.docker.internal:${BACKEND_PORT}/v1/chats/history-access"
        else
            export HISTORY_ACCESS_URL="https://${API_DOMAIN}/v1/chats/history-access"
        fi
    fi
    if [ -z "$MESSAGE_AUDIT_URL" ] || [ "$MESSAGE_AUDIT_URL" == "null" ]; then
        if [ "$API_DOMAIN" == "localhost" ]; then
            export MESSAGE_AUDIT_URL="http://host.docker.internal:${BACKEND_PORT}/v1/chats/message-audit"
        else
            export MESSAGE_AUDIT_URL="https://${API_DOMAIN}/v1/chats/message-audit"
        fi
    fi

    # Pick the ejabberd config variant for this install.
    # - localhost: use `ejabberd-local.yml` (hosts: localhost; disables unused custom modules like mod_get_user_rooms)
    # - non-localhost: use `ejabberd-prod.yml`
    if [ -z "${EJABBERD_CONFIG_NAME:-}" ] || [ "$EJABBERD_CONFIG_NAME" == "null" ]; then
        if [ "$API_DOMAIN" == "localhost" ]; then
            export EJABBERD_CONFIG_NAME="ejabberd-local.yml"
        else
            export EJABBERD_CONFIG_NAME="ejabberd-prod.yml"
        fi
    fi
    
    if [ -z "$MINIO_ROOT_PASSWORD" ] || [ "$MINIO_ROOT_PASSWORD" == "null" ]; then
        export MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)
        log "Generated MinIO root password"
    fi

    if [ "${AI_SERVICE_ENABLED:-false}" == "true" ]; then
        if [ -n "${AI_PG_URL:-}" ] && [ "${AI_PG_URL:-}" != "null" ]; then
            export AI_POSTGRES_MANAGED="false"
        else
            if [ -z "${AI_POSTGRES_PASSWORD:-}" ] || [ "${AI_POSTGRES_PASSWORD:-}" == "null" ]; then
                export AI_POSTGRES_PASSWORD=$(openssl rand -hex 24)
                log "Generated AI Postgres password"
            fi
            export AI_POSTGRES_MANAGED="true"
            export AI_PG_URL="postgresql://${AI_POSTGRES_USER}:${AI_POSTGRES_PASSWORD}@127.0.0.1:${AI_POSTGRES_PORT}/${AI_POSTGRES_DB}"
        fi
    else
        export AI_POSTGRES_MANAGED="false"
    fi
    
    log "Configuration parsed successfully"
    
    # Save environment variables to a file for other scripts
    ENV_FILE="$DEPLOY_DIR/.deploy.env"
    cat > "$ENV_FILE" <<EOF
export API_DOMAIN="$API_DOMAIN"
export WEB_DOMAIN="$WEB_DOMAIN"
export XMPP_DOMAIN="$XMPP_DOMAIN"
export FILES_DOMAIN="$FILES_DOMAIN"
export SECURE_FILES_DOMAIN="$SECURE_FILES_DOMAIN"
export PLAYGROUND_DOMAIN="$PLAYGROUND_DOMAIN"
export WIDGET_DOMAIN="$WIDGET_DOMAIN"
export MCP_DOMAIN="${MCP_DOMAIN:-}"
export HOSTED_APPS_ROOT_DOMAIN="$HOSTED_APPS_ROOT_DOMAIN"
export SSL_METHOD="$SSL_METHOD"
export SSL_EMAIL="$SSL_EMAIL"
export MONGO_PORT="$MONGO_PORT"
export MONGO_DB="$MONGO_DB"
export MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"
export REDIS_PORT="$REDIS_PORT"
export BACKEND_PORT="$BACKEND_PORT"
export NODE_ENV="${NODE_ENV:-production}"
export API_CLIENT_MAX_BODY_SIZE="${API_CLIENT_MAX_BODY_SIZE:-50M}"
export PUSH_ENABLED="${PUSH_ENABLED:-true}"
export PUSH_PORT="${PUSH_PORT:-8098}"
export PLAYGROUND_ENABLED="${PLAYGROUND_ENABLED:-true}"
export PLAYGROUND_PORT="${PLAYGROUND_PORT:-3020}"
export MCP_ENABLED="${MCP_ENABLED:-false}"
export MCP_PORT="${MCP_PORT:-3030}"
export MCP_ENABLE_DANGEROUS_TOOLS="${MCP_ENABLE_DANGEROUS_TOOLS:-true}"
export WIDGET_ENABLED="${WIDGET_ENABLED:-false}"
export WIDGET_SCRIPT_VERSION="${WIDGET_SCRIPT_VERSION:-}"
export HOSTED_APPS_ENABLED="${HOSTED_APPS_ENABLED:-false}"
export AI_SERVICE_ENABLED="$AI_SERVICE_ENABLED"
export DOCS_PARSE_ENABLED="$DOCS_PARSE_ENABLED"
export CRAWLER_ENABLED="$CRAWLER_ENABLED"
export CRAWLER_PORT="${CRAWLER_PORT:-8000}"
export STRIPE_ENABLED="${STRIPE_ENABLED:-false}"
export EMAIL_TLD_VALIDATION="${EMAIL_TLD_VALIDATION:-off}"
export EMAIL_TLD_ALLOWLIST="${EMAIL_TLD_ALLOWLIST:-}"
export POSTMARK_ENABLED="${POSTMARK_ENABLED:-false}"
export POSTMARK_TOKEN="${POSTMARK_TOKEN:-}"
export POSTMARK_FROM_EMAIL="${POSTMARK_FROM_EMAIL:-noreply@ethoramail.com}"
export POSTMARK_FROM_NAME="${POSTMARK_FROM_NAME:-Ethora Platform}"
export POSTMARK_SUBJECT_PREFIX="${POSTMARK_SUBJECT_PREFIX:-Ethora}"
export ANALYTICS_ENABLED="${ANALYTICS_ENABLED:-false}"
export DAILY_REPORT_RECEIVERS="${DAILY_REPORT_RECEIVERS:-}"
export MONTHLY_REPORT_RECEIVERS="${MONTHLY_REPORT_RECEIVERS:-}"
export REPORT_DAILY_SCHEDULE="${REPORT_DAILY_SCHEDULE:-30 8 * * *}"
export REPORT_WEEKLY_SCHEDULE="${REPORT_WEEKLY_SCHEDULE:-30 8 * * 1}"
export REPORT_MONTHLY_SCHEDULE="${REPORT_MONTHLY_SCHEDULE:-30 8 1 * *}"
export REPORT_TIMEZONE="${REPORT_TIMEZONE:-}"
export LEGAL_CONTACT_EMAIL="${LEGAL_CONTACT_EMAIL:-}"
export ALERT_RECIPIENTS="${ALERT_RECIPIENTS:-}"
export STRIPE_SECRET="${STRIPE_SECRET:-}"
export STRIPE_PUBLIC="${STRIPE_PUBLIC:-}"
export STRIPE_PLAN="${STRIPE_PLAN:-}"
export IAP_ENABLED="${IAP_ENABLED:-false}"
export FIREBASE_ENABLED="${FIREBASE_ENABLED:-false}"
export FIREBASE_PROJECT_NAME="${FIREBASE_PROJECT_NAME:-}"
export FIREBASE_SERVICE_ACCOUNT_PATH="${FIREBASE_SERVICE_ACCOUNT_PATH:-}"
export FIREBASE_WEB_API_KEY="${FIREBASE_WEB_API_KEY:-}"
export FIREBASE_WEB_AUTH_DOMAIN="${FIREBASE_WEB_AUTH_DOMAIN:-}"
export FIREBASE_WEB_PROJECT_ID="${FIREBASE_WEB_PROJECT_ID:-}"
export FIREBASE_WEB_STORAGE_BUCKET="${FIREBASE_WEB_STORAGE_BUCKET:-}"
export FIREBASE_WEB_MESSAGING_SENDER_ID="${FIREBASE_WEB_MESSAGING_SENDER_ID:-}"
export FIREBASE_WEB_APP_ID="${FIREBASE_WEB_APP_ID:-}"
export FIREBASE_WEB_MEASUREMENT_ID="${FIREBASE_WEB_MEASUREMENT_ID:-}"
export UPTIME_ENABLED="${UPTIME_ENABLED:-false}"
export UPTIME_PORT="${UPTIME_PORT:-8099}"
export UPTIME_POSTGRES_PORT="${UPTIME_POSTGRES_PORT:-5433}"
export UPTIME_DATABASE_URL="${UPTIME_DATABASE_URL:-}"
export XMPP_ADMIN_PASSWORD="$XMPP_ADMIN_PASSWORD"
export ADMIN_EMAIL="$ADMIN_EMAIL"
export ADMIN_PASSWORD="$ADMIN_PASSWORD"
export JWT_SECRET="$JWT_SECRET"
export REFRESH_SECRET="$REFRESH_SECRET"
export B2B_PUSH_SECRET="${B2B_PUSH_SECRET:-}"
export INTERNAL_REQUESTS_SECRET="${INTERNAL_REQUESTS_SECRET:-}"
export XMPP_SECRET="$XMPP_SECRET"
export CENTRIFUGO_ENABLED="${CENTRIFUGO_ENABLED:-true}"
export CENTRIFUGO_PORT="${CENTRIFUGO_PORT:-8001}"
export CENTRIFUGO_TIMEOUT_MS="${CENTRIFUGO_TIMEOUT_MS:-2000}"
export CENTRIFUGO_API_KEY="${CENTRIFUGO_API_KEY:-}"
export CENTRIFUGO_HMAC_SECRET="${CENTRIFUGO_HMAC_SECRET:-}"
export CENTRIFUGO_ADMIN_PASSWORD="${CENTRIFUGO_ADMIN_PASSWORD:-}"
export CENTRIFUGO_ADMIN_SECRET="${CENTRIFUGO_ADMIN_SECRET:-}"
export TRACK_MEMBER_URL="$TRACK_MEMBER_URL"
export TRACK_LAST_MESSAGE_URL="$TRACK_LAST_MESSAGE_URL"
export TRACK_MESSAGE_URL="$TRACK_MESSAGE_URL"
export HISTORY_ACCESS_URL="$HISTORY_ACCESS_URL"
export MESSAGE_AUDIT_URL="$MESSAGE_AUDIT_URL"
export MINIO_ROOT_USER="$MINIO_ROOT_USER"
export MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD"
export BASE_APP_DISPLAY_NAME="${BASE_APP_DISPLAY_NAME:-Ethora}"
export BASE_APP_DOMAIN_NAME="${BASE_APP_DOMAIN_NAME:-ethora}"
export BASE_APP_OWNER_EMAIL="${BASE_APP_OWNER_EMAIL:-$ADMIN_EMAIL}"
export BASE_APP_OWNER_PASSWORD="${BASE_APP_OWNER_PASSWORD:-$ADMIN_PASSWORD}"
export BASE_APP_START_BALANCE="${BASE_APP_START_BALANCE:-1000000}"
export PLAYGROUND_APP_ID="${PLAYGROUND_APP_ID:-}"
export PLAYGROUND_APP_SECRET="${PLAYGROUND_APP_SECRET:-}"
export AI_SERVICE_PORT="${AI_SERVICE_PORT:-8013}"
export AI_POSTGRES_PORT="${AI_POSTGRES_PORT:-5434}"
export AI_POSTGRES_DB="${AI_POSTGRES_DB:-ai_service_embeddings_db}"
export AI_POSTGRES_USER="${AI_POSTGRES_USER:-ai_embeddings}"
export AI_POSTGRES_PASSWORD="${AI_POSTGRES_PASSWORD:-}"
export AI_POSTGRES_MANAGED="${AI_POSTGRES_MANAGED:-false}"
export AI_PG_URL="${AI_PG_URL:-}"
export DOCS_PARSE_PORT="${DOCS_PARSE_PORT:-8201}"
export BLOCKCHAIN_ENABLED="${BLOCKCHAIN_ENABLED:-false}"
export SOURCE_ROOT="$SOURCE_ROOT"
export SOURCE_DEPLOY_DIR="$SOURCE_ROOT/deploy"
export CANONICAL_DEPLOY_CONFIG_FILE="$CONFIG_FILE"
export ROOT_DIR="$ROOT_DIR"
export BACKEND_DIR="$BACKEND_DIR"
export FRONTEND_DIR="$FRONTEND_DIR"
export EJABBERD_DIR="$EJABBERD_DIR"
export UPTIME_DIR="$UPTIME_DIR"
export PLAYGROUND_DIR="$PLAYGROUND_DIR"
export WIDGET_DIR="$WIDGET_DIR"
export MCP_DIR="$MCP_DIR"
export TURNSTILE_SITE_KEY="${TURNSTILE_SITE_KEY:-}"
export TURNSTILE_SECRET_KEY="${TURNSTILE_SECRET_KEY:-}"
export ENABLE_SWAGGER="${ENABLE_SWAGGER:-false}"
export ENABLE_SWAGGER_INTERNAL="${ENABLE_SWAGGER_INTERNAL:-false}"
export DISABLE_FIREBASE="${DISABLE_FIREBASE:-false}"
export DISABLE_GA="${DISABLE_GA:-false}"
export DISABLE_CLARITY="${DISABLE_CLARITY:-false}"
export GA_ID="${GA_ID:-}"
export GTM_ID="${GTM_ID:-}"
export CLARITY_ID="${CLARITY_ID:-}"
export HUBSPOT_ENABLED="${HUBSPOT_ENABLED:-false}"
export HUBSPOT_PORTAL_ID="${HUBSPOT_PORTAL_ID:-}"
export HUBSPOT_FORM_ID_APP_CREATE="${HUBSPOT_FORM_ID_APP_CREATE:-}"
export HUBSPOT_FORM_ID_SIGNUP="${HUBSPOT_FORM_ID_SIGNUP:-}"
export HUBSPOT_FORM_ID_TUTORIAL="${HUBSPOT_FORM_ID_TUTORIAL:-}"
export HUBSPOT_REGION="${HUBSPOT_REGION:-na1}"
export AI_API_URL="${AI_API_URL:-https://api.openai.com/v1}"
export AI_API_KEY="${AI_API_KEY:-}"
export AI_CHAT_MODEL="${AI_CHAT_MODEL:-gpt-4.1-mini}"
export AI_EMBEDDING_MODEL="${AI_EMBEDDING_MODEL:-text-embedding-3-small}"
export COINBASE_PRIVATE="${COINBASE_PRIVATE:-}"
export EXTERNAL_BC_NETWORKNAME="${EXTERNAL_BC_NETWORKNAME:-}"
export EXTERNAL_BC_WS="${EXTERNAL_BC_WS:-}"
export ALCHEMY="${ALCHEMY:-}"
export USDC_CONTRACT_ADDRESS="${USDC_CONTRACT_ADDRESS:-}"
export ETHORA_BUILD_COMMIT="${ETHORA_BUILD_COMMIT:-}"
export ETHORA_BUILD_TIME="${ETHORA_BUILD_TIME:-}"
export ETHORA_BUILD_VERSION="${ETHORA_BUILD_VERSION:-}"
export EJABBERD_CONFIG_NAME="${EJABBERD_CONFIG_NAME:-}"
EOF
    chmod 600 "$ENV_FILE"
    # Make the env file readable by the deploying user (so they can run setup-env.sh / health-check.sh without sudo).
    # Keep permissions strict (600) because it contains secrets.
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown "$SUDO_USER":"$SUDO_USER" "$ENV_FILE" 2>/dev/null || chown "$SUDO_USER" "$ENV_FILE" 2>/dev/null || true
    fi
    log "Environment variables saved to $ENV_FILE"
}

remove_target_deploy_dir() {
    if [ "$ROOT_DIR" = "$SOURCE_ROOT" ]; then
        return 0
    fi

    local target_deploy_dir="$ROOT_DIR/deploy"
    if [ -d "$target_deploy_dir" ] && [ "$target_deploy_dir" != "$DEPLOY_DIR" ]; then
        warn "Removing target-side deploy directory: $target_deploy_dir"
        rm -rf "$target_deploy_dir" || error "Failed to remove target-side deploy directory: $target_deploy_dir"
    fi
}

# Main installation flow
main() {
    log "Starting Ethora Enterprise Deployment"
    log "======================================"
    
    check_sudo
    check_prerequisites
    parse_config
    # Path safety guard: block in-place installs and data-dir collisions BEFORE
    # anything touches files or data. Aborts on a dangerous layout.
    SRC_DIR="$SOURCE_ROOT" TARGET_DIR="$ROOT_DIR" \
      bash "$DEPLOY_DIR/scripts/preflight-paths.sh" \
      $([ "${NON_INTERACTIVE:-false}" = "true" ] && echo --yes) \
      || exit 1
    remove_target_deploy_dir
    ensure_swapfile
    
    # Ask user if they want to clean up previous installations (unless --reset or --cleanup-only is used)
    # In non-interactive mode, skip prompts and proceed with defaults.
    if [ "$RESET_DB" != "true" ] && [ "$CLEANUP_ONLY" != "true" ] && [ "${NON_INTERACTIVE:-false}" != "true" ]; then
        echo
        info "Do you want to clean up any previous installations?"
        info "This will:"
        info "  - Stop all PM2 services (backend, frontend, ai-service, docs-parse-service)"
        info "  - Stop and remove all Ethora Docker containers"
        info "  - Clean MongoDB and MySQL databases (removes all apps, users, and chat history)"
        echo
        read -p "Clean up previous installations? (y/N): " -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "User requested cleanup - performing cleanup before installation..."
            perform_cleanup
        else
            log "Skipping cleanup - proceeding with installation"
        fi
    fi
    
    # Clean database if reset flag is set (do this before validation to ensure DB is ready)
    if [ "$RESET_DB" == "true" ]; then
        warn "WARNING: This will delete all data in:"
        warn "  - MongoDB database: ${MONGO_DB}"
        warn "  - MySQL Ejabberd database (ejabberd_db)"
        warn "This will remove all apps, users, and chat history."
        if [ "${NON_INTERACTIVE:-false}" == "true" ]; then
            log "Non-interactive mode: auto-confirming --reset"
        else
            read -p "Are you sure you want to continue? (yes/no): " -r
            echo
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                log "Aborted by user"
                exit 0
            fi
        fi
        # In --reset mode, do a full cleanup first to free ports and avoid validation prompting
        # to kill random processes. perform_cleanup will:
        # - stop PM2 services (root + user)
        # - stop/remove Ethora containers
        # - start mongo/mysql temporarily, run clean_database (includes MySQL 1045 auto-reinit), then stop containers
        perform_cleanup
    fi
    
    # Run validation (don't source env file yet, validation parses config itself)
    log "Running pre-deployment validation..."
    "$SCRIPT_DIR/validate.sh" || error "Validation failed"
    
    # Check if localhost mode
    local is_localhost=false
    if [ "$API_DOMAIN" == "localhost" ]; then
        is_localhost=true
        log "Localhost mode: Skipping SSL and Nginx setup"
    fi
    
    # Setup SSL certificates (skip for localhost)
    if [ "$is_localhost" != "true" ]; then
        log "Setting up SSL certificates..."
        "$SCRIPT_DIR/setup-ssl.sh" || error "SSL setup failed"
    else
        log "Skipping SSL setup (localhost mode)"
    fi
    
    # Generate environment files
    log "Generating environment files..."
    ensure_runtime_tree_owned_by_deploy_user
    "$SCRIPT_DIR/setup-env.sh" || error "Environment setup failed"
    
    # Setup Ejabberd configuration
    log "Configuring Ejabberd..."
    "$SCRIPT_DIR/xmpp-from-image.sh" || error "ejabberd image mode setup failed"
    "$SCRIPT_DIR/setup-ejabberd-config.sh" || warn "Ejabberd config setup had issues (may be OK)"
    
    # Setup Nginx (skip for localhost)
    if [ "$is_localhost" != "true" ]; then
        log "Configuring Nginx..."
        "$SCRIPT_DIR/setup-nginx.sh" || error "Nginx setup failed"
    else
        log "Skipping Nginx setup (localhost mode - services accessible directly on ports)"
    fi
    
    # Bring down any existing Ethora stack (idempotent)
    # Note: If cleanup was performed above, containers are already stopped
    # compose interpolates the whole file even for `down`, so the fail-closed
    # data vars must be set here too.
    load_data_dir_env
    log "Stopping existing Ethora stack (if any)..."
    docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" down >/dev/null 2>&1 || true

    # Stop and remove other conflicting containers before starting
    log "Checking for conflicting containers..."
    stop_conflicting_containers() {
        local ports=("27017" "3306" "6379" "9000" "8001" "5280" "5443" "8099" "5433")
        local containers_to_stop=()
        local seen_containers=()
        
        # Check for containers using required ports
        for port in "${ports[@]}"; do
            # Use docker ps to find containers using the port
            local container=$(docker ps --format "{{.Names}}" --filter "publish=$port" 2>/dev/null | head -1)
            if [ -n "$container" ]; then
                # Avoid duplicates
                if [[ ! " ${seen_containers[@]} " =~ " ${container} " ]]; then
                    containers_to_stop+=("$container")
                    seen_containers+=("$container")
                fi
            fi
        done
        
        # Check for existing containers with same names (from docker-compose)
        local named_containers=("centrifugo" "crawler-service" "deploy_mongo_1" "deploy_mysql_1" "deploy_redis-server_1" "deploy_minio_1" "deploy_xmpp_1" "deploy_mongosetup_1" "deploy_uptime_1" "deploy_uptime-db_1" "deploy-uptime-1" "deploy-uptime-db-1")
        for name in "${named_containers[@]}"; do
            if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${name}$"; then
                if [[ ! " ${seen_containers[@]} " =~ " ${name} " ]]; then
                    containers_to_stop+=("$name")
                    seen_containers+=("$name")
                fi
            fi
        done
        
        # Also check for any containers with deploy_ prefix that might conflict
        local deploy_containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep "^deploy_" || true)
        if [ -n "$deploy_containers" ]; then
            while IFS= read -r container; do
                if [[ ! " ${seen_containers[@]} " =~ " ${container} " ]]; then
                    containers_to_stop+=("$container")
                    seen_containers+=("$container")
                fi
            done <<< "$deploy_containers"
        fi
        
        # Check for ejabberd-docker containers that might conflict
        local ejabberd_containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep "^ejabberd-docker_" || true)
        if [ -n "$ejabberd_containers" ]; then
            while IFS= read -r container; do
                if [[ ! " ${seen_containers[@]} " =~ " ${container} " ]]; then
                    containers_to_stop+=("$container")
                    seen_containers+=("$container")
                fi
            done <<< "$ejabberd_containers"
        fi
        
        # Stop and remove conflicting containers
        if [ ${#containers_to_stop[@]} -gt 0 ]; then
            log "Found ${#containers_to_stop[@]} conflicting container(s), stopping and removing..."
            for container in "${containers_to_stop[@]}"; do
                log "Stopping container: $container"
                docker stop "$container" 2>/dev/null || true
                docker rm "$container" 2>/dev/null || true
            done
            log "Conflicting containers removed"
        else
            log "No conflicting containers found"
        fi
    }
    
    stop_conflicting_containers
    
    # Stop PM2-managed Ethora services to avoid port conflicts
    log "Stopping PM2 services (if any)..."
    stop_pm2_services() {
        if ! command -v pm2 >/dev/null 2>&1; then
            log "PM2 not installed, skipping PM2 stop"
            return
        fi
        run_pm2_as() {
            local who="$1"
            shift
            if [ "$who" == "root" ]; then
                pm2 "$@" >/dev/null 2>&1
            else
                sudo -u "$who" -H pm2 "$@" >/dev/null 2>&1
            fi
        }

        stop_services_for_user() {
            local who="$1"
            local services=("backend" "frontend" "ai-service" "docs-parse-service" "docs-parse")
            for svc in "${services[@]}"; do
                if run_pm2_as "$who" pid "$svc"; then
                    log "Stopping PM2 service (${who}): $svc"
                    run_pm2_as "$who" stop "$svc" || true
                    run_pm2_as "$who" delete "$svc" || true
                fi
            done
            # Stop the PM2 daemon too (prevents immediate respawn loops on some setups)
            run_pm2_as "$who" kill || true
        }

        # Stop root-owned PM2 (common if previous runs started pm2 under sudo)
        stop_services_for_user "root"
        # Stop user-owned PM2 (preferred)
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
            stop_services_for_user "$SUDO_USER"
        fi
    }
    stop_pm2_services
    
    # Start Docker services
    # Re-load: setup-env.sh has now persisted the authoritative data dirs.
    load_data_dir_env
    log "Starting Docker services..."
    # Change to root directory for docker-compose (volumes are relative to where docker-compose is run)
    cd "$ROOT_DIR"
    # Export paths for docker-compose environment variable substitution
    export BACKEND_DIR
    export BACKEND_DATA_DIR="$BACKEND_DIR/docker/data"
    export EJABBERD_DIR
    export ROOT_DIR
    # Use absolute path for docker-compose file
    # Start docker services. Use compose profiles to avoid starting optional services (e.g. crawler) when AI is disabled.
    COMPOSE_PROFILES=()
    if [ "${CRAWLER_ENABLED:-false}" == "true" ]; then
        COMPOSE_PROFILES+=(--profile ai)
    fi
    docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" "${COMPOSE_PROFILES[@]}" up -d || error "Failed to start Docker services"

    # Drop sentinel READMEs into stateful bind-mount targets (Mongo / MinIO /
    # MySQL). The data paths default to locations nested under submodule dir
    # names, which look like leftover code to operators - the sentinels flag
    # them as live data so any 'ls' / 'find' sees the warning. Idempotent.
    if [ -x "$SCRIPT_DIR/ensure-data-sentinels.sh" ]; then
        bash "$SCRIPT_DIR/ensure-data-sentinels.sh" || true
    fi

    if [ "${AI_SERVICE_ENABLED:-false}" == "true" ]; then
        log "Starting AI embeddings Postgres..."
        "$SCRIPT_DIR/setup-ai-postgres.sh" || error "Failed to provision AI embeddings Postgres"
    fi

    # Optional: start Uptime monitoring stack (helpful for local dev).
    # Note: docker-compose.uptime.yml depends on files generated by setup-env.sh:
    # - $DEPLOY_DIR/generated/uptime/uptime.env
    # - $DEPLOY_DIR/generated/uptime/uptime.yml
    if [ "${UPTIME_ENABLED:-false}" == "true" ] && [ -f "$DEPLOY_DIR/docker-compose.uptime.yml" ]; then
        log "Starting Ethora Uptime docker services..."
        docker-compose -f "$DEPLOY_DIR/docker-compose.uptime.yml" down >/dev/null 2>&1 || true
        # Helper: run a shell command as the deploy user if possible (SUDO_USER), else run as current user.
        run_as_deploy_user_early() {
            local cmd="$1"
            if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
                sudo -u "$SUDO_USER" -H bash -lc "$cmd"
            else
                bash -lc "$cmd"
            fi
        }
        # Uptime Dockerfile expects compiled JS in $UPTIME_DIR/dist. Some checkouts don't ship dist,
        # so build it once on the host before docker build to avoid:
        #   COPY dist ./dist  -> "/dist": not found
        if [ -n "${UPTIME_DIR:-}" ] && [ -d "$UPTIME_DIR" ] && [ -f "$UPTIME_DIR/package.json" ]; then
            if [ ! -f "$UPTIME_DIR/dist/server.js" ]; then
                log "Uptime dist/ is missing; building uptime on host..."
                # Reduce docker build context size if node_modules exists (it will be recreated in Docker build anyway).
                if [ ! -f "$UPTIME_DIR/.dockerignore" ]; then
                    cat >"$UPTIME_DIR/.dockerignore" <<'EOF'
node_modules
.git
.github
npm-debug.log
yarn-error.log
*.log
EOF
                fi
                # Ensure devDependencies are present for the TypeScript build without relying on
                # deprecated npm production flags, and keep install logs focused on actionable errors.
                set +e
                run_as_deploy_user_early "cd \"$UPTIME_DIR\" && npm ci --include=dev --no-audit --no-fund --loglevel=error" \
                  || run_as_deploy_user_early "cd \"$UPTIME_DIR\" && npm install --include=dev --no-audit --no-fund --loglevel=error"
                rc=$?
                set -e
                if [ "$rc" -ne 0 ]; then
                    warn "Failed to install uptime dependencies for host build; uptime container may fail to build."
                else
                    run_as_deploy_user_early "cd \"$UPTIME_DIR\" && npm run build" || warn "Failed to build uptime dist/ on host"
                fi
            fi
        fi
        # Always rebuild uptime on install to avoid stale/broken images (common failure mode: missing express at runtime).
        docker-compose -f "$DEPLOY_DIR/docker-compose.uptime.yml" up -d --build || warn "Failed to start uptime docker services"
    fi
    
    # Wait for core services to be ready
    log "Waiting for core services to be ready..."
    wait_for_service() {
        local name=$1
        local cmd=$2
        local retries=${3:-30}
        local delay=${4:-2}
        local attempt=1
        while [ $attempt -le $retries ]; do
            if eval "$cmd" >/dev/null 2>&1; then
                log "$name is ready (attempt $attempt/$retries)"
                return 0
            fi
            sleep $delay
            attempt=$((attempt+1))
        done

        # Add high-signal diagnostics for the most common failure in the field: xmpp container not reachable.
        if [ "$name" == "Ejabberd" ]; then
            warn "Ejabberd did not become ready. Dumping docker-compose status and last logs for xmpp/mysql..."
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" ps || true
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" logs --tail 200 xmpp mysql || true
            warn "Also check whether port 5280 is listening on the host:"
            warn "  sudo ss -lntp | grep ':5280' || true"
        fi

        error "$name failed to become ready"
    }

    # MySQL password mismatch auto-detection (ejabberd DB).
    # If MySQL has already been initialized (data dir preserved) but MYSQL_ROOT_PASSWORD changed,
    # mysqladmin ping will never succeed and ejabberd will log "init error 1045" and nginx will 502 /ws and /bosh.
    maybe_reinit_ejabberd_mysql_on_auth_mismatch() {
        local mysql_data_dir="$EJABBERD_DIR/docker-data/my-sql"
        local diag=""
        # Only relevant when there is persisted data.
        if [ ! -d "$mysql_data_dir" ] || [ "$(ls -A "$mysql_data_dir" 2>/dev/null | wc -l)" -eq 0 ]; then
            return 1
        fi

        # Try a simple query to detect auth errors explicitly (mysqladmin ping doesn't always surface details).
        diag="$(docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql sh -lc "mysql -uroot -p\"$MYSQL_ROOT_PASSWORD\" -e 'SELECT 1;' 2>&1" || true)"
        if echo "$diag" | grep -qi "Access denied for user"; then
            warn "Detected MySQL root password mismatch for Ejabberd (data dir exists but current MYSQL_ROOT_PASSWORD is rejected)."
            warn "This causes ejabberd to drop /ws and /bosh (nginx 502) with p1_mysql_conn init error 1045."
            warn "MySQL data dir: $mysql_data_dir"
            warn "To fix, we must reinitialize this MySQL data directory (DESTROYS ejabberd chat DB only)."

            local do_reset="false"
            if [ "$RESET_DB" == "true" ]; then
                do_reset="true"
            elif [ -t 0 ]; then
                echo
                read -p "Reinitialize Ejabberd MySQL data dir now? This deletes XMPP chat DB. (y/N): " -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    do_reset="true"
                fi
            fi

            if [ "$do_reset" != "true" ]; then
                warn "Skipping automatic reinit. If you want the installer to auto-fix this, rerun with --reset."
                warn "Or manually wipe: rm -rf \"$mysql_data_dir\"/*  (then restart docker-compose mysql + xmpp)"
                return 0
            fi

            log "Reinitializing Ejabberd MySQL data directory to fix password mismatch..."
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" stop mysql >/dev/null 2>&1 || true
            rm -rf "$mysql_data_dir"/* || true
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" up -d mysql || error "Failed to start MySQL after reinit"
            # MySQL init scripts will run automatically on fresh data dir.
            return 0
        fi

        return 1
    }
    
    wait_for_service "MongoDB" "docker-compose -f \"$DEPLOY_DIR/docker-compose.enterprise.yml\" exec -T mongo mongosh --eval \"db.adminCommand('ping')\" --quiet"
    # MySQL: if it fails due to auth mismatch on a preserved data dir, auto-remediate (interactive prompt or --reset).
    if ! docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql mysqladmin ping -h localhost -p"$MYSQL_ROOT_PASSWORD" --silent >/dev/null 2>&1; then
        maybe_reinit_ejabberd_mysql_on_auth_mismatch || true
    fi
    wait_for_service "MySQL" "docker-compose -f \"$DEPLOY_DIR/docker-compose.enterprise.yml\" exec -T mysql mysqladmin ping -h localhost -p\"$MYSQL_ROOT_PASSWORD\" --silent"
    wait_for_service "Ejabberd" "docker-compose -f \"$DEPLOY_DIR/docker-compose.enterprise.yml\" exec -T xmpp /home/ejabberd/bin/ejabberdctl ping"
    wait_for_service "Centrifugo" "docker-compose -f \"$DEPLOY_DIR/docker-compose.enterprise.yml\" exec -T centrifugo wget --no-verbose --tries=1 --spider http://localhost:8000/" 60 2

    # Backend is a PM2-managed process (not a container). After setup-node-services, we also wait for /ping.
    # This avoids transient nginx 502s if checks run immediately after PM2 restart.
    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsS "http://127.0.0.1:${BACKEND_PORT:-8080}/ping" >/dev/null 2>&1; then
            warn "Backend /ping not responding yet on localhost. This may be normal during first start; nginx may return 502 briefly."
        fi
    fi
    
    # Clean database if reset flag is set (after services are started)
    # Note: This should have been done earlier, but keeping for safety
    if [ "$RESET_DB" == "true" ]; then
        # Database should already be cleaned, but verify
        log "Database cleanup was performed earlier in the installation process"
    fi
    
    # Initialize services
    log "Initializing services..."
    "$SCRIPT_DIR/init-services.sh" || error "Service initialization failed"

    # init-services.sh may discover and persist PLAYGROUND_APP_ID / PLAYGROUND_APP_SECRET
    # after the base app is initialized. Regenerate env templates so uptime picks up
    # ETHORA_B2B_APP_ID / ETHORA_B2B_APP_SECRET automatically on fresh installs.
    log "Regenerating environment files after service initialization..."
    ensure_runtime_tree_owned_by_deploy_user
    "$SCRIPT_DIR/setup-env.sh" || error "Environment setup failed after init-services"

    if [ "${UPTIME_ENABLED:-false}" == "true" ] && [ -f "$DEPLOY_DIR/docker-compose.uptime.yml" ]; then
        log "Refreshing Ethora Uptime docker services after env regeneration..."
        # Changes inside generated uptime env/config files do not reliably trigger recreation,
        # so force-recreate the uptime service after setup-env.sh refreshes them.
        docker-compose -f "$DEPLOY_DIR/docker-compose.uptime.yml" up -d --build --force-recreate uptime || warn "Failed to refresh uptime docker services after env regeneration"
    fi
    
    # Build and start Node.js services
    log "Building and starting Node.js services..."
    "$SCRIPT_DIR/setup-node-services.sh" || error "Node.js services setup failed"

    # Re-load env after setup-node-services.sh: it may update values like FRONTEND_PORT
    if [ -f "$DEPLOY_DIR/.deploy.env" ]; then
        # shellcheck disable=SC1090
        source "$DEPLOY_DIR/.deploy.env"
    fi

    # Data migrations. A fresh install has nothing to migrate and this is a
    # cheap no-op that stamps the registry, so the first update.sh run does not
    # re-scan. It earns its place on an install over *existing* data: a restore
    # from a stateful snapshot, or a --reinstall that keeps the databases, both
    # arrive here with rows that predate the current schema.
    if [ -f "$SCRIPT_DIR/run-migrations.sh" ]; then
        log "Running data migrations (idempotent)..."
        "$SCRIPT_DIR/run-migrations.sh" || warn "Data migrations reported a failure; re-run: sudo bash $SCRIPT_DIR/run-migrations.sh"
    fi

    # Run health checks
    log "Running health checks..."
    "$SCRIPT_DIR/health-check.sh" || warn "Some health checks failed"

    # Advisory config-gap report (never fails the install).
    if [ -f "$SCRIPT_DIR/report-config-gaps.sh" ]; then
        ROOT_DIR="$ROOT_DIR" DEPLOY_DIR="${DEPLOY_DIR:-$SCRIPT_DIR/..}" \
            bash "$SCRIPT_DIR/report-config-gaps.sh" || true
    fi

    # Display access information
    log "======================================"
    log "Deployment completed successfully!"
    log "======================================"
    echo
    info "Access Information:"
    if [ "$API_DOMAIN" == "localhost" ]; then
        detect_frontend_port() {
            # Prefer configured/stored port first.
            if [ -n "${FRONTEND_PORT:-}" ]; then
                echo "$FRONTEND_PORT"
                return 0
            fi

            # Detect a running dev server: check the common Vite ports in order.
            for p in 5173 5174 5175 5176 5177; do
                if command -v ss >/dev/null 2>&1; then
                    if ss -ltn "( sport = :$p )" 2>/dev/null | grep -q ":$p"; then
                        echo "$p"
                        return 0
                    fi
                elif command -v lsof >/dev/null 2>&1; then
                    if lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
                        echo "$p"
                        return 0
                    fi
                fi
            done

            # Fallback: default Vite port.
            echo "5173"
        }

        local_frontend_port="$(detect_frontend_port)"
        echo "  API: http://localhost:${BACKEND_PORT}"
        echo "  API Docs (Swagger): http://localhost:${BACKEND_PORT}/api-docs/"
        echo "  Web App (Frontend): http://localhost:${local_frontend_port}"
        if [ "$local_frontend_port" != "5173" ]; then
            echo "    (note: Vite moved off 5173 because it was busy)"
        fi
        echo "  XMPP: localhost (http://localhost:5280 or https://localhost:5443)"
        echo "  Files: http://localhost:9000 (API), http://localhost:9001 (Console)"
        if [ "${UPTIME_ENABLED:-false}" == "true" ]; then
            echo "  Uptime: http://localhost:${UPTIME_PORT}"
        fi
        if [ "${PLAYGROUND_ENABLED:-false}" == "true" ]; then
            echo "  SDK Playground: http://localhost:${PLAYGROUND_PORT:-3020}"
        fi
        if [ "${MCP_ENABLED:-false}" == "true" ]; then
            echo "  MCP server: http://localhost:${MCP_PORT:-3030}/mcp"
        fi
        echo "  MinIO Console: http://localhost:9001 (user: ${MINIO_ROOT_USER}, pass: ${MINIO_ROOT_PASSWORD})"
    else
        echo "  API: https://$API_DOMAIN"
        echo "  API Docs (Swagger): https://$API_DOMAIN/api-docs/"
        echo "  Web App: https://$WEB_DOMAIN"
        echo "  XMPP: $XMPP_DOMAIN"
        echo "  Files: https://$FILES_DOMAIN"
        # Uptime is optional in production. Prefer the configured uptime domain if provided.
        if [ "${UPTIME_ENABLED:-false}" == "true" ]; then
            if [ -n "${UPTIME_DOMAIN:-}" ] && [ "${UPTIME_DOMAIN:-}" != "null" ] && [ "${UPTIME_DOMAIN:-}" != "localhost" ]; then
                echo "  Uptime: https://${UPTIME_DOMAIN}"
            else
                echo "  Uptime: http://localhost:${UPTIME_PORT}"
            fi
        fi
        if [ "${PLAYGROUND_ENABLED:-false}" == "true" ] && [ -n "${PLAYGROUND_DOMAIN:-}" ] && [ "${PLAYGROUND_DOMAIN:-}" != "null" ]; then
            echo "  SDK Playground: https://${PLAYGROUND_DOMAIN}"
        fi
        if [ "${MCP_ENABLED:-false}" == "true" ] && [ -n "${MCP_DOMAIN:-}" ] && [ "${MCP_DOMAIN:-}" != "null" ]; then
            echo "  MCP server: https://${MCP_DOMAIN}/mcp"
        fi
        if [ "${WIDGET_ENABLED:-false}" == "true" ] && [ -n "${WIDGET_DOMAIN:-}" ] && [ "${WIDGET_DOMAIN:-}" != "null" ]; then
            if [ -n "${WIDGET_SCRIPT_VERSION:-}" ]; then
                echo "  Widget: https://${WIDGET_DOMAIN}/assistant${WIDGET_SCRIPT_VERSION}.js"
            else
                echo "  Widget: https://${WIDGET_DOMAIN}/assistant.js"
            fi
        fi
        if [ "${HOSTED_APPS_ENABLED:-false}" == "true" ] && [ -n "${HOSTED_APPS_ROOT_DOMAIN:-}" ] && [ "${HOSTED_APPS_ROOT_DOMAIN:-}" != "null" ]; then
            echo "  Hosted apps root: *.${HOSTED_APPS_ROOT_DOMAIN}"
        fi
    fi
    echo
    info "Admin Credentials:"
    echo "  Email: $ADMIN_EMAIL"
    echo "  Password: [as configured in deploy.yml]"
    if [ "$XMPP_DOMAIN" == "localhost" ]; then
        echo "  Ejabberd Admin: admin@localhost / $XMPP_ADMIN_PASSWORD"
    else
        echo "  Ejabberd Admin: admin@$XMPP_DOMAIN / $XMPP_ADMIN_PASSWORD"
    fi
    echo
    info "Configuration saved to: $CONFIG_FILE"
    info "Log file: $LOG_FILE"
    echo
    if [ "$API_DOMAIN" == "localhost" ]; then
        info "Quick Test:"
        echo "  curl http://localhost:${BACKEND_PORT}/ping"
        echo "  ./scripts/health-check.sh"
    fi
    echo
}

# Perform complete cleanup (services, containers, databases)
# This function can be called from interactive prompt or --cleanup-only mode
perform_cleanup() {
    load_data_dir_env
    log "Performing complete cleanup..."

    # Re-load environment in case the caller environment is missing required vars.
    # This is important because docker-compose.enterprise.yml references variables like BACKEND_DIR,
    # EJABBERD_DIR, MYSQL_ROOT_PASSWORD, MINIO_ROOT_PASSWORD, etc. If they are missing, docker-compose
    # may fail to even start mongo/mysql (and then the cleanup DB wait loops will fail).
    if [ -f "$DEPLOY_DIR/.deploy.env" ]; then
        # shellcheck disable=SC1090
        source "$DEPLOY_DIR/.deploy.env"
    fi
    
    # Step 1: Stop PM2 services
    log "Stopping PM2 services..."
    if command -v pm2 >/dev/null 2>&1; then
        run_pm2_as() {
            local who="$1"
            shift
            if [ "$who" == "root" ]; then
                pm2 "$@" >/dev/null 2>&1
            else
                sudo -u "$who" -H pm2 "$@" >/dev/null 2>&1
            fi
        }

        stop_services_for_user() {
            local who="$1"
            local services=("backend" "frontend" "ai-service" "docs-parse-service" "docs-parse")
            for svc in "${services[@]}"; do
                if run_pm2_as "$who" pid "$svc"; then
                    log "Stopping PM2 service (${who}): $svc"
                    run_pm2_as "$who" stop "$svc" || true
                    run_pm2_as "$who" delete "$svc" || true
                fi
            done
            run_pm2_as "$who" kill || true
        }

        stop_services_for_user "root"
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
            stop_services_for_user "$SUDO_USER"
        fi
        log "PM2 services stopped"
    else
        log "PM2 not installed, skipping PM2 services"
    fi
    
    # Step 2: Stop and remove Docker containers
    log "Stopping Docker containers..."
    cd "$ROOT_DIR" || error "Failed to change to root directory"
    
    # Stop Ethora stack
    if [ -f "$DEPLOY_DIR/docker-compose.enterprise.yml" ]; then
        log "Stopping Ethora Docker stack..."
        docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" down -v >/dev/null 2>&1 || warn "Failed to stop some containers (may not exist)"
    fi

    # Stop Uptime stack (so we don't leave orphan containers around after cleanup/reset).
    if [ -f "$DEPLOY_DIR/docker-compose.uptime.yml" ]; then
        log "Stopping Ethora Uptime Docker stack..."
        docker-compose -f "$DEPLOY_DIR/docker-compose.uptime.yml" down -v >/dev/null 2>&1 || warn "Failed to stop uptime containers (may not exist)"
    fi

    if [ -f "$DEPLOY_DIR/docker-compose.ai.yml" ]; then
        log "Stopping AI Postgres Docker stack..."
        docker-compose -f "$DEPLOY_DIR/docker-compose.ai.yml" down -v >/dev/null 2>&1 || warn "Failed to stop AI Postgres containers (may not exist)"
    fi
    
    # Stop conflicting containers
    log "Stopping conflicting containers..."
    ports=("27017" "3306" "6379" "9000" "8001" "5280" "5443" "8099" "5433" "${AI_POSTGRES_PORT:-5434}")
    containers_to_stop=()
    seen_containers=()
    
    for port in "${ports[@]}"; do
        container=$(docker ps --format "{{.Names}}" --filter "publish=$port" 2>/dev/null | head -1)
        if [ -n "$container" ]; then
            if [[ ! " ${seen_containers[@]} " =~ " ${container} " ]]; then
                containers_to_stop+=("$container")
                seen_containers+=("$container")
            fi
        fi
    done
    
    named_containers=("centrifugo" "crawler-service" "deploy_mongo_1" "deploy_mysql_1" "deploy_redis-server_1" "deploy_minio_1" "deploy_xmpp_1" "deploy_mongosetup_1" "deploy_uptime_1" "deploy_uptime-db_1" "deploy-uptime-1" "deploy-uptime-db-1" "deploy_ai-postgres_1" "deploy-ai-postgres-1")
    for name in "${named_containers[@]}"; do
        if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${name}$"; then
            if [[ ! " ${seen_containers[@]} " =~ " ${name} " ]]; then
                containers_to_stop+=("$name")
                seen_containers+=("$name")
            fi
        fi
    done
    
    deploy_containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep "^deploy_" || true)
    if [ -n "$deploy_containers" ]; then
        while IFS= read -r container; do
            if [[ ! " ${seen_containers[@]} " =~ " ${container} " ]]; then
                containers_to_stop+=("$container")
                seen_containers+=("$container")
            fi
        done <<< "$deploy_containers"
    fi
    
    ejabberd_containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep "^ejabberd-docker_" || true)
    if [ -n "$ejabberd_containers" ]; then
        while IFS= read -r container; do
            if [[ ! " ${seen_containers[@]} " =~ " ${container} " ]]; then
                containers_to_stop+=("$container")
                seen_containers+=("$container")
            fi
        done <<< "$ejabberd_containers"
    fi
    
    if [ ${#containers_to_stop[@]} -gt 0 ]; then
        log "Found ${#containers_to_stop[@]} container(s) to stop and remove..."
        for container in "${containers_to_stop[@]}"; do
            log "Stopping and removing container: $container"
            docker stop "$container" >/dev/null 2>&1 || true
            docker rm "$container" >/dev/null 2>&1 || true
        done
        log "Containers stopped and removed"
    else
        log "No containers found to stop"
    fi
    
    # Step 3: Start Docker services temporarily for database cleanup
    log "Starting Docker services temporarily for database cleanup..."
    # Ensure critical paths are set for docker-compose file parsing (even when only starting mongo/mysql).
    export BACKEND_DIR="${BACKEND_DIR:-$ROOT_DIR/ethora-backend}"
    export EJABBERD_DIR="${EJABBERD_DIR:-$ROOT_DIR/ejabberd-docker}"
    export BACKEND_DATA_DIR="${BACKEND_DATA_DIR:-${BACKEND_DIR}/docker/data}"

    if ! docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" up -d mongo mysql; then
        warn "Failed to start Docker services for cleanup. Showing docker-compose ps/logs for diagnostics:"
        docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" ps || true
        docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" logs --tail 120 mongo mysql 2>/dev/null || true
        error "Cannot continue cleanup: MongoDB/MySQL did not start"
    fi
    sleep 5
    
    # Step 4: Clean databases
    clean_database
    
    # Step 5: Stop Docker services again
    log "Stopping Docker services after cleanup..."
    docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" down >/dev/null 2>&1 || true
    
    log "Cleanup completed successfully"
}

# Clean databases (removes all apps, users, and XMPP data)
clean_database() {
    log "Cleaning databases..."

    # Ensure mongo/mysql are running for cleanup. In --reset mode we may reach this function
    # before the main docker-compose up happens, so exec/ping would fail with no containers.
    log "Starting MongoDB/MySQL containers for database cleanup (if not already running)..."
    # Ensure critical paths are set for docker-compose env substitution.
    export BACKEND_DIR="${BACKEND_DIR:-$ROOT_DIR/ethora-backend}"
    export EJABBERD_DIR="${EJABBERD_DIR:-$ROOT_DIR/ejabberd-docker}"
    export BACKEND_DATA_DIR="${BACKEND_DATA_DIR:-${BACKEND_DIR}/docker/data}"
    if ! docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" up -d mongo mysql; then
        warn "Failed to start MongoDB/MySQL for cleanup. Diagnostics:"
        docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" ps || true
        docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" logs --tail 120 mongo mysql 2>/dev/null || true
        error "Cannot continue cleanup: MongoDB/MySQL did not start"
    fi
    sleep 3
    
    # Wait for MongoDB to be ready
    log "Waiting for MongoDB to be ready..."
    for i in {1..30}; do
        if docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mongo mongosh --eval "db.adminCommand('ping')" --quiet > /dev/null 2>&1; then
            log "MongoDB is ready"
            break
        fi
        if [ $i -eq 30 ]; then
            warn "MongoDB failed to start. Diagnostics:"
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" ps mongo || true
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" logs --tail 120 mongo 2>/dev/null || true
            error "MongoDB failed to start"
        fi
        sleep 2
    done
    
    # Drop MongoDB database
    log "Dropping MongoDB database: ${MONGO_DB}"
    docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mongo mongosh --eval "
        use ${MONGO_DB};
        db.dropDatabase();
    " --quiet || warn "Failed to drop MongoDB database (may not exist)"
    
    # Wait for MySQL to be ready
    log "Waiting for MySQL to be ready..."
    for i in {1..30}; do
        if docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql mysqladmin ping -h localhost -p"$MYSQL_ROOT_PASSWORD" --silent > /dev/null 2>&1; then
            log "MySQL is ready"
            break
        fi
        if [ $i -eq 30 ]; then
            warn "MySQL failed to start, skipping MySQL cleanup"
            log "Databases cleaned successfully (MongoDB only)"
            return
        fi
        sleep 2
    done

    # Verify that the current MYSQL_ROOT_PASSWORD actually works. This catches the common case where the
    # MySQL data dir is persisted but the env password changed (1045). In --reset mode it's safe to
    # reinitialize the ejabberd MySQL data dir automatically (it already implies wiping chat history).
    mysql_auth_diag="$(docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql sh -lc "mysql -uroot -p\"$MYSQL_ROOT_PASSWORD\" -e 'SELECT 1;' 2>&1" || true)"
    if echo "$mysql_auth_diag" | grep -qi "Access denied for user"; then
        warn "MySQL is running but root authentication failed with the current MYSQL_ROOT_PASSWORD (1045)."
        warn "This typically happens when the MySQL data directory was already initialized with a different root password."
        if [ "$RESET_DB" == "true" ]; then
            log "Reset mode: reinitializing Ejabberd MySQL data directory to restore password alignment..."
            mysql_data_dir="$EJABBERD_DIR/docker-data/my-sql"
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" stop mysql >/dev/null 2>&1 || true
            rm -rf "$mysql_data_dir"/* || true
            docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" up -d mysql || error "Failed to start MySQL after reinit"
            sleep 5
            # Wait for MySQL again
            for i in {1..30}; do
                if docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql mysqladmin ping -h localhost -p"$MYSQL_ROOT_PASSWORD" --silent > /dev/null 2>&1; then
                    log "MySQL is ready after reinit"
                    break
                fi
                if [ $i -eq 30 ]; then
                    warn "MySQL did not become ready after reinit. Diagnostics:"
                    docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" ps mysql || true
                    docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" logs --tail 120 mysql 2>/dev/null || true
                    error "MySQL failed to start after reinit"
                fi
                sleep 2
            done
        else
            warn "Not in --reset mode; refusing to wipe MySQL data dir automatically."
            warn "To fix: set databases.mysql.root_password in deploy.yml to the original value, or wipe $EJABBERD_DIR/docker-data/my-sql/*"
            warn "Raw MySQL auth error output:"
            warn "$mysql_auth_diag"
            return
        fi
    fi
    
    # Drop MySQL Ejabberd database
    log "Dropping MySQL Ejabberd database..."
    docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS ejabberd_db;" 2>/dev/null || warn "Failed to drop MySQL database (may not exist)"

    # IMPORTANT: Ejabberd will fail to start (and WS handshake will reset) if ejabberd_db doesn't exist.
    # Recreate ejabberd_db + schema using the init SQL that is mounted into the mysql container.
    log "Recreating MySQL Ejabberd database and schema..."
    # Retry a few times to avoid flakiness right after container init.
    schema_ok=false
    for i in {1..5}; do
        if docker-compose -f "$DEPLOY_DIR/docker-compose.enterprise.yml" exec -T mysql sh -lc "mysql -uroot -p\"$MYSQL_ROOT_PASSWORD\" < /docker-entrypoint-initdb.d/01.sql" >/dev/null 2>&1; then
            schema_ok=true
            break
        fi
        sleep 2
    done
    if [ "$schema_ok" != "true" ]; then
        warn "Failed to recreate MySQL ejabberd_db schema after retries (XMPP may not start)"
    fi
    
    log "Databases cleaned successfully (MongoDB and MySQL)"
}

# Parse command line arguments
RESET_DB=false
CLEANUP_ONLY=false
REINSTALL=false
NON_INTERACTIVE=false
FORCE_REINSTALL=false
CONFIG_BASE_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset|--clean)
            RESET_DB=true
            ;;
        --cleanup-only|--clean-databases)
            CLEANUP_ONLY=true
            ;;
        --reinstall|--clean-reinstall|--fresh-reinstall)
            REINSTALL=true
            ;;
        --yes|--non-interactive)
            NON_INTERACTIVE=true
            ;;
        --base-dir)
            CONFIG_BASE_DIR_OVERRIDE="${2:-}"
            shift
            ;;
        --force)
            FORCE_REINSTALL=true
            ;;
    esac
    shift
done

if [ "$RESET_DB" == "true" ]; then
    log "Reset mode enabled - will clean MongoDB and MySQL databases"
fi
if [ "$CLEANUP_ONLY" == "true" ]; then
    log "Cleanup-only mode enabled - will only clean databases, then exit"
fi

safe_delete_root_dir() {
    local target="$1"
    if [ -z "$target" ]; then
        error "safe_delete_root_dir: missing target dir"
    fi
    if [ "$target" == "/" ] || [ "$target" == "/root" ] || [ "$target" == "/home" ]; then
        error "Refusing to delete unsafe directory: $target"
    fi
    # Don't allow deleting the repo itself (installer source).
    if [ "$target" == "$DEFAULT_ROOT_DIR" ] || [ "$target" == "$DEPLOY_DIR" ] || [ "$target" == "$(cd "$DEPLOY_DIR/.." && pwd)" ]; then
        error "Refusing to delete the installer source directory: $target. Use paths.base (or --base-dir) to point to a separate target dir."
    fi

    if [ -d "$target" ]; then
        # IMPORTANT:
        # If the current working directory is inside the target directory, deleting it will make
        # subsequent commands (including rsync) fail with: getcwd(): No such file or directory.
        # Always move to a safe directory before removing the target.
        cd / || true

        # Safety: only allow deletion if it looks like an Ethora install target, unless --force is provided.
        if [ "$FORCE_REINSTALL" != "true" ]; then
            if [ ! -d "$target/ethora-backend" ] && [ ! -d "$target/ejabberd-docker" ] && [ ! -d "$target/ethora-app-reactjs" ] && [ ! -d "$target/ethora-uptime" ]; then
                error "Refusing to delete $target because it doesn't look like an Ethora install directory. Re-run with --force if you're sure."
            fi
        fi
        warn "Deleting target directory: $target"
        rm -rf "$target" || error "Failed to delete target directory: $target"
    fi
    mkdir -p "$target" || error "Failed to recreate target directory: $target"
}

reinstall_flow() {
    check_sudo
    check_prerequisites

    # For reinstall, always run non-interactively (no prompts).
    NON_INTERACTIVE=true

    # Avoid deleting the directory we are currently in (or any parent).
    # Always execute reinstall steps from a stable location.
    cd "$DEPLOY_DIR" || cd / || true

    parse_config

    log "Reinstall mode enabled - performing clean reinstall"
    log "  Target base directory: $ROOT_DIR"

    # 1) Stop services + remove containers + clean databases (best-effort)
    perform_cleanup

    # 2) Delete target base directory contents (removes docker-data dirs and service folders)
    safe_delete_root_dir "$ROOT_DIR"

    # Ensure we are not inside the deleted directory before continuing.
    cd "$DEPLOY_DIR" || cd / || true

    # 3) Run the normal install flow (non-interactive; will regenerate env and start services)
    RESET_DB=false
    CLEANUP_ONLY=false
    main
}

if [ "$REINSTALL" == "true" ]; then
    reinstall_flow
    exit 0
fi

# If cleanup-only mode, run cleanup and exit
if [ "$CLEANUP_ONLY" == "true" ]; then
    check_sudo
    log "Starting complete cleanup"
    log "======================================"
    
    # Source environment if .deploy.env exists
    if [ -f "$DEPLOY_DIR/.deploy.env" ]; then
        source "$DEPLOY_DIR/.deploy.env"
        log "Loaded environment from .deploy.env"
    else
        # Try to parse config to get database names
        if [ -f "$DEPLOY_DIR/config/deploy.yml" ]; then
            if ! command -v yq &> /dev/null; then
                error "yq is required for cleanup. Please install it or run the full installer first."
            fi
            export MONGO_DB=$(yq eval '.databases.mongo.database' "$DEPLOY_DIR/config/deploy.yml")
            export MYSQL_ROOT_PASSWORD=$(yq eval '.databases.mysql.root_password' "$DEPLOY_DIR/config/deploy.yml")
            # Get paths from config
            CONFIG_BASE_DIR=$(yq eval '.paths.base' "$DEPLOY_DIR/config/deploy.yml" 2>/dev/null || echo "")
            if [ -n "$CONFIG_BASE_DIR" ] && [ "$CONFIG_BASE_DIR" != "null" ]; then
                ROOT_DIR="$(cd "$CONFIG_BASE_DIR" && pwd)"
            else
                ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
            fi
            export ROOT_DIR
            export BACKEND_DIR="$ROOT_DIR/ethora-backend"
            export FRONTEND_DIR="$ROOT_DIR/ethora-app-reactjs"
            log "Loaded database config from deploy.yml"
        else
            # Use defaults
            ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
            export ROOT_DIR
            export BACKEND_DIR="$ROOT_DIR/ethora-backend"
            export FRONTEND_DIR="$ROOT_DIR/ethora-app-reactjs"
            export MONGO_DB="ethora_prod"
            warn "No .deploy.env or deploy.yml found. Using default paths and database names."
        fi
    fi
    
    warn "WARNING: This will:"
    warn "  1. Stop all PM2 services (backend, frontend, ai-service, docs-parse-service)"
    warn "  2. Stop and remove all Ethora Docker containers"
    warn "  3. Delete all data in:"
    warn "     - MongoDB database: ${MONGO_DB:-ethora_prod}"
    warn "     - MySQL Ejabberd database (ejabberd_db)"
    warn "This will remove all apps, users, and chat history."
    if [ "${NON_INTERACTIVE:-false}" == "true" ]; then
        log "Non-interactive mode: auto-confirming --cleanup-only"
    else
        read -p "Are you sure you want to continue? (yes/no): " -r
        echo
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log "Aborted by user"
            exit 0
        fi
    fi
    
    # Perform cleanup using the shared function
    perform_cleanup
    
    log "======================================"
    log "Complete cleanup finished successfully!"
    log "All services stopped, containers removed, and databases cleaned."
    log "You can now run: sudo ./scripts/install.sh"
    exit 0
fi

# Run main function
main "$@"
