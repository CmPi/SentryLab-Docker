#!/bin/bash
#
# @file setup-vmct.sh
# @author CmPi <github.com/CmPi>
# @brief Deploy SentryLab monitoring to Proxmox VM or CT
# @date 2026-01-11
# @version 0.1.11
#

# DONE: 
#  * Use utils.sh (to load config, print messages, etc.)
#  * Publish discovery messages after setup and related to the while VMCT (*.py will deal with docker inside)
#   discovery topics: 
#     - homeassistant/sl_docker_<proxmox_hostname>_<vmct id>_deployed/config
#     - homeassistant/sl_docker_<proxmox_hostname>_<vmct id>_deployed_time/config
#     - homeassistant/sl_docker_<proxmox_hostname>_<vmct id>_last_discovery_time/config
#     - homeassistant/sl_docker_<proxmox_hostname>_<vmct id>_last_monitor_time/config
#  * Publish data topics after setup and related to the while VMCT (*.py will deal with docker inside)
#   data topics:
#     - sl_docker/<proxmox_hostname>/<vmct id>/deployed - Value: true (retained)
#     - sl_docker/<proxmox_hostname>/<vmct id>/deployed_time - Value: true (retained)

# TODO

#  when launched, discovery.py shall publish data (NOW) under:
#     - sl_docker/<proxmox_hostname>/<vmct id>/last_discovery_time (retained)
#  when launched, monitor.py shall publish data (NOW) under:
#     - sl_docker/<proxmox_hostname>/<vmct id>/last_monitor_time


set -e

PROXMOX_NODE=$(hostname -s)

CONFIG_FILE="/usr/local/etc/sentrylab.conf"
TEMPLATES_DIR="/usr/local/share/sentrylab/templates"
UTILS_FILE="/usr/local/bin/sentrylab/utils.sh"

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Run install.sh first!"
    exit 1
fi

# Source configuration
source "$CONFIG_FILE"

# Source utils.sh for MQTT publishing and logging functions
if [ -f "$UTILS_FILE" ]; then
    # Set INTERACTIVE mode for setup script
    INTERACTIVE=true
    source "$UTILS_FILE"
else
    echo "WARNING: utils.sh not found, MQTT publishing will be skipped"
    echo "         Expected at: $UTILS_FILE"
    # Define stub functions if utils.sh not available
    mqtt_publish_retain() { return 0; }
fi

box_title "SentryLab-Docker - VM/CT Setup"

box_begin "Prerequisites Checks"

# Check required variables
if [ -z "$BROKER" ]; then
    box_line "ERROR: BROKER not set in $CONFIG_FILE"
    box_end
    exit 1
fi

# Use DOCKER_* variables from config, with defaults
DEPLOY_PATH="${DOCKER_DEPLOY_PATH:-/opt/sentrylab}"
POLL_INTERVAL="${DOCKER_POLL_INTERVAL:-30}"
LOG_LEVEL="${DOCKER_LOG_LEVEL:-INFO}"
RUN_DISCOVERY="${DOCKER_RUN_DISCOVERY_ON_STARTUP:-true}"

# Check VMID parameter
if [ -z "$1" ]; then
    echo "Usage: $0 <VMID>"
    echo ""
    echo "Deploy SentryLab-Docker monitoring to a Proxmox VM/CT"
    echo ""
    echo "Example: $0 100"
    echo ""
    exit 1
fi

VMID="$1"

echo "================================================"
echo "SentryLab-Docker VM/CT Setup"
echo "Version 1.0.0"
echo "================================================"
echo ""

# Check if VM/CT exists
if ! pct status "$VMID" &>/dev/null && ! qm status "$VMID" &>/dev/null; then
    PROXMOX_NODE=$(hostname -s)
    echo "ERROR: VM/CT $VMID not found on node $PROXMOX_NODE"
    echo ""
    echo "Available containers:"
    pct list 2>/dev/null || echo "  (none)"
    echo ""
    echo "Available VMs:"
    qm list 2>/dev/null || echo "  (none)"
    exit 1
fi

# Get Proxmox hostname early for status publishing
PROXMOX_HOST=$(hostname -s | tr '[:upper:]' '[:lower:]')

