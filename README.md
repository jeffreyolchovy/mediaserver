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
* A UniFi gateway API key (optional; only for the port-forward reconciler)

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

1. Install prerequisites (curl, jq)
2. Scope Avahi mDNS to physical interfaces (so `<host>.local` never resolves
   to a Docker bridge IP)
3. Install Docker
4. Add your user to the `docker` group
5. Configure the Docker daemon (custom DNS)
6. Detect and mount the external USB drive
7. Deploy all config files
8. Pull images and start all 9 services
9. Make the systemd journal persistent (bounded: 200M / 1 month)
10. Install the watchdog (systemd timer; see [Watchdog](#watchdog))
11. *(Optional)* Install the UniFi port-forward reconciler (see
    [UniFi Port-Forward Reconciler](#unifi-port-forward-reconciler))

Each step is idempotent, so it's safe to re-run if interrupted. Host files
from steps 9-11 are only rewritten when their contents differ, and services
are only reloaded when something actually changed.

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
# If the watchdog is installed, mask it first so it doesn't restart the
# stack before the Pi halts (it runs 'docker compose up -d' for any
# stopped container):
sudo systemctl mask --now mediaserver-watchdog.timer

cd /mnt/extmedia/config/services && sg docker -c 'docker compose stop'
sudo shutdown -h now
```

Use `stop`, not `down`. `stop` halts the containers but keeps them
defined; `down` *removes* them.

**After boot, bring the stack back up explicitly:**

```bash
cd /mnt/extmedia/config/services && sg docker -c 'docker compose up -d'
sudo systemctl unmask mediaserver-watchdog.timer
sudo systemctl enable --now mediaserver-watchdog.timer
```

`restart: unless-stopped` deliberately does **not** restart a container
you stopped yourself, even across a reboot. That's the difference from
`always`. If the watchdog is enabled when the Pi boots, it will start any
stopped containers about 2 minutes after boot, but don't count on it
across a move, because you masked it above. `docker compose up -d` is
idempotent: it's a no-op for anything already running.

If the new location has a different LAN subnet, update `LOCAL_SUBNET` in
`/mnt/extmedia/config/services/.env` and run
`docker compose up -d --force-recreate vpn deluge` (see
[LAN Subnet](#lan-subnet-local_subnet)).

## Configuration Reference

### LAN Subnet (`LOCAL_SUBNET`)

Deluge runs inside the VPN container's network namespace, behind a
kill-switch that sends everything through the tunnel. For LAN clients to
reach the Deluge web UI (`:8112`), the VPN container needs a direct return
route to your LAN. Set it in `config/.env`:

```
LOCAL_SUBNET=192.168.1.0/24
```

It defaults to `192.168.1.0/24`. If Deluge's web UI hangs while every
other service loads, this value almost certainly doesn't match your LAN.
On a running server, edit `/mnt/extmedia/config/services/.env`, then run
`docker compose up -d --force-recreate vpn deluge`.

### Watchdog

Step 10 installs `/usr/local/sbin/mediaserver-watchdog.sh`, run by
`mediaserver-watchdog.timer` every 15 minutes (first run 2 minutes after
boot). It handles:

| Condition | Action |
|---|---|
| Expected container stopped/missing | `docker compose up -d <name>` |
| Container unhealthy with `Health.FailingStreak` > 10 | `docker compose restart <name>` -- **torrenting stack only** (vpn, deluge, jackett, flaresolverr); other services are logged, not restarted |
| VPN egress empty or equal to the host's public IP (tunnel down) | `docker compose restart vpn` (deluge follows) |
| Empty leaf directories under `complete/{tv,movies}` | removed |

It's silent when everything is healthy, uses a 10-minute per-container
cooldown to avoid flapping, and logs only to journald:

```bash
sudo journalctl -u mediaserver-watchdog.service -n 50
sudo systemctl start mediaserver-watchdog.service   # run it now
```

### Persistent Logs

Step 9 moves the systemd journal from RAM to disk
(`/etc/systemd/journald.conf.d/persistent.conf`), bounded to 200M / 1
month. Logs survive reboots and power loss, so after an unexpected
restart you can see how the previous boot ended:

```bash
journalctl --list-boots
journalctl -b -1 -n 100    # tail of the previous boot
```

### UniFi Port-Forward Reconciler

*Optional; only relevant behind a UniFi gateway (UDM / UDM Pro / UDM SE).*

UniFi firmware upgrades can silently delete every port-forward rule. Step
11 installs an hourly timer (`unifi-portforward-reconcile.timer`, plus a
run 3 minutes after boot) that re-creates any missing rule through the
gateway's local API.

To enable it, create both files from their templates, then run (or
re-run) `install.sh`:

```bash
cp config/unifi/unifi.env.example config/unifi/unifi.env
cp config/unifi/unifi-portforwards.json.example config/unifi/unifi-portforwards.json
```

- `unifi.env` holds the gateway address, an API key (UniFi Network ->
  Settings -> Control Plane -> Integrations), and the server's LAN IP.
  The installer puts it on the server as `/etc/mediaserver/unifi.env`,
  root-only (0600).
- `unifi-portforwards.json` lists the forwards to keep in place.

The reconciler only **adds** rules and never deletes them. To remove a
forward, delete it from `unifi-portforwards.json`, re-run `install.sh`,
and *then* delete the rule on the gateway. Otherwise the next hourly run
will put it back.

Only forward services that are meant to be public and have real
authentication (Emby). Sonarr, Radarr, Jackett and Deluge log in over
plain HTTP; exposing them sends credentials across the internet in
cleartext.

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
│   ├── journald/
│   │   └── persistent.conf    # Persistent, bounded journald drop-in
│   ├── samba/
│   │   └── config.yml         # Samba share configuration
│   ├── unifi/                 # Optional UniFi port-forward reconciler
│   │   ├── unifi-portforward-reconcile.sh
│   │   ├── unifi-portforward-reconcile.service
│   │   ├── unifi-portforward-reconcile.timer
│   │   ├── unifi.env.example
│   │   └── unifi-portforwards.json.example
│   ├── vpn/
│   │   ├── ca.rsa.2048.crt    # PIA CA certificate
│   │   ├── vpn.conf.example   # Template for OpenVPN configuration
│   │   └── vpn.auth.example   # Template for VPN credentials
│   └── watchdog/
│       ├── mediaserver-watchdog.sh
│       ├── mediaserver-watchdog.service
│       └── mediaserver-watchdog.timer
├── README.md
├── UNLICENSE
└── .gitignore
```

Files you create from templates (not committed):

* `config/.env` -- Compose environment variables (contains DuckDNS token)
* `config/vpn/vpn.conf` -- OpenVPN config (contains server choice)
* `config/vpn/vpn.auth` -- PIA credentials
* `config/unifi/unifi.env` -- *(optional)* UniFi API key and addresses
* `config/unifi/unifi-portforwards.json` -- *(optional)* desired port-forwards

## License

This project is released into the public domain. See [UNLICENSE](UNLICENSE).
