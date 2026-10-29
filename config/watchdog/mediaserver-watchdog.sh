#!/usr/bin/env bash
#
# mediaserver-watchdog.sh -- Pi-side watchdog for known failure patterns.
#
# Runs LOCALLY on the mediaserver Pi (not from a workstation) via systemd
# timer. Targets a small, well-defined set of failure modes that can be
# detected reliably and remediated safely.
#
# Checks:
#   0. Media mount gate: /mnt/extmedia must be mounted from the fstab UUID
#      and readable. If not -> stop all expected containers (so they stop
#      crash-looping / writing onto the SD card). If the drive is attached
#      but simply not mounted (USB re-enumeration), `e2fsck -p` + `mount`
#      it (at most once per REMOUNT_COOLDOWN_SEC). Otherwise skip every
#      other check: nothing is started while the media mount is missing.
#   1. Stopped/missing expected containers    -> `docker compose up -d <name>`
#   2. Wedged containers (unhealthy + streak) -> `docker compose restart`
#      (allowlisted to torrenting stack; others are logged only)
#   3. VPN egress failure (host IP == container IP, or container IP empty)
#      -> `docker compose restart vpn` (cascades to deluge)
#   4. Empty leaf directories under complete/{tv,movies} -> delete
#   5. Stale container mounts: a container whose /mnt/extmedia bind mounts
#      point at a different device than the host's current mount (drive
#      dropped and re-enumerated) -> `docker compose restart` (any
#      container: the signature is unambiguous and restart is the only fix)
#   6. Root filesystem pressure -> log only (top writable layers listed)
#
# Notifications (optional): if NTFY_URL is set in /etc/mediaserver-watchdog.env,
# every run that logs anything is pushed to ntfy. Identical reports are
# repeated at most every NOTIFY_REPEAT_SEC; a "resolved" message follows
# once a failing run is followed by a clean one.
#
# Design principles:
#   - No unbounded logging: stdout only, captured by systemd into journald
#     (bounded via SystemMaxUse).
#   - Silent on healthy: emit nothing when everything is fine.
#   - Idempotent: safe to invoke arbitrarily often.
#   - Per-container cooldown to avoid flapping.
#
# Exit codes:
#   0 -- all checks passed or successful auto-remediation
#   1 -- a check failed and could not (or should not) be remediated
#   2 -- invocation error (missing docker, wrong user, etc.)
#
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────

MEDIA_MOUNT="/mnt/extmedia"
COMPOSE_DIR="${MEDIA_MOUNT}/config/services"
MOUNT_READ_TIMEOUT=20
MOUNT_READ_ATTEMPTS=3
ROOT_FS_WARN_PCT=90
EXPECTED_CONTAINERS=(vpn deluge duckdns samba jackett radarr sonarr emby flaresolverr)
AUTO_RESTART_ALLOWLIST=(vpn deluge jackett flaresolverr)
HEALTH_FAIL_STREAK=10
COOLDOWN_SEC=600
REMOUNT_COOLDOWN_SEC=3600
STATE_DIR="/var/lib/mediaserver-watchdog"
LOG_PREFIX="[mediaserver-watchdog]"
MEDIA_COMPLETE_DIRS=(/mnt/extmedia/complete/tv /mnt/extmedia/complete/movies)
ENV_FILE="/etc/mediaserver-watchdog.env"
NTFY_URL=""
NOTIFY_REPEAT_SEC=21600

# shellcheck source=/dev/null
[[ -r "$ENV_FILE" ]] && source "$ENV_FILE"

# ── Setup ─────────────────────────────────────────────────────────────────

if ! command -v docker >/dev/null 2>&1; then
    echo "${LOG_PREFIX} ERROR: docker not found in PATH" >&2
    exit 2
fi

mkdir -p "$STATE_DIR"

# Everything logged during this run, for the notification. A file rather
# than a variable so log() works from pipeline subshells too.
REPORT_FILE=$(mktemp)
trap 'rm -f "$REPORT_FILE"' EXIT

log() {
    echo "${LOG_PREFIX} $*"
    echo "$*" >> "$REPORT_FILE"
}

in_allowlist() {
    local name="$1" x
    for x in "${AUTO_RESTART_ALLOWLIST[@]}"; do
        [[ "$x" == "$name" ]] && return 0
    done
    return 1
}

in_cooldown() {
    local name="$1" window="${2:-$COOLDOWN_SEC}"
    local marker="$STATE_DIR/last-restart-${name}"
    [[ -f "$marker" ]] || return 1
    local last now
    last=$(stat -c %Y "$marker")
    now=$(date +%s)
    (( now - last < window ))
}

mark_restart() {
    touch "$STATE_DIR/last-restart-$1"
}