# Publish initial VM/CT status discovery and data (status: absent)
if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    HA_DISCOVERY_PREFIX="${HA_BASE_TOPIC:-homeassistant}"
    DEVICE_JSON=$(jq -n \
        --arg id "docker_${PROXMOX_HOST}_${VMID}" \
        --arg name "SentryLab Docker VM/CT" \
        --arg model "SentryLab-Docker" \
        --arg mfr "SentryLab" \
        '{identifiers: [$id], name: $name, model: $model, manufacturer: $mfr}')
    
    # VM/CT status discovery
    VMCT_STATUS_CONFIG=$(jq -n \
        --argjson dev "$DEVICE_JSON" \
        --arg topic "sl_docker/${PROXMOX_HOST}/${VMID}/status" \
        '{
            name: "VM/CT Status",
            unique_id: "'${PROXMOX_HOST}'_'${VMID}'_status",
            state_topic: $topic,
            value_template: "{{ value_json }}",
            device: $dev,
            icon: "mdi:server"
        }')
    mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/sensor/sl_${PROXMOX_HOST}_${VMID}_status/config" \
        "$(echo "$VMCT_STATUS_CONFIG" | jq -c .)"
fi

# Determine if it's a CT or VM
IS_CT=false
if pct status "$VMID" &>/dev/null; then
    IS_CT=true
    VM_NAME=$(pct config "$VMID" | grep "^hostname:" | awk '{print $2}')
    VM_TYPE="CT"
else
    VM_NAME=$(qm config "$VMID" | grep "^name:" | awk '{print $2}')
    VM_TYPE="VM"
fi

# Use VMID if name is empty
if [ -z "$VM_NAME" ]; then
    VM_NAME="vm${VMID}"
fi

# Get Proxmox hostname for consistent topic hierarchy
PROXMOX_HOST=$(hostname -s | tr '[:upper:]' '[:lower:]')

# Generate device identifiers matching topic hierarchy: sl_docker/<proxmox_node>/<vmid>
DEVICE_NAME="Docker ${VM_NAME} (${PROXMOX_HOST})"
DEVICE_ID="docker_${PROXMOX_HOST}_${VMID}"

echo "VM/CT ID:    $VMID"
echo "Type:        $VM_TYPE"
echo "Name:        $VM_NAME"
echo "Device Name: $DEVICE_NAME"
echo "Device ID:   $DEVICE_ID"
echo "Deploy Path: $DEPLOY_PATH"
echo ""

# Check if VM/CT is running
if [ "$IS_CT" = true ]; then
    STATUS=$(pct status "$VMID" | awk '{print $2}')
else
    STATUS=$(qm status "$VMID" | awk '{print $2}')
fi

if [ "$STATUS" != "running" ]; then
    echo "WARNING: $VM_TYPE $VMID is not running (status: $STATUS)"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Publish VM/CT status data (running or stopped)
if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    VMCT_STATUS_VALUE="running"
    if [ "$STATUS" != "running" ]; then
        VMCT_STATUS_VALUE="stopped"
    fi
    mqtt_publish_retain "sl_docker/${PROXMOX_HOST}/${VMID}/status" "$VMCT_STATUS_VALUE"
fi

# Function to execute commands in CT
exec_cmd() {
    if [ "$IS_CT" = true ]; then
        pct exec "$VMID" -- "$@"
    else
        echo "ERROR: VM deployment not yet supported"
        echo "Please use CT (container) for now"
        exit 1
    fi
}

# ==============================================================================
# DEBUG MODE: Skip Docker deployment and only simulate MQTT publication
# ==============================================================================
if [ "${DEBUG:-false}" = "true" ]; then
    box_begin "DEBUG MODE - Simulation Only"
    box_line ""
    box_line "Docker deployment and Python scripts are DISABLED"
    box_line "Only simulating MQTT configuration publication"
    box_line ""
    box_end
