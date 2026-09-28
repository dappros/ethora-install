#!/usr/bin/env bash
# Sourceable helper: guarantees the stateful data-dir variables are exported and
# absolute before anything runs docker compose.
#
# Every data volume in docker-compose.enterprise.yml is fail-closed
# (${MONGO_DATA_DIR:?...}). That is deliberate: a relative default is how live
# data ended up inside the git tree, and how a deploy silently brought a database
# up on the wrong copy. The cost is that compose refuses to interpolate the file
# at all - even for `down`, `ps` or `logs` - unless all four are set. Scripts that
# shell out to compose therefore have to load them first, including when they are
# run standalone (health-check.sh, maintain.sh, init-services.sh) or before
# setup-env.sh has ever written .deploy.env (install.sh teardown/cleanup).
#
# Precedence, matching setup-env.sh:
#   1. already set in the environment (operator override)
#   2. deploy/.deploy.env (what setup-env.sh persisted)
#   3. $DATA_DIR/<service>, default $HOME/ethora-data/<service>
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/load-data-env.sh"
#   ethora_load_data_env            # optionally: ethora_load_data_env /path/to/deploy
#
# Keep the default in sync with setup-env.sh (NEW_DATA_ROOT), preflight-paths.sh
# and migrate-data-paths.sh.

# The invoking user's home, even under sudo (which may set HOME=/root).
_ethora_deploy_home() {
    getent passwd "${SUDO_USER:-${USER:-}}" 2>/dev/null | cut -d: -f6 | grep . || echo "${HOME:-/root}"
}

ethora_load_data_env() {
    local deploy_dir="${1:-${DEPLOY_DIR:-}}"
    if [ -z "$deploy_dir" ]; then
        deploy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    fi

    # Read .deploy.env in a subshell and take ONLY these five values. Sourcing it
    # into the caller would also clobber ROOT_DIR/SOURCE_ROOT/domains/secrets with
    # a previous install's values, which install.sh has already resolved from
    # deploy.yml by the time it needs this.
    local env_file="$deploy_dir/.deploy.env"
    local persisted="" line i=0
    if [ -f "$env_file" ]; then
        persisted="$(
            # shellcheck disable=SC1090
            source "$env_file" >/dev/null 2>&1
            printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
                "${DATA_DIR:-}" "${MONGO_DATA_DIR:-}" "${MINIO_DATA_DIR:-}" \
                "${MYSQL_DATA_DIR:-}" "${REDIS_DATA_DIR:-}" "${MINIO_IMAGE:-}"
        )" || persisted=""
    fi

    local names=(DATA_DIR MONGO_DATA_DIR MINIO_DATA_DIR MYSQL_DATA_DIR REDIS_DATA_DIR MINIO_IMAGE)
    while IFS= read -r line; do
        [ "$i" -lt "${#names[@]}" ] || break
        # Only fill in what the environment has not already set.
        if [ -n "$line" ] && [ -z "$(eval "printf '%s' \"\${${names[$i]}:-}\"")" ]; then
            eval "${names[$i]}=\$line"
        fi
        i=$((i + 1))
    done <<< "$persisted"

    DATA_DIR="${DATA_DIR:-$(_ethora_deploy_home)/ethora-data}"
    : "${MONGO_DATA_DIR:=$DATA_DIR/mongo}"
    : "${MINIO_DATA_DIR:=$DATA_DIR/minio}"
    : "${MYSQL_DATA_DIR:=$DATA_DIR/mysql}"
    : "${REDIS_DATA_DIR:=$DATA_DIR/redis}"
    export DATA_DIR MONGO_DATA_DIR MINIO_DATA_DIR MYSQL_DATA_DIR REDIS_DATA_DIR
    export MINIO_IMAGE="${MINIO_IMAGE:-docker.io/dappros/minio:RELEASE.2025-09-07T16-13-09Z}"

    local var val
    for var in MONGO_DATA_DIR MINIO_DATA_DIR MYSQL_DATA_DIR REDIS_DATA_DIR; do
        eval "val=\${$var}"
        case "$val" in
            /*) ;;
            *)
                echo "[ERROR] $var must be an absolute path, got: '$val'." >&2
                echo "[ERROR] Set it in $env_file, or unset it to use \$DATA_DIR/<service>." >&2
                return 1
                ;;
        esac
    done
}
