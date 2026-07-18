# mediaserver

Install and provision a Raspberry Pi as a Docker-based home media server.

Runs containerized instances of Emby, Sonarr, Radarr, Jackett, Deluge,
FlareSolverr, Samba, DuckDNS, and an OpenVPN client. All application data
and configuration lives on an external USB hard drive, keeping the SD card
disposable.

## Services

| Service | Port | Purpose |
|---------|------|---------|
| Emby | 8096 | Media server |
| Sonarr | 8989 | TV show management |
| Radarr | 7878 | Movie management |
| Jackett | 9117 | Torrent indexer proxy |
| Deluge | 8112 | Torrent client (routed through VPN) |
| FlareSolverr | 8191 | Cloudflare bypass for Jackett |
| DuckDNS | -- | Dynamic DNS updates |
| VPN | -- | PIA OpenVPN tunnel |
| Samba | 445 | SMB file sharing (guest access) |

## Requirements

### Hardware

* Raspberry Pi 4 Model B (4GB RAM recommended)
* MicroSD card (32GB+)
* USB-C power supply
* External USB hard drive (ext4 formatted)

### Software

The install script handles all software installation on the Pi. On your
local machine you just need:

* SSH access to the Pi (key-based auth, no password prompt)

### Accounts

* [Private Internet Access](https://www.privateinternetaccess.com/) VPN
  subscription (for Deluge traffic)
* [DuckDNS](https://www.duckdns.org/) subdomain and token (optional, for
  dynamic DNS)

## Quick Start

### 1. Flash the OS

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to write
Raspberry Pi OS (64-bit) to the MicroSD card. Configure WiFi, hostname, and
your user account in the imager settings.

### 2. Set up SSH access

Boot the Pi, then from your local machine:

```bash
ssh-copy-id user@hostname.local
```

Verify passwordless login works:

```bash
ssh user@hostname.local 'echo connected'
```

### 3. Reserve a static IP

Log into your router and create a DHCP reservation for the Pi so its IP
address doesn't change.

### 4. Configure

Clone this repo and create your config files from the templates:

```bash
cp config/.env.example config/.env
cp config/vpn/vpn.conf.example config/vpn/vpn.conf
cp config/vpn/vpn.auth.example config/vpn/vpn.auth
```

Edit each file:

* **`config/.env`** -- Set your DuckDNS subdomain and token. Adjust timezone
  and UID/GID if needed.
* **`config/vpn/vpn.conf`** -- Replace `<geography>` with your preferred PIA
  server region (e.g., `ca-toronto`, `us-east`). See PIA's
  [server list](https://www.privateinternetaccess.com/pages/network/).
* **`config/vpn/vpn.auth`** -- Your PIA username on line 1, password on
  line 2.

### 5. Install

```bash
./install.sh user@hostname.local
```

The script will:

1. Install Docker on the Pi
2. Configure the Docker daemon (custom DNS)
3. Detect and mount the external USB drive
4. Deploy all config files
5. Pull images and start all 9 services

Each step is idempotent -- safe to re-run if interrupted.

### 6. Verify

After install completes, check the service web UIs:

* Emby: `http://<host>:8096`
* Sonarr: `http://<host>:8989`
* Radarr: `http://<host>:7878`
* Jackett: `http://<host>:9117`
* Deluge: `http://<host>:8112`

The SMB share is available at `smb://<host>/extmedia` with guest access.

## Managing Services

SSH into the Pi and use Docker Compose:

```bash
# View running containers
cd /mnt/extmedia/config/services && sg docker -c 'docker compose ps'

# View logs for a service
sg docker -c 'docker compose logs sonarr'

# Restart a service
sg docker -c 'docker compose restart emby'

# Pull updated images and recreate
sg docker -c 'docker compose pull && docker compose up -d'
```

### Rebooting or Relocating the Server

When you need to reboot the Pi or physically move it, **stop the stack --
don't tear it down**:

```bash
cd /mnt/extmedia/config/services && sg docker -c 'docker compose stop'
sudo shutdown -h now
```

Use `stop`, not `down`. `stop` halts the containers but leaves them
defined, so Docker's `restart: unless-stopped` policy brings them back
automatically on the next boot. `down` *removes* the containers, which
means nothing auto-starts after reboot and you have to `docker compose
up -d` by hand.

## Configuration Reference

### VPN Region

Edit `config/vpn/vpn.conf` and change the `remote` line:

```
remote ca-toronto.privacy.network 1198
```

Replace `ca-toronto` with any PIA region. Redeploy with `./install.sh` or
manually copy the file and restart the VPN container.

### Samba

The Samba share is configured in `config/samba/config.yml`. It uses
[crazymax/samba](https://github.com/crazy-max/docker-samba) with WSDD2 for
network discovery. Guest access is enabled by default.

### Adding Media Directories

Media paths are defined in `config/docker-compose.yml` under the `emby`
service's volumes. Add new volume mounts and restart Emby to pick them up.

## Project Structure

```
mediaserver/
├── install.sh                 # Provisioning script (run from local machine)
├── config/
│   ├── docker-compose.yml     # Docker Compose service definitions
│   ├── .env.example           # Template for Compose environment variables
│   ├── daemon.json            # Docker daemon configuration
│   ├── samba/
│   │   └── config.yml         # Samba share configuration
│   └── vpn/
│       ├── ca.rsa.2048.crt    # PIA CA certificate
│       ├── vpn.conf.example   # Template for OpenVPN configuration
│       └── vpn.auth.example   # Template for VPN credentials
├── README.md
├── UNLICENSE
└── .gitignore
```

Files you create from templates (not committed):

* `config/.env` -- Compose environment variables (contains DuckDNS token)
* `config/vpn/vpn.conf` -- OpenVPN config (contains server choice)
* `config/vpn/vpn.auth` -- PIA credentials

## License

This project is released into the public domain. See [UNLICENSE](UNLICENSE).