compose_restart() {
    local name="$1"
    ( cd "$COMPOSE_DIR" && docker compose restart "$name" )
}

compose_up() {
    local name="$1"
    ( cd "$COMPOSE_DIR" && docker compose up -d "$name" )
}

# ── Check 0: media mount gate ─────────────────────────────────────────────
#
# When the USB drive drops, systemd unmounts /mnt/extmedia and the drive
# re-enumerates under a new name (sda -> sdb), so the fstab mount never
# comes back on its own. Containers keep running against the dead device.
# Samba crash-loops dumping core onto the SD card, and anything recreated
# in this state would bind-mount empty dirs on the SD card. So: stop the
# stack first, then remount only in the one well-understood case (drive
# attached, nothing mounted, fsck preen succeeds).

MOUNT_PROBLEM=""

media_mount_ok() {
    if ! mountpoint -q "$MEDIA_MOUNT"; then
        MOUNT_PROBLEM="not mounted"
        return 1
    fi

    local want got
    want=$(findmnt --fstab -no SOURCE "$MEDIA_MOUNT" 2>/dev/null || true)
    if [[ "$want" == UUID=* ]]; then
        got=$(findmnt -no UUID "$MEDIA_MOUNT" 2>/dev/null || true)
        if [[ "UUID=${got}" != "$want" ]]; then
            MOUNT_PROBLEM="mounted filesystem UUID=${got:-unknown} does not match fstab ${want}"
            return 1
        fi
    fi

    # Mounted but dead (ext4 shut down after I/O errors) shows up as EIO or
    # a hang. Retry so a momentarily saturated USB disk isn't mistaken for it.
    local i
    for (( i = 1; i <= MOUNT_READ_ATTEMPTS; i++ )); do
        if timeout "$MOUNT_READ_TIMEOUT" stat -t "$COMPOSE_DIR/docker-compose.yml" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    MOUNT_PROBLEM="mounted but unreadable (${MOUNT_READ_ATTEMPTS} attempts)"
    return 1
}

stop_all_containers() {
    local name state
    for name in "${EXPECTED_CONTAINERS[@]}"; do
        state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
        [[ "$state" == "running" || "$state" == "restarting" ]] || continue
        log "  action: docker stop ${name} (media mount unavailable)"
        if ! docker stop -t 30 "$name" >/dev/null 2>&1; then
            log "  ERROR: failed to stop ${name}"
        fi
    done
}

try_remount() {
    local dev="$1" rc=0

    if in_cooldown remount "$REMOUNT_COOLDOWN_SEC"; then
        log "  skip remount: already attempted within ${REMOUNT_COOLDOWN_SEC}s"
        return 1
    fi
    mark_restart remount

    # -p only fixes what is safe without a human (journal replay, summary
    # counts); anything worse exits >= 4 and we stop there.
    log "  action: e2fsck -p ${dev}"
    e2fsck -p "$dev" >/dev/null 2>&1 || rc=$?
    if (( rc >= 2 )); then
        log "  ERROR: e2fsck -p ${dev} exited ${rc}; needs a manual fsck"
        return 1
    fi

    log "  action: mount ${MEDIA_MOUNT}"
    if ! mount "$MEDIA_MOUNT" >/dev/null 2>&1; then
        log "  ERROR: mount ${MEDIA_MOUNT} failed"
        return 1
    fi

    if media_mount_ok; then
        log "  ${MEDIA_MOUNT} remounted from ${dev}; containers will be started"
        return 0
    fi
    log "  ERROR: ${MEDIA_MOUNT} still unhealthy after remount: ${MOUNT_PROBLEM}"
    return 1
}

check_media_mount() {
    media_mount_ok && return 0

    log "MEDIA MOUNT FAILURE: ${MEDIA_MOUNT} ${MOUNT_PROBLEM}"
    stop_all_containers

    local want dev=""
    want=$(findmnt --fstab -no SOURCE "$MEDIA_MOUNT" 2>/dev/null || true)
    if [[ "$want" == UUID=* && -e "/dev/disk/by-uuid/${want#UUID=}" ]]; then
        dev=$(readlink -f "/dev/disk/by-uuid/${want#UUID=}")
    fi

    if [[ -z "$dev" ]]; then
        log "  drive ${want:-for ${MEDIA_MOUNT}} is not attached; nothing to remount"
        return 1
    fi

    if [[ "$MOUNT_PROBLEM" != "not mounted" ]]; then
        log "  drive is ${dev}; not remounting automatically (${MOUNT_PROBLEM})"
        return 1
    fi

    log "  drive is attached as ${dev}"
    try_remount "$dev"
}

# ── Check 1: stopped / missing expected containers ────────────────────────

