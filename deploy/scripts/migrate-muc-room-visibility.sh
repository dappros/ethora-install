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
# `change_room_option`. It is idempotent: a room already set to false is left
# untouched (no write), so re-running is safe and cheap.
#
# Transport: the ejabberd HTTP API (mod_http_api on 127.0.0.1:5280, as
# admin@XMPP_DOMAIN) when reachable, else `ejabberdctl` inside the container.
# Each ejabberdctl call boots an Erlang node (~0.8s) while an HTTP call takes
# ~25ms, which matters at tens of thousands of rooms. Rooms are processed by
# MUC_MIGRATION_JOBS parallel workers (default 8 over HTTP, 4 over ejabberdctl).
#
# Run standalone (as the deploy user / root that owns docker):
#   sudo bash deploy/scripts/migrate-muc-room-visibility.sh
#
# update.sh calls it once (guarded by a stamp) after init-services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

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
TRANSPORT="ctl"
API_URL="${EJABBERD_API_URL:-http://127.0.0.1:5280/api}"
MUC_PREFIX="${EJABBERD_MUC_PREFIX:-conference.}"

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

# POST one command to the ejabberd HTTP API; prints the body, fails on non-200.
# Credentials go to curl on stdin (-K -) so the password never shows up in ps.
http_api() {
    local cmd="$1" data="$2" pass out code
    pass="${XMPP_ADMIN_PASSWORD//\\/\\\\}"
    pass="${pass//\"/\\\"}"
    out="$(printf 'user = "admin@%s:%s"\n' "$XMPP_DOMAIN" "$pass" \
        | curl -sS -m 15 -K - -H 'Content-Type: application/json' \
            -w '\n%{http_code}' -d "$data" "$API_URL/$cmd" 2>/dev/null)" || return 1
    code="${out##*$'\n'}"
    [ "$code" = "200" ] || return 1
    printf '%s\n' "${out%$'\n'*}"
}

# Flatten a JSON array of plain strings (room JIDs, vhosts) to one per line.
json_list() {
    tr -d '[]" \n' | tr ',' '\n' | sed '/^$/d'
}

# Use the HTTP API when admin credentials are known and it answers.
# .deploy.env is the same file init-services.sh sources for XMPP_ADMIN_PASSWORD.
pick_transport() {
    if [ -z "${XMPP_ADMIN_PASSWORD:-}" ] || [ -z "${XMPP_DOMAIN:-}" ]; then
        if [ -f "$DEPLOY_DIR/.deploy.env" ]; then
            set -a
            # shellcheck disable=SC1091
            . "$DEPLOY_DIR/.deploy.env" >/dev/null 2>&1 || true
            set +a
        fi
    fi
    if [ -n "${XMPP_ADMIN_PASSWORD:-}" ] && [ -n "${XMPP_DOMAIN:-}" ] \
        && command -v curl >/dev/null 2>&1 \
        && http_api registered_vhosts '{}' >/dev/null; then
        TRANSPORT="http"
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
    local out rc vhosts v

    if [ "$TRANSPORT" = "http" ]; then
        vhosts="$(http_api registered_vhosts '{}' | json_list)"
        [ -z "$vhosts" ] && return 1
        for v in $vhosts; do
            http_api muc_online_rooms "{\"service\":\"${MUC_PREFIX}${v}\"}" | json_list || true
        done
        return 0
    fi

    # `if` so a non-zero exit here does not trip `set -e` before we can fall back.
    if out="$(ejabberdctl muc_online_rooms global 2>/dev/null)"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi 'exception'; then
        printf '%s\n' "$out"
        return 0
    fi

    vhosts="$(ejabberdctl registered_vhosts 2>/dev/null | sed '/^[[:space:]]*$/d')"
    [ -z "$vhosts" ] && return 1
    for v in $vhosts; do
        ejabberdctl muc_online_rooms "${MUC_PREFIX}${v}" 2>/dev/null || true
    done
}

