#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------------
# install.sh -- Provision a Raspberry Pi as a Docker-based media server.
#
# Usage:
#   ./install.sh user@host
#
# This script is meant to be run from your local machine. It connects to the
# target host over SSH to install Docker, mount the external drive, deploy
# config files, and start services.
#
# Before running:
#   1. Copy config/.env.example to config/.env and fill in your values.
#   2. Copy config/vpn/vpn.conf.example to config/vpn/vpn.conf and set your
#      preferred PIA region.
#   3. Copy config/vpn/vpn.auth.example to config/vpn/vpn.auth and fill in
#      your PIA credentials (username on line 1, password on line 2).
#   4. Ensure you can SSH into the target host without a password prompt.
# --------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"

usage() {
    echo "Usage: $0 user@host"
    echo ""
    echo "Provision a Raspberry Pi as a Docker-based media server."
    echo ""
    echo "Before running, create these files from their .example templates:"
    echo "  config/.env             -- Docker Compose environment variables"
    echo "  config/vpn/vpn.conf     -- OpenVPN configuration (set your region)"
    echo "  config/vpn/vpn.auth     -- PIA credentials (username and password)"
    exit 1
}

# -- Argument parsing ------------------------------------------------------

if [[ $# -ne 1 ]]; then
    usage
fi

TARGET="$1"

# Validate target looks like user@host
if [[ ! "$TARGET" =~ ^[^@]+@[^@]+$ ]]; then
    echo "Error: target must be in the format user@host"
    exit 1
fi

# -- Pre-flight checks -----------------------------------------------------

echo "==> Pre-flight checks"

# Check required files exist
for f in ".env" "vpn/vpn.conf" "vpn/vpn.auth"; do
    if [[ ! -f "$CONFIG_DIR/$f" ]]; then
        echo "Error: $CONFIG_DIR/$f not found."
        echo "Copy the .example template and fill in your values."
        exit 1
    fi
done

echo "  Config files found."

# Test SSH connectivity
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$TARGET" 'true' 2>/dev/null; then
    echo "Error: cannot connect to $TARGET via SSH."
    echo "Ensure SSH key-based auth is set up and the host is reachable."
    exit 1
fi

echo "  SSH connection to $TARGET OK."

REMOTE_USER=$(echo "$TARGET" | cut -d@ -f1)
MEDIA_ROOT="/mnt/extmedia"

# -- Helper: install a file on the target as root, only if it changed ------
#
# Usage: push_root_file <local-src> <remote-dst> <mode>
# Prints "changed" or "unchanged" so the caller can decide whether to reload
# or restart anything. The file is streamed over SSH straight into place
# (umask 077, atomic rename), so it never sits world-readable in /tmp. That
# matters for secrets such as config/unifi/unifi.env.

sha256_local() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

push_root_file() {
    local src="$1" dst="$2" mode="$3" want have
    want=$(sha256_local "$src")
    have=$(ssh "$TARGET" "sudo sha256sum '$dst' 2>/dev/null | awk '{print \$1}'" || true)
    if [[ "$want" == "$have" ]]; then
        echo "unchanged"
        return 0
    fi
    # mkdir BEFORE tightening umask so parent dirs get the normal 0755; only
    # the file itself is written under umask 077.
    ssh "$TARGET" "sudo sh -c 'mkdir -p \"\$(dirname $dst)\" && umask 077 && cat > $dst.tmp && chown root:root $dst.tmp && chmod $mode $dst.tmp && mv -f $dst.tmp $dst'" < "$src"
    echo "changed"
}

# -- Step 1: Install prerequisites ----------------------------------------

echo ""
echo "==> Step 1: Installing prerequisites"

ssh "$TARGET" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

if command -v curl &>/dev/null && command -v jq &>/dev/null; then
    echo "  Prerequisites already installed."
else
    echo "  Installing curl and jq..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq curl jq
fi
REMOTE_SCRIPT

# -- Step 2: Scope Avahi mDNS to physical interfaces -----------------------
#
# By default avahi-daemon publishes on all interfaces, including Docker
# bridge networks created later by compose. When that happens, some clients
# (browsers with DoH, non-Bonjour resolvers) can resolve <host>.local to a
# Docker bridge gateway IP (e.g. 172.18.0.1) that is unreachable from the
# LAN. Restricting avahi to wlan0/eth0 pins .local resolution to the real
# LAN address. avahi-utils is also installed so avahi-resolve is available
# for diagnostics.

echo ""
echo "==> Step 2: Scoping Avahi mDNS to physical interfaces"

ssh "$TARGET" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

if ! dpkg -s avahi-daemon &>/dev/null; then
    echo "  Installing avahi-daemon..."
    sudo apt-get install -y -qq avahi-daemon
fi

if ! dpkg -s avahi-utils &>/dev/null; then
    echo "  Installing avahi-utils..."
    sudo apt-get install -y -qq avahi-utils
fi

CONF=/etc/avahi/avahi-daemon.conf

if grep -qE '^allow-interfaces=wlan0,eth0$' "$CONF"; then
    echo "  avahi-daemon already scoped to wlan0,eth0."
else
    echo "  Backing up $CONF..."
    sudo cp "$CONF" "${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    echo "  Setting allow-interfaces=wlan0,eth0..."
    # Replace an existing (commented or uncommented) allow-interfaces line,
    # or append one under [server] if none exists.
    if grep -qE '^[#[:space:]]*allow-interfaces=' "$CONF"; then
        sudo sed -i -E 's|^[#[:space:]]*allow-interfaces=.*|allow-interfaces=wlan0,eth0|' "$CONF"
    else
        sudo sed -i '/^\[server\]/a allow-interfaces=wlan0,eth0' "$CONF"
    fi
    sudo systemctl restart avahi-daemon
    echo "  avahi-daemon restarted."
fi
REMOTE_SCRIPT

# -- Step 3: Install Docker ------------------------------------------------

echo ""
echo "==> Step 3: Installing Docker"

ssh "$TARGET" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

if command -v docker &>/dev/null; then
    echo "  Docker already installed: $(docker --version)"
else
    echo "  Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | sudo sh
    echo "  Docker installed: $(docker --version)"
fi
REMOTE_SCRIPT

# -- Step 4: Add user to docker group -------------------------------------

echo ""
echo "==> Step 4: Configuring Docker group"

ssh "$TARGET" "bash -s" <<REMOTE_SCRIPT
set -euo pipefail

if id -nG "$REMOTE_USER" | grep -qw docker; then
    echo "  User $REMOTE_USER is already in the docker group."
else
    echo "  Adding $REMOTE_USER to the docker group..."
    sudo usermod -aG docker "$REMOTE_USER"
    echo "  Done. Group change takes effect on next login."
fi
REMOTE_SCRIPT

# -- Step 5: Configure Docker daemon --------------------------------------

echo ""
echo "==> Step 5: Configuring Docker daemon"

DAEMON_JSON=$(cat "$CONFIG_DIR/daemon.json")

ssh "$TARGET" "bash -s" <<REMOTE_SCRIPT
set -euo pipefail

DESIRED='$DAEMON_JSON'

if [[ -f /etc/docker/daemon.json ]]; then
    CURRENT=\$(cat /etc/docker/daemon.json)
    if [[ "\$CURRENT" == "\$DESIRED" ]]; then
        echo "  daemon.json already configured."
    else
        echo "  Updating daemon.json..."
        echo "\$DESIRED" | sudo tee /etc/docker/daemon.json >/dev/null
        sudo systemctl restart docker
        echo "  Docker restarted with new config."
    fi
else
    echo "  Writing daemon.json..."
    echo "\$DESIRED" | sudo tee /etc/docker/daemon.json >/dev/null
    sudo systemctl restart docker
    echo "  Docker restarted with new config."
fi
REMOTE_SCRIPT

# -- Step 6: Detect and mount external drive -------------------------------

echo ""
echo "==> Step 6: Mounting external drive"

ssh -t "$TARGET" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

MOUNT_POINT="/mnt/extmedia"

# Check if already mounted
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "  $MOUNT_POINT is already mounted."
    exit 0
fi

# Auto-detect the largest ext4 partition
echo "  Scanning for ext4 partitions..."
CANDIDATES=$(lsblk -rno NAME,FSTYPE,SIZE,UUID | awk '$2 == "ext4" && $4 != ""' | sort -h -k3 -r)

if [[ -z "$CANDIDATES" ]]; then
    echo "  Error: no ext4 partitions found."
    echo "  Attach an ext4-formatted USB drive and try again."
    exit 1
fi

# Pick the largest
BEST=$(echo "$CANDIDATES" | head -1)
BEST_NAME=$(echo "$BEST" | awk '{print $1}')
BEST_SIZE=$(echo "$BEST" | awk '{print $3}')
BEST_UUID=$(echo "$BEST" | awk '{print $4}')

echo ""
echo "  Detected ext4 partition:"
echo "    Device: /dev/$BEST_NAME"
echo "    Size:   $BEST_SIZE"
echo "    UUID:   $BEST_UUID"
echo ""
read -rp "  Use this partition? [Y/n] " CONFIRM
CONFIRM="${CONFIRM:-Y}"

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    exit 1
fi

# Create mount point
sudo mkdir -p "$MOUNT_POINT"

# Add to fstab if not already there
FSTAB_ENTRY="UUID=$BEST_UUID $MOUNT_POINT ext4 defaults,noatime,nofail 0 2"
if grep -q "$BEST_UUID" /etc/fstab; then
    echo "  fstab entry already exists."
else
    echo "  Adding fstab entry..."
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab >/dev/null
fi

# Mount
sudo mount "$MOUNT_POINT"
echo "  Mounted $MOUNT_POINT."
REMOTE_SCRIPT

# -- Step 7: Deploy config files ------------------------------------------

echo ""
echo "==> Step 7: Deploying config files"

# Ensure remote directories exist
ssh "$TARGET" "bash -s" <<REMOTE_SCRIPT
set -euo pipefail
mkdir -p "$MEDIA_ROOT/config/services"
mkdir -p "$MEDIA_ROOT/config/samba"
mkdir -p "$MEDIA_ROOT/config/vpn"
REMOTE_SCRIPT

# Copy files
scp -q "$CONFIG_DIR/docker-compose.yml" "$TARGET:$MEDIA_ROOT/config/services/docker-compose.yml"
scp -q "$CONFIG_DIR/.env"               "$TARGET:$MEDIA_ROOT/config/services/.env"
scp -q "$CONFIG_DIR/samba/config.yml"   "$TARGET:$MEDIA_ROOT/config/samba/config.yml"
scp -q "$CONFIG_DIR/vpn/ca.rsa.2048.crt" "$TARGET:$MEDIA_ROOT/config/vpn/ca.rsa.2048.crt"
scp -q "$CONFIG_DIR/vpn/vpn.conf"       "$TARGET:$MEDIA_ROOT/config/vpn/vpn.conf"
scp -q "$CONFIG_DIR/vpn/vpn.auth"       "$TARGET:$MEDIA_ROOT/config/vpn/vpn.auth"

echo "  Config files deployed."

# -- Step 8: Start services ------------------------------------------------

echo ""
echo "==> Step 8: Starting services"

ssh "$TARGET" "bash -s" <<REMOTE_SCRIPT
set -euo pipefail
cd "$MEDIA_ROOT/config/services"
sg docker -c 'docker compose pull'
sg docker -c 'docker compose up -d'
REMOTE_SCRIPT

# -- Step 9: Persistent, bounded journald -----------------------------------
#
# Raspberry Pi OS keeps the journal in RAM (/run/log/journal) by default, so
# every reboot or power loss wipes the logs. That hides why the server went
# down and erases the watchdog's history. Persist it to disk, bounded to
# 200M / 1 month so it can't fill the SD card.

echo ""
echo "==> Step 9: Enabling persistent journald"

if [[ $(push_root_file "$CONFIG_DIR/journald/persistent.conf" \
        /etc/systemd/journald.conf.d/persistent.conf 0644) == "changed" ]]; then
    ssh "$TARGET" 'sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald && sudo journalctl --flush'
    echo "  journald is now persistent (bounded: 200M / 1 month)."
else
    echo "  journald already persistent."
fi

# -- Step 10: Install the mediaserver watchdog ------------------------------
#
# A systemd timer (every 15 min, first run 2 min after boot) runs a small
# watchdog that auto-remediates known failure modes:
#   - an expected container is stopped/missing   -> docker compose up -d
#   - a container is wedged (unhealthy, FailingStreak > 10); auto-restart is
#     limited to the torrenting stack (vpn, deluge, jackett, flaresolverr),
#     everything else is logged only
#   - VPN egress is empty or equals the host's public IP (tunnel down)
#                                                -> docker compose restart vpn
#   - empty leaf directories under complete/{tv,movies} -> removed
# It's silent on a healthy system and logs to journald only when it acts.

echo ""
echo "==> Step 10: Installing mediaserver watchdog"

WD_CHANGED=0
for pair in \
    "mediaserver-watchdog.sh:/usr/local/sbin/mediaserver-watchdog.sh:0755" \
    "mediaserver-watchdog.service:/etc/systemd/system/mediaserver-watchdog.service:0644" \
    "mediaserver-watchdog.timer:/etc/systemd/system/mediaserver-watchdog.timer:0644"; do
    IFS=: read -r src dst mode <<< "$pair"
    if [[ $(push_root_file "$CONFIG_DIR/watchdog/$src" "$dst" "$mode") == "changed" ]]; then
        echo "  Updated $dst"
        WD_CHANGED=1
    fi
done

if (( WD_CHANGED )); then
    ssh "$TARGET" 'sudo systemctl daemon-reload'
else
    echo "  Watchdog files already up to date."
fi
ssh "$TARGET" 'sudo systemctl enable --now mediaserver-watchdog.timer >/dev/null 2>&1 && systemctl is-active mediaserver-watchdog.timer' \
    | sed 's/^/  mediaserver-watchdog.timer: /'

# -- Step 11 (optional): UniFi port-forward reconciler -----------------------
#
# UniFi firmware upgrades can silently wipe every port-forward rule, which
# kills external access. If you're
# behind a UniFi gateway, this installs an hourly systemd timer that
# re-creates any missing rule from config/unifi/unifi-portforwards.json via
# the gateway's local API. It's silent when nothing is missing and logs to
# journald when it restores something.
#
# Runs only if config/unifi/unifi.env and config/unifi/unifi-portforwards.json
# exist (create them from their .example templates).

echo ""
echo "==> Step 11: UniFi port-forward reconciler (optional)"

if [[ -f "$CONFIG_DIR/unifi/unifi.env" && -f "$CONFIG_DIR/unifi/unifi-portforwards.json" ]]; then
    UF_CHANGED=0
    for pair in \
        "unifi-portforward-reconcile.sh:/usr/local/sbin/unifi-portforward-reconcile.sh:0755" \
        "unifi-portforward-reconcile.service:/etc/systemd/system/unifi-portforward-reconcile.service:0644" \
        "unifi-portforward-reconcile.timer:/etc/systemd/system/unifi-portforward-reconcile.timer:0644" \
        "unifi-portforwards.json:/etc/mediaserver/unifi-portforwards.json:0644" \
        "unifi.env:/etc/mediaserver/unifi.env:0600"; do
        IFS=: read -r src dst mode <<< "$pair"
        if [[ $(push_root_file "$CONFIG_DIR/unifi/$src" "$dst" "$mode") == "changed" ]]; then
            echo "  Updated $dst"
            UF_CHANGED=1
        fi
    done

    if (( UF_CHANGED )); then
        ssh "$TARGET" 'sudo systemctl daemon-reload'
    else
        echo "  Reconciler files already up to date."
    fi
    ssh "$TARGET" 'sudo systemctl enable --now unifi-portforward-reconcile.timer >/dev/null 2>&1 && systemctl is-active unifi-portforward-reconcile.timer' \
        | sed 's/^/  unifi-portforward-reconcile.timer: /'
else
    echo "  Skipped (config/unifi/unifi.env and/or unifi-portforwards.json not present)."
fi

echo ""
echo "==> Done! All services are starting."
echo ""
echo "  Service web UIs (replace <host> with your server's IP or hostname):"
echo "    Emby:         http://<host>:8096"
echo "    Sonarr:       http://<host>:8989"
echo "    Radarr:       http://<host>:7878"
echo "    Jackett:      http://<host>:9117"
echo "    Deluge:       http://<host>:8112"
echo "    FlareSolverr: http://<host>:8191"
echo ""
echo "  SMB share: smb://<host>/extmedia (guest access, no password)"
echo ""
echo "  To manage services:"
echo "    ssh $TARGET \"cd $MEDIA_ROOT/config/services && sg docker -c 'docker compose ps'\""
