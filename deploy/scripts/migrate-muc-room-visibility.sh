#!/bin/bash

# Migrate MUC room visibility: hide existing rooms from Service Discovery.
#
# New rooms already default to public:false / public_list:false via
# default_room_options in ejabberd.yml (see the ejabberd-docker config). That
# default only applies to rooms created AFTER the config change, so rooms that
# already existed keep their stored public:true / public_list:true flags and
# stay listed in the MUC service disco#items (JID, name and occupant list
# exposed, even for members-only group rooms).
#
# This script walks every existing room and sets both flags to false via
# `ejabberdctl change_room_option`. It is idempotent: a room already set to
# false is left untouched (no write), so re-running is safe and cheap.
#
# Run standalone (as the deploy user / root that owns docker):
#   sudo bash deploy/scripts/migrate-muc-room-visibility.sh
#
# update.sh calls it once (guarded by a stamp) after init-services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

warn() {
    echo "[WARN] $1" >&2
}

# Find the running Ejabberd container (same resolution order as init-services.sh:
# default compose names first, then the compose service label as a fallback).
get_xmpp_container() {
    if docker ps --format '{{.Names}}' | grep -q '^deploy_xmpp_1$'; then
        echo "deploy_xmpp_1"; return 0
    fi
    if docker ps --format '{{.Names}}' | grep -q '^deploy-xmpp-1$'; then
        echo "deploy-xmpp-1"; return 0
    fi
    local by_label
    by_label="$(docker ps --filter 'label=com.docker.compose.service=xmpp' --format '{{.Names}}' | head -n 1)"
    if [ -n "$by_label" ]; then
        echo "$by_label"; return 0
    fi
    return 1
}

XMPP_CONTAINER=""

# Run an ejabberdctl command with a short timeout so a wedged node can't hang
# the whole update. stdin from /dev/null for the same reason as init-services.sh
# (docker exec -i under a backgrounded `timeout` earns SIGTTIN on a tty read).
ejabberdctl() {
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 1s 15s docker exec -i "$XMPP_CONTAINER" /home/ejabberd/bin/ejabberdctl "$@" </dev/null
    else
        docker exec -i "$XMPP_CONTAINER" /home/ejabberd/bin/ejabberdctl "$@" </dev/null
    fi
}

# List every room JID ("name@service"), one per line.
#
# `muc_online_rooms global` is the obvious call but needs the "global scope"
# API permission, which is not granted to ejabberdctl under the stock
# api_permissions (it raises "no case clause matching global_scope" and exits
# non-zero). So try global first and, if it is not permitted, fall back to
# listing each registered vhost's MUC service explicitly. The default MUC
# service prefix is "conference." (ejabberd's default and what Ethora uses);
# override via EJABBERD_MUC_PREFIX for a non-standard mod_muc host.
list_rooms() {
    local out rc
    # `if` so a non-zero exit here does not trip `set -e` before we can fall back.
    if out="$(ejabberdctl muc_online_rooms global 2>/dev/null)"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi 'exception'; then
        printf '%s\n' "$out"
        return 0
    fi

    local vhosts v prefix="${EJABBERD_MUC_PREFIX:-conference.}"
    vhosts="$(ejabberdctl registered_vhosts 2>/dev/null | sed '/^[[:space:]]*$/d')"
    [ -z "$vhosts" ] && return 1
    for v in $vhosts; do
        ejabberdctl muc_online_rooms "${prefix}${v}" 2>/dev/null || true
    done
}

# Read one room option's current value (empty if absent / unreadable).
# get_room_options prints one "name<whitespace>value" per line; match the name
# exactly so `public` does not also match `public_list`.
room_option() {
    local room="$1" service="$2" opt="$3"
    ejabberdctl get_room_options "$room" "$service" 2>/dev/null \
        | awk -v o="$opt" '$1==o {print $2; exit}'
}

main() {
    echo "============================================================"
    log "Migrating MUC room visibility: hiding existing rooms from discovery"
    log "  (setting public=false and public_list=false on every room)"
    echo "============================================================"

    if ! command -v docker >/dev/null 2>&1; then
        warn "docker not found on PATH; cannot reach ejabberd. Skipping."
        return 1
    fi

    if ! XMPP_CONTAINER="$(get_xmpp_container)"; then
        warn "No running xmpp container found; cannot migrate rooms now."
        warn "Re-run once ejabberd is up: sudo bash $SCRIPT_DIR/migrate-muc-room-visibility.sh"
        return 1
    fi
    log "Using ejabberd container: $XMPP_CONTAINER"

    if ! ejabberdctl status >/dev/null 2>&1; then
        warn "ejabberd is not responding (ejabberdctl status failed). Skipping for now."
        return 1
    fi

    # Enumerate rooms. Ethora rooms are persistent with preload_rooms: true, so
    # every persistent room is loaded at startup and shows up here.
    local rooms
    rooms="$(list_rooms | sed '/^[[:space:]]*$/d')" || true

    local total=0 changed=0 already=0 failed=0

    if [ -z "$rooms" ]; then
        log "No MUC rooms found. Nothing to migrate."
        echo "------------------------------------------------------------"
        log "MUC room visibility migration: 0 rooms, nothing to do."
        echo "------------------------------------------------------------"
        return 0
    fi

    while IFS= read -r jid; do
        [ -z "$jid" ] && continue
        total=$((total + 1))

        # jid is "name@service"; split on the first '@'.
        local room="${jid%%@*}"
        local service="${jid#*@}"
        if [ -z "$room" ] || [ -z "$service" ] || [ "$service" = "$jid" ]; then
            warn "Skipping unparseable room JID: '$jid'"
            failed=$((failed + 1))
            continue
        fi

        local cur_public cur_list
        cur_public="$(room_option "$room" "$service" public || true)"
        cur_list="$(room_option "$room" "$service" public_list || true)"

        local need_public="false" need_list="false"
        if [ "$cur_public" != "false" ]; then need_public="true"; fi
        if [ "$cur_list" != "false" ]; then need_list="true"; fi

        if [ "$need_public" = "false" ] && [ "$need_list" = "false" ]; then
            already=$((already + 1))
            continue
        fi

        local ok="true"
        if [ "$need_public" = "true" ]; then
            if ! ejabberdctl change_room_option "$room" "$service" public false >/dev/null 2>&1; then
                ok="false"
            fi
        fi
        if [ "$need_list" = "true" ]; then
            if ! ejabberdctl change_room_option "$room" "$service" public_list false >/dev/null 2>&1; then
                ok="false"
            fi
        fi

        if [ "$ok" = "true" ]; then
            changed=$((changed + 1))
            log "  hidden: $jid"
        else
            failed=$((failed + 1))
            warn "  failed to update: $jid"
        fi
    done <<< "$rooms"

    echo "------------------------------------------------------------"
    log "MUC room visibility migration result:"
    log "  rooms scanned : $total"
    log "  newly hidden  : $changed"
    log "  already hidden: $already"
    log "  failed        : $failed"
    echo "------------------------------------------------------------"

    # Per-room failures are not fatal (the stack is up and serving); report them
    # via a non-zero exit only so the caller can retry on the next update.
    if [ "$failed" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