else
    # ==============================================================================
    # NORMAL MODE: Deploy Docker container and scripts
    # ==============================================================================
    
    # Check if Docker is installed
    echo "Checking Docker installation..."
    if ! exec_cmd which docker &>/dev/null; then
        echo "ERROR: Docker is not installed on $VM_TYPE $VMID"
        echo ""
        echo "To install Docker, enter the CT and run:"
        echo "  pct enter $VMID"
        echo "  curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
    echo "✓ Docker is installed"
    echo ""
    
    # Publish Docker status discovery and data (running)
    if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
        HA_DISCOVERY_PREFIX="${HA_BASE_TOPIC:-homeassistant}"
        DEVICE_JSON=$(jq -n \
            --arg id "docker_${PROXMOX_HOST}_${VMID}" \
            --arg name "SentryLab Docker VM/CT" \
            --arg model "SentryLab-Docker" \
            --arg mfr "SentryLab" \
            '{identifiers: [$id], name: $name, model: $model, manufacturer: $mfr}')
        
        # Docker status discovery
        DOCKER_STATUS_CONFIG=$(jq -n \
            --argjson dev "$DEVICE_JSON" \
            --arg topic "sl_docker/${PROXMOX_HOST}/${VMID}/docker_status" \
            '{
                name: "Docker Status",
                unique_id: "'${PROXMOX_HOST}'_'${VMID}'_docker_status",
                state_topic: $topic,
                value_template: "{{ value_json }}",
                device: $dev,
                icon: "mdi:docker"
            }')
        mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/sensor/sl_${PROXMOX_HOST}_${VMID}_docker_status/config" \
            "$(echo "$DOCKER_STATUS_CONFIG" | jq -c .)"
        
        # Publish Docker status data (running)
        mqtt_publish_retain "sl_docker/${PROXMOX_HOST}/${VMID}/docker_status" "running"
    fi

    # Create deployment directory
    echo "Creating deployment directory..."
    exec_cmd mkdir -p "$DEPLOY_PATH/logs"
    echo "✓ Directory created: $DEPLOY_PATH"
    echo ""

    # Copy files
    echo "Deploying files..."

    pct push "$VMID" "$TEMPLATES_DIR/discovery.py" "$DEPLOY_PATH/discovery.py"
    echo "✓ Copied: discovery.py"

    pct push "$VMID" "$TEMPLATES_DIR/monitor.py" "$DEPLOY_PATH/monitor.py"
    echo "✓ Copied: monitor.py"

    pct push "$VMID" "$TEMPLATES_DIR/startup.sh" "$DEPLOY_PATH/startup.sh"
    echo "✓ Copied: startup.sh"

    # Copy VERSION file
    if [ -f "/usr/local/share/sentrylab/VERSION" ]; then
        pct push "$VMID" "/usr/local/share/sentrylab/VERSION" "$DEPLOY_PATH/VERSION"
        echo "✓ Copied: VERSION"
    else
        echo "⚠ VERSION file not found, creating default"
        exec_cmd bash -c "echo 'unknown' > $DEPLOY_PATH/VERSION"
    fi

    # Create compose.yml with substituted DEPLOY_PATH
    sed "s|DEPLOY_PATH|$DEPLOY_PATH|g" "$TEMPLATES_DIR/compose.yml" > /tmp/compose.yml.tmp
    pct push "$VMID" /tmp/compose.yml.tmp "$DEPLOY_PATH/compose.yml"
    rm /tmp/compose.yml.tmp
    echo "✓ Copied: compose.yml"

    echo ""

    # Generate .env file from sentrylab.conf
    echo "Generating .env configuration..."

    # Create .env content
    ENV_CONTENT="# SentryLab-Docker Configuration
# Auto-generated from /usr/local/etc/sentrylab.conf
# Date: $(date)

# MQTT Configuration (from sentrylab.conf)
BROKER=$BROKER
PORT=$PORT
USER=$USER
PASS=$PASS

# Home Assistant Integration
HA_BASE_TOPIC=$HA_BASE_TOPIC

# Proxmox Information (for topic hierarchy)
PROXMOX_HOST=$PROXMOX_HOST
PROXMOX_VMID=$VMID

# Device Configuration (generated)
DEVICE_NAME=$DEVICE_NAME
DEVICE_ID=$DEVICE_ID

# Monitoring Settings
POLL_INTERVAL=$POLL_INTERVAL
LOG_LEVEL=$LOG_LEVEL
RUN_DISCOVERY_ON_STARTUP=$RUN_DISCOVERY

# Debug Mode
DEBUG=$DEBUG
"

    # Write .env file to CT
    exec_cmd bash -c "cat > $DEPLOY_PATH/.env" << EOF
$ENV_CONTENT
EOF

    echo "✓ Configuration created: .env"
    echo ""

    # Make scripts executable
    exec_cmd chmod +x "$DEPLOY_PATH/discovery.py"
    exec_cmd chmod +x "$DEPLOY_PATH/monitor.py"
    exec_cmd chmod +x "$DEPLOY_PATH/startup.sh"

    # Start the service
    echo "Starting Docker monitoring service..."
    exec_cmd bash -c "cd $DEPLOY_PATH && docker compose up -d"
    echo "✓ Service started"
    echo ""

    echo "================================================"
    echo "Deployment Complete!"
    echo "================================================"
    echo ""
    echo "VM/CT:      $VM_NAME ($VMID)"
    echo "Device ID:  $DEVICE_ID"
    echo "Path:       $DEPLOY_PATH"
    echo ""
    echo "Useful commands:"
    echo ""
    echo "  View logs:"
    echo "    pct exec $VMID -- docker logs sentrylab -f"
    echo ""
    echo "  Restart service:"
    echo "    pct exec $VMID -- bash -c 'cd $DEPLOY_PATH && docker compose restart'"
    echo ""
    echo "  Re-run discovery:"
    echo "    pct exec $VMID -- docker exec sentrylab python /app/discovery.py"
    echo ""
    echo "  Stop service:"
    echo "    pct exec $VMID -- bash -c 'cd $DEPLOY_PATH && docker compose down'"
    echo ""