check_stopped_containers() {
    local status=0 name state
    for name in "${EXPECTED_CONTAINERS[@]}"; do
        state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
        if [[ "$state" == "running" ]]; then
            continue
        fi

        log "Container ${name} not running (state=${state})"

        if in_cooldown "$name"; then
            log "  skip: within ${COOLDOWN_SEC}s cooldown"
            status=1
            continue
        fi

        log "  action: docker compose up -d ${name}"
        if compose_up "$name" >/dev/null 2>&1; then
            mark_restart "$name"
            log "  ${name} started"
        else
            log "  ERROR: failed to start ${name}" >&2
            status=1
        fi
    done
    return $status
}

# ── Check 2: wedged containers (unhealthy + streak) ───────────────────────

check_wedged_containers() {
    local status=0 name health streak
    for name in "${EXPECTED_CONTAINERS[@]}"; do
        # Only inspect running containers with a healthcheck
        local state
        state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
        [[ "$state" == "running" ]] || continue

        health=$(docker inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo "none")
        [[ "$health" == "unhealthy" ]] || continue

        streak=$(docker inspect "$name" --format '{{.State.Health.FailingStreak}}' 2>/dev/null || echo "0")
        streak="${streak:-0}"
        (( streak > HEALTH_FAIL_STREAK )) || continue

        log "Container ${name} wedged: unhealthy, FailingStreak=${streak}"

        if ! in_allowlist "$name"; then
            log "  ${name} not in auto-restart allowlist; leaving for human review"
            status=1
            continue
        fi

        if in_cooldown "$name"; then
            log "  skip: within ${COOLDOWN_SEC}s cooldown"
            status=1
            continue
        fi

        log "  action: docker compose restart ${name}"
        if compose_restart "$name" >/dev/null 2>&1; then
            mark_restart "$name"
            log "  ${name} restarted"
        else
            log "  ERROR: failed to restart ${name}" >&2
            status=1
        fi
    done
    return $status
}

# ── Check 3: VPN egress (container egress must differ from host egress) ───

check_vpn_egress() {
    local state
    state=$(docker inspect vpn --format '{{.State.Status}}' 2>/dev/null || echo "missing")
    [[ "$state" == "running" ]] || return 0  # covered by check_stopped_containers

    local host_ip vpn_ip
    host_ip=$(curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null || true)
    vpn_ip=$(docker exec vpn curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null || true)

    # Strip whitespace
    host_ip="${host_ip//[[:space:]]/}"
    vpn_ip="${vpn_ip//[[:space:]]/}"

    local wedged=false reason=""
    if [[ -z "$vpn_ip" ]]; then
        wedged=true
        reason="vpn container egress empty (host=${host_ip:-unknown})"
    elif [[ -n "$host_ip" && "$vpn_ip" == "$host_ip" ]]; then
        wedged=true
        reason="vpn egress == host egress (${vpn_ip}); tunnel is down"
    fi

    if [[ "$wedged" == false ]]; then
        return 0
    fi

    log "VPN egress check failed: ${reason}"

    if in_cooldown vpn; then
        log "  skip: within ${COOLDOWN_SEC}s cooldown"
        return 1
    fi

    log "  action: docker compose restart vpn (cascades to deluge)"
    if compose_restart vpn >/dev/null 2>&1; then
        mark_restart vpn
        log "  vpn restarted"
        return 0
    else
        log "  ERROR: docker compose restart vpn failed" >&2
        return 1
    fi
}

# ── Check 4: empty media directories ──────────────────────────────────────

check_empty_media_dirs() {
    local dir removed
    for dir in "${MEDIA_COMPLETE_DIRS[@]}"; do
        [[ -d "$dir" ]] || continue
        # Depth-first single-pass leaf removal. Capture what was removed so
        # we only log when we actually did something.
        removed=$(find "$dir" -mindepth 1 -type d -empty -print -delete 2>/dev/null || true)
        if [[ -n "$removed" ]]; then
            local count
            count=$(printf '%s\n' "$removed" | wc -l | tr -d ' ')
            log "Removed ${count} empty dir(s) under ${dir}"
        fi
    done
    return 0
}

# ── Check 5: stale container mounts ───────────────────────────────────────
#
# A container's bind mounts keep the device they were created with. If the
# drive re-enumerated (8:1 -> 8:17) and the host was remounted, containers
# started before that still see the dead device until restarted.

