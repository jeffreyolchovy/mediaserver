#!/usr/bin/env bash
#
# mediaserver-watchdog.sh -- Pi-side watchdog for known failure patterns.
#
# Runs LOCALLY on the mediaserver Pi (not from a workstation) via systemd
# timer. Targets a small, well-defined set of failure modes that can be
# detected reliably and remediated safely.
#
# Checks:
#   1. Stopped/missing expected containers    -> `docker compose up -d <name>`
#   2. Wedged containers (unhealthy + streak) -> `docker compose restart`
#      (allowlisted to torrenting stack; others are logged only)
#   3. VPN egress failure (host IP == container IP, or container IP empty)
#      -> `docker compose restart vpn` (cascades to deluge)
#   4. Empty leaf directories under complete/{tv,movies} -> delete
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

COMPOSE_DIR="/mnt/extmedia/config/services"
EXPECTED_CONTAINERS=(vpn deluge duckdns samba jackett radarr sonarr emby flaresolverr)
AUTO_RESTART_ALLOWLIST=(vpn deluge jackett flaresolverr)
HEALTH_FAIL_STREAK=10
COOLDOWN_SEC=600
STATE_DIR="/var/lib/mediaserver-watchdog"
LOG_PREFIX="[mediaserver-watchdog]"
MEDIA_COMPLETE_DIRS=(/mnt/extmedia/complete/tv /mnt/extmedia/complete/movies)

# ── Setup ─────────────────────────────────────────────────────────────────

if ! command -v docker >/dev/null 2>&1; then
    echo "${LOG_PREFIX} ERROR: docker not found in PATH" >&2
    exit 2
fi

mkdir -p "$STATE_DIR"

log() { echo "${LOG_PREFIX} $*"; }

in_allowlist() {
    local name="$1" x
    for x in "${AUTO_RESTART_ALLOWLIST[@]}"; do
        [[ "$x" == "$name" ]] && return 0
    done
    return 1
}

in_cooldown() {
    local name="$1"
    local marker="$STATE_DIR/last-restart-${name}"
    [[ -f "$marker" ]] || return 1
    local last now
    last=$(stat -c %Y "$marker")
    now=$(date +%s)
    (( now - last < COOLDOWN_SEC ))
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

# ── Run all checks ────────────────────────────────────────────────────────

overall_status=0

check_stopped_containers || overall_status=1
check_wedged_containers  || overall_status=1
check_vpn_egress         || overall_status=1
check_empty_media_dirs   || overall_status=1

exit "$overall_status"
