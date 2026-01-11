# SentryLab-Docker

Docker containers monitoring for Proxmox VMs/CTs with integration via MQTT (Home Assistant oritented).

## Overview

SentryLab-Docker deploys lightweight Docker monitoring containers to your Proxmox VMs and CTs. Each monitored host reports container status to your MQTT broker, automatically creating Home Assistant entities for easy monitoring.

## Features

- ✅ Automatic Home Assistant MQTT discovery
- ✅ Deploy to multiple Proxmox VMs/CTs from one command
- ✅ Monitors container status, uptime, health, and more
- ✅ Lightweight (50MB RAM per host)
- ✅ Secure (Docker socket stays local)
- ✅ Shared configuration with SentryLab-PVE

## Prerequisites

Common to SentryLab-PVE / SentryLab-Docker 

- Proxmox VE host
- MQTT broker (e.g., Mosquitto)
- Home Assistant with MQTT integration

Subject of monitoring

- One or many VMs/CTs with Docker installed

## Quick Start

### 1. Install on Proxmox Host

```bash
git clone https://github.com/CmPi/SentryLab-Docker.git
cd SentryLab-Docker
sudo ./install.sh
```

### 2. Configure

Edit the configuration file:

```bash
sudo nano /usr/local/etc/sentrylab.conf
```

Update if necessary these values:
```bash
BROKER="192.168.x.x"        # MQTT broker IP address or hostname
PORT="1883"                 # MQTT broker port (default: 1883, TLS: 8883)
USER="your_mqtt_user"       # MQTT username for authentication
PASS="your_mqtt_password"   # MQTT password for authentication
```

### 3. Deploy to VM/CT

```bash
sudo /usr/local/bin/sentrylab/setup-vmct.sh <VMID>
```

Example:
```bash
sudo /usr/local/bin/sentrylab/setup-vmct.sh 100
```

This will:
- Detect the VM/CT name automatically
- Deploy monitoring scripts to `/opt/sentrylab`
- Start the Docker monitoring container
- Register the devices/sensors in Home Assistant

## What Gets Installed

### On Proxmox Host

```
/usr/local/bin/sentrylab/
├── setup-vmct.sh              # Deployment script

/usr/local/etc/
└── sentrylab.conf             # Shared configuration

/usr/local/share/sentrylab/templates/
├── discovery.py               # HA discovery script
├── monitor.py                 # Container monitoring script
├── compose.yml                # Docker Compose config
└── startup.sh                 # Container startup script
```

### On Each VM/CT

```
/opt/sentrylab/
├── discovery.py
├── monitor.py
├── startup.sh
├── compose.yml
├── .env                       # Instance-specific config
└── logs/                      # Container logs
```

## Usage

### Deploy to Multiple VMs/CTs

```bash
# Deploy to CT 100
sudo /usr/local/bin/sentrylab/setup-vmct.sh 100

# Deploy to CT 101
sudo /usr/local/bin/sentrylab/setup-vmct.sh 101

# Deploy to CT 102
sudo /usr/local/bin/sentrylab/setup-vmct.sh 102
```

### View Logs

```bash
# From Proxmox host
pct exec 100 -- docker logs sentrylab -f

# Inside the CT
docker logs sentrylab -f
```

### Restart Monitoring

```bash
# From Proxmox host
pct exec 100 -- bash -c 'cd /opt/sentrylab && docker compose restart'

# Inside the CT
cd /opt/sentrylab && docker compose restart
```

### Re-run Discovery (After Adding Containers)

```bash
# From Proxmox host
pct exec 100 -- docker exec sentrylab python /app/discovery.py

# Inside the CT
docker exec sentrylab python /app/discovery.py
```

## Home Assistant Integration

After deployment, entities will automatically appear in Home Assistant under the MQTT integration.

### Entities Created Per Host

**Summary Sensors:**
- `sensor.docker_HOSTNAME_total_containers`
- `sensor.docker_HOSTNAME_running_containers`
- `sensor.docker_HOSTNAME_stopped_containers`