check_stale_mounts() {
    local status=0 name pid host_dev src dest dev stale
    host_dev=$(mountpoint -d "$MEDIA_MOUNT" 2>/dev/null || true)
    [[ -n "$host_dev" ]] || return 0  # covered by check_media_mount

    for name in "${EXPECTED_CONTAINERS[@]}"; do
        pid=$(docker inspect "$name" --format '{{.State.Pid}}' 2>/dev/null || echo 0)
        [[ "${pid:-0}" -gt 0 ]] || continue

        stale=""
        while IFS='|' read -r src dest; do
            [[ "$src" == "$MEDIA_MOUNT" || "$src" == "$MEDIA_MOUNT"/* ]] || continue
            dev=$(awk -v d="$dest" '$5 == d { print $3; exit }' "/proc/${pid}/mountinfo" 2>/dev/null || true)
            if [[ -n "$dev" && "$dev" != "$host_dev" ]]; then
                stale="${dest} (dev ${dev})"
                break
            fi
        done < <(docker inspect "$name" --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{println}}{{end}}' 2>/dev/null)

        [[ -n "$stale" ]] || continue

        log "Container ${name} has a stale media mount: ${stale}, host ${MEDIA_MOUNT} is dev ${host_dev}"

        if in_cooldown "$name"; then
            log "  skip: within ${COOLDOWN_SEC}s cooldown"
            status=1
            continue
        fi

        log "  action: docker compose restart ${name}"
        if compose_restart "$name" >/dev/null 2>&1; then
            mark_restart "$name"
            log "  ${name} restarted"
        else
            log "  ERROR: failed to restart ${name}" >&2
            status=1
        fi
    done
    return $status
}

# ── Check 6: root filesystem pressure ─────────────────────────────────────
#
# A full SD card breaks docker state writes, journald, and any container
# that needs /tmp. Detect only -- what to delete is a human decision.

check_root_fs() {
    local used avail
    used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
    avail=$(df -h --output=avail / | tail -1 | tr -d ' ')
    (( used >= ROOT_FS_WARN_PCT )) || return 0

    log "Root filesystem ${used}% used (${avail} free); largest container writable layers:"
    docker ps -as --format '{{.Size}}|{{.Names}}' 2>/dev/null \
        | sort -t'|' -k1 -h -r | head -3 \
        | while IFS='|' read -r size name; do log "  ${name}: ${size}"; done
    return 1
}

# ── Notifications ─────────────────────────────────────────────────────────

notify() {
    local status="$1"
    [[ -n "$NTFY_URL" ]] || return 0

    local sig_file="$STATE_DIR/notify-signature" last_status_file="$STATE_DIR/notify-status"
    local prev_status=0 title priority tags sig now
    [[ -f "$last_status_file" ]] && prev_status=$(cat "$last_status_file")
    echo "$status" > "$last_status_file"

    if [[ ! -s "$REPORT_FILE" ]]; then
        # Clean run. Announce recovery once if the last report was a failure.
        if (( prev_status != 0 )) && [[ -f "$sig_file" ]]; then
            rm -f "$sig_file"
            curl -fsS --max-time 15 -H "Title: mediaserver: resolved" -H "Tags: white_check_mark" \
                -d "All watchdog checks passing again." "$NTFY_URL" >/dev/null 2>&1 || true
        fi
        return 0
    fi

    # Same report (ignoring counters/IDs) -> repeat at most every NOTIFY_REPEAT_SEC.
    sig=$(tr -d '0-9' < "$REPORT_FILE" | sha256sum | cut -d' ' -f1)
    now=$(date +%s)
    if [[ -f "$sig_file" && "$(cat "$sig_file")" == "$sig" ]] \
        && (( now - $(stat -c %Y "$sig_file") < NOTIFY_REPEAT_SEC )); then
        return 0
    fi

    if grep -q "MEDIA MOUNT FAILURE" "$REPORT_FILE"; then
        if (( status == 0 )); then
            title="mediaserver: media drive dropped, auto-recovered"; priority=high; tags=rotating_light
        else
            title="mediaserver: media drive DOWN"; priority=urgent; tags=rotating_light
        fi
    elif (( status != 0 )); then
        title="mediaserver: needs attention"; priority=high; tags=warning
    else
        title="mediaserver: auto-remediated"; priority=default; tags=wrench
    fi

    if curl -fsS --max-time 15 -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: ${tags}" \
        --data-binary "@${REPORT_FILE}" "$NTFY_URL" >/dev/null 2>&1; then
        echo "$sig" > "$sig_file"
    else
        echo "${LOG_PREFIX} WARNING: ntfy notification failed" >&2
    fi
}

finish() {
    notify "$1"
    exit "$1"
}

# ── Run all checks ────────────────────────────────────────────────────────

overall_status=0

check_root_fs || overall_status=1

# Everything below needs the media drive. Never start or restart containers
# while it is missing -- they would bind-mount empty dirs on the SD card.
if ! check_media_mount; then
    finish 1
fi

check_stopped_containers || overall_status=1
check_wedged_containers  || overall_status=1
check_vpn_egress         || overall_status=1
check_empty_media_dirs   || overall_status=1
check_stale_mounts       || overall_status=1

finish "$overall_status"
