#!/bin/bash
#
# @file setup-vmct.sh
# @author CmPi <github.com/CmPi>
# @brief Deploy SentryLab monitoring to Proxmox VM or CT
# @date 2026-01-11
# @version 0.1.11
#

#
# SPECIFICATION:
# 1) Check prerequisites:
#    11) Check if config file exists and source it
#    12) Chechk if utils.sh exists and source it
#    13) Check if running on Proxmox
#    14) Check if running as root
#    15) Check required variables (BROKER, PORT, USER, PASS...)

# DONE: 
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

# 1) Prerequisites Checks

CONFIG_FILE="/usr/local/etc/sentrylab.conf"
TEMPLATES_DIR="/usr/local/share/sentrylab/templates"
UTILS_FILE="/usr/local/bin/sentrylab/utils.sh"

# 11) Check if config exists

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Run install.sh first!"
    exit 1
fi
source "$CONFIG_FILE"

# 12) Source utils.sh for MQTT publishing and logging functions

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


# Read repository VERSION (used in installer header)

S_VERSION="unknown"
if [ -f VERSION ]; then
    S_VERSION=$(cat VERSION)
fi

box_title "SentryLab-Docker v${S_VERSION} - VM/CT Setup"

box_begin "Prerequisites Checks"

# 13) Check if running on Proxmox (same behavior as install.sh)
if [ ! -f /etc/pve/.version ]; then
    box_line "⚠ Warning: This doesn't appear to be a Proxmox host"
    read -p "│ Continue anyway? (y/N): " -n 1 -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        box_end
        exit 1
    fi
fi

# 14) Check if running as root
if [[ $EUID -ne 0 ]]; then
    box_line "ERROR: This script must be run as root"
    box_end
    exit 1
fi

# 15) Check required variables (BROKER, PORT, USER, PASS, MQTT_QOS)
# If DEBUG is true we only warn; otherwise these are required.
if [[ "${DEBUG:-false}" == "true" ]]; then
    box_line "DEBUG mode: MQTT settings not strictly required (no publishing will occur)"
else
    local_bad=false
    if [ -z "${BROKER:-}" ]; then
        box_line "ERROR: BROKER not set in $CONFIG_FILE"
        local_bad=true
    fi
    if [ -z "${PORT:-}" ]; then
        box_line "ERROR: PORT not set in $CONFIG_FILE"
        local_bad=true
    else
        if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
            box_line "ERROR: PORT must be a number (found: $PORT)"
            local_bad=true
        fi
    fi
    if [ -z "${USER:-}" ]; then
        box_line "ERROR: USER not set in $CONFIG_FILE"
        local_bad=true
    fi
    if [ -z "${PASS:-}" ]; then
        box_line "ERROR: PASS not set in $CONFIG_FILE"
        local_bad=true
    fi
    if [ -z "${MQTT_QOS:-}" ]; then
        box_line "ERROR: MQTT_QOS not set in $CONFIG_FILE"
        local_bad=true
    else
        if ! [[ "$MQTT_QOS" =~ ^[0-2]$ ]]; then
            box_line "ERROR: MQTT_QOS must be 0, 1 or 2 (found: $MQTT_QOS)"
            local_bad=true
        fi
    fi
    if [ "$local_bad" = true ]; then
        box_end
        exit 1
    fi
fi

# Use DOCKER_* variables from config, with defaults
DEPLOY_PATH="${DOCKER_DEPLOY_PATH:-/opt/sentrylab}"
POLL_INTERVAL="${DOCKER_POLL_INTERVAL:-30}"
LOG_LEVEL="${DOCKER_LOG_LEVEL:-INFO}"
RUN_DISCOVERY="${DOCKER_RUN_DISCOVERY_ON_STARTUP:-true}"

# Check VMID parameter
if [ -z "$1" ]; then
    box_line "Usage: $0 <VMID>"
    box_line ""
    box_line "Deploy SentryLab-Docker monitoring to a Proxmox VM/CT"
    box_line ""
    box_line "Example: $0 100"
    box_line ""
    box_end
    exit 1
fi

VMID="$1"