**Per Container:**
- `binary_sensor.CONTAINER_status` - Running/Stopped
- `sensor.CONTAINER_state` - Current state
- `sensor.CONTAINER_uptime` - Time since started
- `sensor.CONTAINER_health` - Health check status
- `sensor.CONTAINER_image` - Image name

### Example Dashboard

```yaml
type: entities
title: Docker Monitoring
entities:
  - sensor.docker_vm100_total_containers
  - sensor.docker_vm100_running_containers
  - sensor.docker_vm101_total_containers
  - sensor.docker_vm101_running_containers
```

### Example Automation

```yaml
automation:
  - alias: "Alert on Container Stop"
    trigger:
      - platform: state
        entity_id: binary_sensor.nginx_status
        to: 'off'
    action:
      - service: notify.mobile_app
        data:
          message: "Nginx container stopped!"
```

## Configuration

### Global Config (`/usr/local/etc/sentrylab.conf`)

```bash
# MQTT Broker Settings
MQTT_BROKER="192.168.1.100"
MQTT_PORT="1883"
MQTT_USERNAME="homeassistant"
MQTT_PASSWORD="your_password"

# Home Assistant Settings
HA_DISCOVERY_PREFIX="homeassistant"

# Monitoring Settings
POLL_INTERVAL="30"              # Seconds between updates
LOG_LEVEL="INFO"                # DEBUG, INFO, WARNING, ERROR

# Deployment Settings
DEPLOY_PATH="/opt/sentrylab"    # Where to deploy on VM/CT
```

### Per-Instance Config (Auto-generated)

Each VM/CT gets a unique `.env` file at `/opt/sentrylab/.env`:

```bash
DEVICE_NAME="Docker vm100"      # Shows in Home Assistant
DEVICE_ID="docker_vm100"        # Unique identifier
# ... plus settings from global config
```

## Troubleshooting

### VM/CT Not Found

```
ERROR: VM/CT 100 not found
```

**Solution:** Check the VMID exists:
```bash
pct list    # For containers
qm list     # For VMs
```

### Docker Not Installed

```
ERROR: Docker is not installed on CT 100
```

**Solution:** Install Docker on the VM/CT first:
```bash
pct enter 100
curl -fsSL https://get.docker.com | sh
```

### No Entities in Home Assistant

**Check:**
1. MQTT broker is accessible from VM/CT
2. MQTT credentials are correct in config
3. Container is running: `docker ps | grep sentrylab`
4. Check logs: `docker logs sentrylab`

### Discovery Not Running

**Re-run discovery:**
```bash
pct exec 100 -- docker exec sentrylab python /app/discovery.py
```

## Advanced Usage

### Deploy to Multiple Hosts via Script

```bash
#!/bin/bash
# deploy-all.sh

VMIDS="100 101 102 103"

for vmid in $VMIDS; do
    echo "Deploying to VM/CT $vmid..."
    /usr/local/bin/sentrylab/setup-vmct.sh $vmid
    echo ""
done
```

### Custom Deployment Path

Edit `/usr/local/etc/sentrylab.conf`:
```bash
DEPLOY_PATH="/opt/custom/path"
```

### Disable Auto-Discovery on Restart

In the VM/CT's `.env` file:
```bash
RUN_DISCOVERY_ON_STARTUP=false
```

## Uninstall

### Remove from VM/CT

```bash
pct exec 100 -- bash -c 'cd /opt/sentrylab && docker compose down'
pct exec 100 -- rm -rf /opt/sentrylab
```

### Remove from Proxmox Host

```bash
sudo rm -rf /usr/local/bin/sentrylab
sudo rm -rf /usr/local/share/sentrylab
sudo rm /usr/local/etc/sentrylab.conf
```

## Related Projects

- **SentryLab-PVE**: Proxmox host monitoring (shares same config file)

## Support

For issues and feature requests, please use GitHub Issues.

## License

MIT License

## Author

CmPi