# Print "<public> <public_list>" for a room in one read ("-" for a value that
# is absent or unreadable, so `read` never shifts fields). Over HTTP
# get_room_options is a flat JSON object of strings; over ejabberdctl it is one
# "name<whitespace>value" per line. Both match the name exactly so `public`
# does not also match `public_list`.
room_visibility() {
    local room="$1" service="$2" out pub list
    if [ "$TRANSPORT" = "http" ]; then
        out="$(http_api get_room_options "{\"name\":\"$room\",\"service\":\"$service\"}" || true)"
        pub="$(printf '%s' "$out" | sed -n 's/.*"public":"\([a-z]*\)".*/\1/p')"
        list="$(printf '%s' "$out" | sed -n 's/.*"public_list":"\([a-z]*\)".*/\1/p')"
    else
        out="$(ejabberdctl get_room_options "$room" "$service" 2>/dev/null || true)"
        pub="$(printf '%s\n' "$out" | awk '$1=="public" {print $2; exit}')"
        list="$(printf '%s\n' "$out" | awk '$1=="public_list" {print $2; exit}')"
    fi
    printf '%s %s\n' "${pub:--}" "${list:--}"
}

hide_option() {
    local room="$1" service="$2" opt="$3"
    if [ "$TRANSPORT" = "http" ]; then
        http_api change_room_option \
            "{\"name\":\"$room\",\"service\":\"$service\",\"option\":\"$opt\",\"value\":\"false\"}" >/dev/null
    else
        ejabberdctl change_room_option "$room" "$service" "$opt" false >/dev/null 2>&1
    fi
}

# Worker: handle one room JID and print exactly one "<status> <jid>" line
# (hidden / already / failed). Always exits 0 so xargs keeps going.
process_room() {
    local jid="$1"
    # jid is "name@service"; split on the first '@'.
    local room="${jid%%@*}"
    local service="${jid#*@}"
    if [ -z "$room" ] || [ -z "$service" ] || [ "$service" = "$jid" ]; then
        echo "failed $jid"
        return 0
    fi

    local cur_public cur_list
    read -r cur_public cur_list <<< "$(room_visibility "$room" "$service")" || true

    if [ "$cur_public" = "false" ] && [ "$cur_list" = "false" ]; then
        echo "already $jid"
        return 0
    fi

    local ok="true"
    if [ "$cur_public" != "false" ]; then
        hide_option "$room" "$service" public || ok="false"
    fi
    if [ "$cur_list" != "false" ]; then
        hide_option "$room" "$service" public_list || ok="false"
    fi

    if [ "$ok" = "true" ]; then
        echo "hidden $jid"
    else
        echo "failed $jid"
    fi
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

    pick_transport
    local jobs
    if [ "$TRANSPORT" = "http" ]; then
        jobs="${MUC_MIGRATION_JOBS:-8}"
        log "Using ejabberd HTTP API ($API_URL) with $jobs parallel workers"
    else
        jobs="${MUC_MIGRATION_JOBS:-4}"
        log "HTTP API unavailable; using ejabberdctl with $jobs parallel workers (slower)"
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

    local room_count
    room_count="$(printf '%s\n' "$rooms" | wc -l | tr -d ' ')"
    log "Found $room_count rooms"

    export XMPP_CONTAINER TRANSPORT API_URL XMPP_DOMAIN XMPP_ADMIN_PASSWORD
    export -f ejabberdctl http_api room_visibility hide_option process_room

    local status jid
    while read -r status jid; do
        total=$((total + 1))
        case "$status" in
            hidden) changed=$((changed + 1)) ;;
            already) already=$((already + 1)) ;;
            *) failed=$((failed + 1)); warn "  failed to update: $jid" ;;
        esac
        if [ $((total % 500)) -eq 0 ]; then
            log "  progress: $total/$room_count (hidden $changed, already $already, failed $failed)"
        fi
    done < <(printf '%s\n' "$rooms" | xargs -d '\n' -n 1 -P "$jobs" bash -c 'process_room "$1"' _)

    echo "------------------------------------------------------------"
    log "MUC room visibility migration result:"
    log "  rooms scanned : $total"
    log "  newly hidden  : $changed"
    log "  already hidden: $already"
    log "  failed        : $failed"
    echo "------------------------------------------------------------"

    # Per-room failures are not fatal (the stack is up and serving); report them
    # via a non-zero exit only so the caller can retry on the next update.
    # A worker that died without reporting also counts as a failure.
    if [ "$failed" -gt 0 ] || [ "$total" -lt "$room_count" ]; then
        return 1
    fi
    return 0
}

main "$@"