# Check if VM/CT exists
if ! pct status "$VMID" &>/dev/null && ! qm status "$VMID" &>/dev/null; then
    PROXMOX_NODE=$(hostname -s)
    box_line "ERROR: VM/CT $VMID not found on node $PROXMOX_NODE"
    box_line ""
    box_line "Available containers:"
    pct list 2>/dev/null || echo "  (none)"
    box_line ""
    box_line "Available VMs:"
    qm list 2>/dev/null || echo "  (none)"
    box_end
    exit 1
fi

# Get Proxmox hostname early for status publishing
PROXMOX_HOST=$(hostname -s | tr '[:upper:]' '[:lower:]')


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

box_value "Proxmox node (PROXMOX_NODE)" "$PROXMOX_NODE"
box_value "VM/CT ID (VMID)" "$VMID"
box_value "VM/CT type (VM_TYPE)" "$VM_TYPE"
box_value "VM/CT name" "$VM_NAME"

# Publish initial VM/CT status discovery and data (status: absent)
if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    HA_DISCOVERY_PREFIX="${HA_BASE_TOPIC:-homeassistant}"
    DEVICE_JSON=$(jq -n \
        --arg id "sentrylab_${PROXMOX_HOST}_${VMID}" \
        --arg name "${VM_NAME} on ${PROXMOX_NODE}" \
        --arg model "${VM_TYPE}" \
        --arg mfr "SentryLab" \
        '{identifiers: [$id], name: $name, model: $model, manufacturer: $mfr}')
    
    # VM/CT status discovery
    VMCT_STATUS_CONFIG=$(jq -n \
        --arg name "${VM_TYPE} ${VM_NAME} Status" \
        --arg unique_id "${PROXMOX_HOST}_${VMID}_status" \
        --arg topic "sentrylab/${PROXMOX_HOST}/${VMID}/status" \
        --argjson dev "$DEVICE_JSON" \
        '{
            name: $name,
            unique_id: $unique_id,
            object_id: $unique_id,
            state_topic: $topic,
            value_template: "{{ value_json }}",
            device: $dev,
            icon: "mdi:server"
        }')
    mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/sensor/sl_${PROXMOX_HOST}_${VMID}_status/config" \
        "$(echo "$VMCT_STATUS_CONFIG" | jq -c .)"
fi

# Get Proxmox hostname for consistent topic hierarchy
PROXMOX_HOST=$(hostname -s | tr '[:upper:]' '[:lower:]')

# Generate device identifiers matching topic hierarchy: sl_docker/<proxmox_node>/<vmid>
DEVICE_NAME="Docker ${VM_NAME} (${PROXMOX_HOST})"
DEVICE_ID="docker_${PROXMOX_HOST}_${VMID}"

box_value "Type"        "$VM_TYPE"
box_value "Name"        "$VM_NAME"
box_value "Device Name" "$DEVICE_NAME"
box_value "Device ID"   "$DEVICE_ID"
box_value "Deploy Path" "$DEPLOY_PATH"
box_line ""

# Check if VM/CT is running
if [ "$IS_CT" = true ]; then
    STATUS=$(pct status "$VMID" | awk '{print $2}')
else
    STATUS=$(qm status "$VMID" | awk '{print $2}')
fi

# Publish VM/CT status data (running or stopped)
if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    VMCT_STATUS_VALUE="running"
    if [ "$STATUS" != "running" ]; then
        VMCT_STATUS_VALUE="stopped"
    fi
    mqtt_publish_retain "sentrylab/${PROXMOX_HOST}/${VMID}/status" "$VMCT_STATUS_VALUE"
fi

if [ "$STATUS" != "running" ]; then
    box_line "WARNING: $VM_TYPE $VMID is not running (status: $STATUS)"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
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
            --arg id "sl_${PROXMOX_HOST}_${VMID}" \
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

    # Copy VERSION file (renamed from SL_DOCKER_VERSION to VERSION inside container)
    if [ -f "/usr/local/share/sentrylab/SL_DOCKER_VERSION" ]; then
        pct push "$VMID" "/usr/local/share/sentrylab/SL_DOCKER_VERSION" "$DEPLOY_PATH/VERSION"
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