fi

# ============================================================================
# Publish VM/CT-level discovery and data topics to MQTT
# ============================================================================

if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    echo ""
    echo "Publishing Home Assistant discovery topics..."
    
    # Get Proxmox hostname for topic hierarchy
    PROXMOX_HOST=$(hostname -s | tr '[:upper:]' '[:lower:]')
    BASE_TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}"
    HA_DISCOVERY_PREFIX="${HA_BASE_TOPIC:-homeassistant}"
    
    # Create device info for Home Assistant
    DEVICE_JSON=$(jq -n \
        --arg id "docker_${PROXMOX_HOST}_${VMID}" \
        --arg name "Docker ${VM_NAME}" \
        --arg model "SentryLab-Docker" \
        --arg mfr "SentryLab" \
        '{identifiers: [$id], name: $name, model: $model, manufacturer: $mfr}')
    
    # 1. Deployed status binary sensor
    DEPLOYED_CONFIG=$(jq -n \
        --argjson dev "$DEVICE_JSON" \
        --arg topic "${BASE_TOPIC}/deployed" \
        '{
            name: "Deployed",
            unique_id: "'${PROXMOX_HOST}'_'${VMID}'_deployed",
            state_topic: $topic,
            value_template: "{{ value_json }}",
            payload_on: "true",
            payload_off: "false",
            device_class: "connectivity",
            device: $dev
        }')
    mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/binary_sensor/sl_docker_${PROXMOX_HOST}_${VMID}_deployed/config" \
        "$(echo "$DEPLOYED_CONFIG" | jq -c .)"
    
    # 2. Deployed time sensor
    DEPLOYED_TIME_CONFIG=$(jq -n \
        --argjson dev "$DEVICE_JSON" \
        --arg topic "${BASE_TOPIC}/deployed_time" \
        '{
            name: "Deployed Time",
            unique_id: "'${PROXMOX_HOST}'_'${VMID}'_deployed_time",
            state_topic: $topic,
            value_template: "{{ value_json }}",
            device_class: "timestamp",
            device: $dev
        }')
    mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/sensor/sl_docker_${PROXMOX_HOST}_${VMID}_deployed_time/config" \
        "$(echo "$DEPLOYED_TIME_CONFIG" | jq -c .)"
    
    # 3. Last discovery time sensor
    DISCOVERY_TIME_CONFIG=$(jq -n \
        --argjson dev "$DEVICE_JSON" \
        --arg topic "${BASE_TOPIC}/last_discovery_time" \
        '{
            name: "Last Discovery Time",
            unique_id: "'${PROXMOX_HOST}'_'${VMID}'_last_discovery_time",
            state_topic: $topic,
            value_template: "{{ value_json }}",
            device_class: "timestamp",
            device: $dev
        }')
    mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/sensor/sl_docker_${PROXMOX_HOST}_${VMID}_last_discovery_time/config" \
        "$(echo "$DISCOVERY_TIME_CONFIG" | jq -c .)"
    
    # 4. Last monitor time sensor
    MONITOR_TIME_CONFIG=$(jq -n \
        --argjson dev "$DEVICE_JSON" \
        --arg topic "${BASE_TOPIC}/last_monitor_time" \
        '{
            name: "Last Monitor Time",
            unique_id: "'${PROXMOX_HOST}'_'${VMID}'_last_monitor_time",
            state_topic: $topic,
            value_template: "{{ value_json }}",
            device_class: "timestamp",
            device: $dev
        }')
    mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/sensor/sl_docker_${PROXMOX_HOST}_${VMID}_last_monitor_time/config" \
        "$(echo "$MONITOR_TIME_CONFIG" | jq -c .)"
    
    # Publish initial data topics
    echo "Publishing data topics..."
    DEPLOYED_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    mqtt_publish_retain "${BASE_TOPIC}/deployed" "true"
    mqtt_publish_retain "${BASE_TOPIC}/deployed_time" "$DEPLOYED_TIMESTAMP"
    
    echo "✓ Discovery and data topics published"
else
    echo ""
    echo "⚠ MQTT publishing skipped (utils.sh or BROKER not available)"
fi