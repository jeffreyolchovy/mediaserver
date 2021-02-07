# mediaserver
A home media server powered by a Raspberry Pi 4 Model B. It leverages HypriotOS and containerized versions of Deluge, Jackett, Sonarr, Radarr, and Emby. Media and service configuration is stored on an external USB hard drive. A containerized Samba server enables remote file management.

* [Requirements](#requirements)
* [Assumptions](#assumptions)
* [Setup and Installation](#setup-and-installation)

## Requirements
* Raspberry Pi 4 Model B
* An _optional_ Raspberry Pi 4 case with integrated fan mount
* Low-noise system fan
* Set of heat sinks
* USB-C Raspberry Pi 4 power supply
* MicroSD card
* USB MicroSD card reader
* An external USB hard drive
* A supporting machine with an installation of `ansible`
* An _optional_, registered [duckdns.org](https://duckdns.org) subdomain

## Assumptions
* Raspberry 4 Model B 1.5GHz 64-bit quad-core ARMv8 CPU with 4GB RAM
* `ntfs` formatted external 4TB USB hard drive
* Working knowledge of ansible playbooks, Docker (in general), and docker-compose.yml files
* Verizon Fios supplied router

## Setup and Installation

### Setup hardware
1. Add heat sinks to Raspberry Pi.
2. Attach fan to GPIO board.
3. Install Raspberry Pi board into case, and fan into case top.

### Format MicroSD card with preferred OS (Hypriot)
1. Checkout a local copy of [https://github.com/hypriot/flash](https://github.com/hypriot/flash).
2. Create a copy of `sample/wifi-user-data.yml` and save as `wifi.yml` in your loacl repository's root directory.
3. Execute:

    ```sh
    ./flash --userdata wifi.yml https://github.com/hypriot/image-builder-rpi/releases/download/v1.11.5/hypriotos-rpi-v1.11.5.img.zip
    ```

4. When prompted, insert MicroSD card via USB dongle into supporting machine.
5. Follow the remaining prompts from flash utility.
6. Upon completion, install the MicroSD card into the Raspberry Pi.

### Test connection to Raspberry Pi
1. Power on the Raspberry Pi.
2. From the supporting machine attempt to ssh into the Raspberry Pi using `username@hostname` (entering your plain-text password when prompted). These credentials can be found in your `wifi.yml` configuration file from the previous step.

### Take out static DHCP lease on router (next steps assume Verizon Fios provided router)
1. Log in to the router's control plane at [http://192.168.1.1](http://192.168.1.1).
2. Using the top navigation menu, choose `Advanced`.
3. Then navigate to `IP Address Distribution`.
4. Navigate to `Connection List`.
5. Find your Raspberry Pi device and click `Edit`.
6. Enable the option to take out a static lease.
7. Note the local IP address that was allocated to the device.

If not using a Verizon Fios provided router, consult your router manufacturer's instructions on reserving a static IP address for your Raspberry Pi (i.e. see their instructions for Static DHCP or DHCP reservations).

### Setup passwordless access from supporting machine
1. Generate ssh key for supporting machine if not already present.
2. Copy your public key to the Raspberry Pi:

    ```sh
    cat .ssh/id_rsa.pub | ssh username@hostname 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
    ```

### Update ansible inventories
1. Navigate to ansible playbook directory on supporting machine.
2. Add hosts group to inventories/localhosts using hostname.local or IP address allocated to Raspberry Pi.
3. Add hosts group to inventories/hosts using externally accessible address (e.g. subdomain.duckdns.org), if desired.

### Execute ansible playbook
1. Execute `ansible -i inventories/localhosts mediaserver.yml` or `ansible -i inventories/hosts mediaserver.yml` to run the playbook. The services should be up and running momentarily.

Optionally follow the GUI configuration instructions for each of the desired services as described at [https://github.com/sebgl/htpc-download-box](https://github.com/sebgl/htpc-download-box).
