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

# -- Step 2: Install Docker ------------------------------------------------

echo ""
echo "==> Step 2: Installing Docker"

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

# -- Step 3: Add user to docker group -------------------------------------

echo ""
echo "==> Step 3: Configuring Docker group"

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

# -- Step 4: Configure Docker daemon --------------------------------------

echo ""
echo "==> Step 4: Configuring Docker daemon"

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

# -- Step 5: Detect and mount external drive -------------------------------

echo ""
echo "==> Step 5: Mounting external drive"

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

# -- Step 6: Deploy config files ------------------------------------------

echo ""
echo "==> Step 6: Deploying config files"

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

# -- Step 7: Start services ------------------------------------------------

echo ""
echo "==> Step 7: Starting services"

ssh "$TARGET" "bash -s" <<REMOTE_SCRIPT
set -euo pipefail
cd "$MEDIA_ROOT/config/services"
sg docker -c 'docker compose pull'
sg docker -c 'docker compose up -d'
REMOTE_SCRIPT

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
