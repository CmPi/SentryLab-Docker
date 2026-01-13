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
# 2) Detect VM/CT status
#    21) Check if VM/CT exists
#    22) Check if it is a VM or a CT
#    23) Determine VM/CT name
#    24) Check if VM/CT is running

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


#set -e

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


# Use DOCKER_* variables from config, with defaults
LOG_LEVEL="${DOCKER_LOG_LEVEL:-INFO}"
RUN_DISCOVERY="${DOCKER_RUN_DISCOVERY_ON_STARTUP:-true}"



box_value "Proxmox node (PROXMOX_NODE)" "$PROXMOX_NODE"
box_value "VM/CT ID (VMID)" "$VMID"

# 2) Determine VM/CT status, type and name

S_VMCT_STATUS="unknown"
VM_TYPE="VM/CT"

# 21) Check if VM/CT exists
if ! pct status "$VMID" &>/dev/null && ! qm status "$VMID" &>/dev/null; then
    S_VMCT_STATUS="absent"
    PROXMOX_NODE=$(hostname -s)
    box_line "ERROR: VM/CT $VMID not found on node $PROXMOX_NODE"
    box_line ""
    box_line "Available containers:"
    pct list 2>/dev/null || echo "  (none)"
    box_line ""
    box_line "Available VMs:"
    qm list 2>/dev/null || echo "  (none)"
else
    # 22) Determine if it's a CT or VM
    IS_CT=false
    if pct status "$VMID" &>/dev/null; then
        IS_CT=true
        VM_NAME=$(pct config "$VMID" | grep "^hostname:" | awk '{print $2}')
        VM_TYPE="CT"
    else
        VM_NAME=$(qm config "$VMID" | grep "^name:" | awk '{print $2}')
        VM_TYPE="VM"
    fi
fi

# 23) Determine VM/CT name

# Use VMID if name is empty
if [ -z "$VM_NAME" ]; then
    VM_NAME="${VM_TYPE} ${VMID}"
fi

box_value "VM/CT type (VM_TYPE)" "$VM_TYPE"
box_value "VM/CT name" "$VM_NAME"

# Get Proxmox ID from hostname for consistent topic hierarchy
ID_PROXMOX=$(hostname -s | tr '[:upper:]' '[:lower:]')

DEVICE_JSON=$(jq -n \
    --arg id "sentrylab_${ID_PROXMOX}_${VMID}" \
    --arg name "${VM_NAME} on ${PROXMOX_NODE}" \
    --arg model "${VM_TYPE}" \
    --arg mfr "SentryLab" \
    '{identifiers: [$id], name: $name, model: $model, manufacturer: $mfr}')

HA_DISCOVERY_PREFIX="${HA_BASE_TOPIC:-homeassistant}"

# Publish initial VM/CT status discovery and data (status: absent)
if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    HA_ID="sentrylab_${ID_PROXMOX}_${VMID}_status"
    HA_LABEL=$(translate "vmct_status")
    VAL_TOPIC="sentrylab/${ID_PROXMOX}/${VMID}/status"
    CFG_TOPIC="${HA_DISCOVERY_PREFIX}/sensor/${HA_ID}/config"
    PAYLOAD=$(jq -n \
        --arg name "$HA_LABEL" \
        --arg unique_id "$HA_ID" \
        --arg topic "$VAL_TOPIC" \
        --argjson dev "$DEVICE_JSON" \
        '{
            name: $name,
            unique_id: $unique_id,
            object_id: $unique_id,
            state_topic: $topic,
            value_template: "{{ value }}",
            device: $dev,
            icon: "mdi:server"
        }')
    mqtt_publish_retain "$CFG_TOPIC" "$PAYLOAD"
fi

# Generate device identifiers matching topic hierarchy: sl_docker/<proxmox_node>/<vmid>
DEVICE_NAME="Docker ${VM_NAME} (${ID_PROXMOX})"
DEVICE_ID="docker_${ID_PROXMOX}_${VMID}"

box_value "Name"        "$VM_NAME"
box_value "Device Name" "$DEVICE_NAME"
box_value "Device ID"   "$DEVICE_ID"
box_line ""

# Assess VM/CT status

# 24) Check if VM/CT is running
if [ "$IS_CT" = true ]; then
    STATUS=$(pct status "$VMID" | awk '{print $2}')
else
    STATUS=$(qm status "$VMID" | awk '{print $2}')
fi

S_VMCT_STATUS="running"
if [ "$STATUS" != "running" ]; then
    S_VMCT_STATUS="stopped"
fi

box_line "VM/CT $VMID is $STATUS"

# Publish VM/CT status data (running or stopped)
if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    mqtt_publish_retain "$VAL_TOPIC" "$S_VMCT_STATUS"
else
    box_line "WARNING: MQTT broker not configured"    
fi


box_line "279 - S_VMCT_STATUS: $S_VMCT_STATUS"

# Depending on VM/CT status, go further and check broker status

if [ "$S_VMCT_STATUS" = "running" ]; then


    # Function to execute commands - works for both CT and VM
    exec_cmd() {
        if [ "$IS_CT" = true ]; then
            pct exec "$VMID" -- bash -c "$*"
            return $?
        else
            # For VM, use qm guest exec (requires qemu-guest-agent)
            qm guest exec "$VMID" -- bash -c "$*"
            return $?
        fi
    }

    # Initialize Docker availability flag
    DOCKER_AVAILABLE=false

    box_line "Checking system accessibility... 01h42"

    # For VMs, verify qemu-guest-agent is available
    if [ "$IS_CT" = false ]; then
        if ! qm guest ping "$VMID" >/dev/null 2>&1; then
            S_DOCKER_STATUS="unreachable"
            box_line "⚠ WARNING: Cannot communicate with VM $VMID"
            box_line "The qemu-guest-agent is not running or not installed."
            box_line ""
            box_line "To fix this:"
            box_line "  1. Access your VM console or SSH into it"
            box_line "  2. Install: apt-get install qemu-guest-agent"
            box_line "  3. Enable: systemctl enable --now qemu-guest-agent"
            box_line "  4. Wait ~10 seconds for Proxmox to detect it"
            box_line ""
            box_line "Continuing without Docker checks..."
        else
            box_line "✓ Guest agent is responding"
            
            box_line "Checking Docker installation..."
            
            # Try to find docker
            if DOCKER_BIN=$(exec_cmd "command -v docker" 2>/dev/null); then
                # Get Docker version for confirmation
                DOCKER_VERSION=$(exec_cmd "docker --version" 2>/dev/null | cut -d' ' -f3 | tr -d ',')
                
                # Check if Docker daemon is running
                if exec_cmd "docker ps" >/dev/null 2>&1; then
                    DOCKER_AVAILABLE=true
                    S_DOCKER_STATUS="running"
                    box_line "✓ Docker $DOCKER_VERSION is installed and running"
                else
                    S_DOCKER_STATUS="stopped"
                    box_line "⚠ WARNING: Docker is installed but daemon is not running"
                    box_line "Try: systemctl start docker"
                fi
            else
                S_DOCKER_STATUS="absent"
                box_line "⚠ WARNING: Docker is not installed on VM $VMID"
                box_line "To install: curl -fsSL https://get.docker.com | sh"
            fi
        fi
    else
        # Container checks
        box_line "Checking Docker installation..."
        
        if DOCKER_BIN=$(exec_cmd "command -v docker" 2>/dev/null); then
            DOCKER_VERSION=$(exec_cmd "docker --version" 2>/dev/null | cut -d' ' -f3 | tr -d ',')
            
            if exec_cmd "docker ps" >/dev/null 2>&1; then
                DOCKER_AVAILABLE=true
                S_DOCKER_STATUS="running"
                box_line "✓ Docker $DOCKER_VERSION is installed and running"
            else
                S_DOCKER_STATUS="stopped"
                box_line "⚠ WARNING: Docker is installed but daemon is not running"
                box_line "Try: systemctl start docker"
            fi
        else
            S_DOCKER_STATUS="absent"
            box_line "⚠ WARNING: Docker is not installed on CT $VMID"
            box_line "To install: pct enter $VMID && curl -fsSL https://get.docker.com | sh"
        fi
    fi

    # Continue with the rest of the script...
    box_line "Docker status: $S_DOCKER_STATUS"

    # Later in the script, you can check before Docker operations:
    if [ "$DOCKER_AVAILABLE" = true ]; then
        box_line "Proceeding with Docker operations..."
        # Do Docker stuff
    else
        box_line "⚠ Skipping Docker operations (Docker not available)"
        # Skip Docker-related tasks
    fi

    # Publish Docker status discovery and data (running)


    if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
        box_line "Publishing Docker status discovery... 2h26"

        HA_ID="sentrylab_${ID_PROXMOX}_${VMID}_docker_status"
        HA_LABEL=$(translate "vmct_docker_status")
        VAL_TOPIC="sentrylab/${ID_PROXMOX}/${VMID}/docker"
        CFG_TOPIC="${HA_DISCOVERY_PREFIX}/sensor/${HA_ID}/config"
        # Publish Docker status discovery
        PAYLOAD=$(jq -n \
            --arg name "$HA_LABEL" \
            --arg unique_id "$HA_ID" \
            --arg object_id "$HA_ID" \
            --arg topic "$VAL_TOPIC" \
            --argjson dev "$DEVICE_JSON" \
            '{
                name: $name,
                unique_id: $unique_id,
                object_id: $unique_id,
                state_topic: $topic,
                value_template: "{{ value_json.status }}",
                json_attributes_topic: $topic,
                device: $dev,
                icon: "mdi:docker"
            }')
        mqtt_publish_retain "$CFG_TOPIC" "$PAYLOAD"
        

        # Publish Docker version discovery

        HA_ID="sentrylab_${ID_PROXMOX}_${VMID}_docker_version"
        CFG_TOPIC="${HA_DISCOVERY_PREFIX}/sensor/${HA_ID}/config"
        if [ "$DOCKER_AVAILABLE" = true ]; then
            box_line "Publishing Docker version discovery."
            HA_LABEL=$(translate "docker_version")
            VAL_TOPIC="sentrylab/${ID_PROXMOX}/${VMID}/docker"
            # Publish Docker status discovery
            PAYLOAD=$(jq -n \
                --arg name "$HA_LABEL" \
                --arg unique_id "$HA_ID" \
                --arg object_id "$HA_ID" \
                --arg topic "$VAL_TOPIC" \
                --argjson dev "$DEVICE_JSON" \
                '{
                    name: $name,
                    unique_id: $unique_id,
                    object_id: $unique_id,
                    state_topic: $topic,
                    value_template: "{{ value_json.version }}",
                    json_attributes_topic: $topic,
                    device: $dev,
                    icon: "mdi:docker"
                }')
            mqtt_publish_retain "$CFG_TOPIC" "$PAYLOAD"
        else
            box_line "Removing eventual existing Docker version discovery."
            mqtt_publish "$CFG_TOPIC" ""
        fi

        # Publish Docker status data (as JSON)
        box_line "Publishing Docker status state as a json... 02h07"
        STATUS_PAYLOAD=$(jq -n \
            --arg status "$S_DOCKER_STATUS" \
            --arg docker_bin "${DOCKER_BIN:-none}" \
            --arg docker_version "${DOCKER_VERSION:-unknown}" \
            --argjson available "$([ "$DOCKER_AVAILABLE" = true ] && echo true || echo false)" \
            '{
                status: $status,
                available: $available,
                path: $docker_bin,
                version: $docker_version
            }')
        mqtt_publish_retain "$VAL_TOPIC" "$STATUS_PAYLOAD"
        
        # Debug: show what we're sending
        box_line "Sent to $VAL_TOPIC: $STATUS_PAYLOAD"
    else
        box_line "WARNING: MQTT broker not configured"    
    fi



    if [ "$DOCKER_AVAILABLE" = true ]; then

        DEPLOY_PATH="${DOCKER_DEPLOY_PATH:-/opt/sentrylab}"
        POLL_INTERVAL="${DOCKER_POLL_INTERVAL:-300}"

        box_value "Deploy Path" "$DEPLOY_PATH"
        box_value "Poll Interval" "$POLL_INTERVAL"

        # Create deployment directory
        box_line "Creating deployment directory..."
        exec_cmd mkdir -p "$DEPLOY_PATH/logs"
        box_line "✓ Directory created: $DEPLOY_PATH"

        # Copy files
        box_line "Deploying files..."

        pct push "$VMID" "$TEMPLATES_DIR/discovery.py" "$DEPLOY_PATH/discovery.py"
        box_line "✓ Copied: discovery.py"

        pct push "$VMID" "$TEMPLATES_DIR/monitor.py" "$DEPLOY_PATH/monitor.py"
        box_line "✓ Copied: monitor.py"

        pct push "$VMID" "$TEMPLATES_DIR/startup.sh" "$DEPLOY_PATH/startup.sh"
        box_line "✓ Copied: startup.sh"

        # Copy VERSION file (renamed from SL_DOCKER_VERSION to VERSION inside container)
        if [ -f "/usr/local/share/sentrylab/SL_DOCKER_VERSION" ]; then
            pct push "$VMID" "/usr/local/share/sentrylab/SL_DOCKER_VERSION" "$DEPLOY_PATH/VERSION"
            box_line "✓ Copied: VERSION"
        else
            box_line "⚠ VERSION file not found, creating default"
            exec_cmd bash -c "echo 'unknown' > $DEPLOY_PATH/VERSION"
        fi


        # Create compose.yml with substituted DEPLOY_PATH
        sed "s|DEPLOY_PATH|$DEPLOY_PATH|g" "$TEMPLATES_DIR/compose.yml" > /tmp/compose.yml.tmp
        pct push "$VMID" /tmp/compose.yml.tmp "$DEPLOY_PATH/compose.yml"
        rm /tmp/compose.yml.tmp
        box_line "✓ Copied: compose.yml"
        box_line ""

        # Generate .env file from sentrylab.conf
        box_line "Generating .env configuration..."

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
ID_PROXMOX=$ID_PROXMOX
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

        box_line "✓ Configuration created: .env"
        box_line ""

        # Make scripts executable
        exec_cmd chmod +x "$DEPLOY_PATH/discovery.py"
        exec_cmd chmod +x "$DEPLOY_PATH/monitor.py"
        exec_cmd chmod +x "$DEPLOY_PATH/startup.sh"

        # Start the service

        exit 1

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




        # ============================================================================
        # Publish VM/CT-level discovery and data topics to MQTT
        # ============================================================================

        if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
            echo ""
            echo "Publishing Home Assistant discovery topics..."
            
            # Get Proxmox hostname for topic hierarchy
            ID_PROXMOX=$(hostname -s | tr '[:upper:]' '[:lower:]')
            BASE_TOPIC="sl_docker/${ID_PROXMOX}/${VMID}"
            HA_DISCOVERY_PREFIX="${HA_BASE_TOPIC:-homeassistant}"
            
            # Create device info for Home Assistant
            DEVICE_JSON=$(jq -n \
                --arg id "docker_${ID_PROXMOX}_${VMID}" \
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
                    unique_id: "'${ID_PROXMOX}'_'${VMID}'_deployed",
                    state_topic: $topic,
                    value_template: "{{ value_json }}",
                    payload_on: "true",
                    payload_off: "false",
                    device_class: "connectivity",
                    device: $dev
                }')
            mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/binary_sensor/sl_docker_${ID_PROXMOX}_${VMID}_deployed/config" \
                "$(echo "$DEPLOYED_CONFIG" | jq -c .)"
            
            # 2. Deployed time sensor
            DEPLOYED_TIME_CONFIG=$(jq -n \
                --argjson dev "$DEVICE_JSON" \
                --arg topic "${BASE_TOPIC}/deployed_time" \
                '{
                    name: "Deployed Time",
                    unique_id: "'${ID_PROXMOX}'_'${VMID}'_deployed_time",
                    state_topic: $topic,
                    value_template: "{{ value_json }}",
                    device_class: "timestamp",
                    device: $dev
                }')
            mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/sensor/sl_docker_${ID_PROXMOX}_${VMID}_deployed_time/config" \
                "$(echo "$DEPLOYED_TIME_CONFIG" | jq -c .)"
            
            # 3. Last discovery time sensor
            DISCOVERY_TIME_CONFIG=$(jq -n \
                --argjson dev "$DEVICE_JSON" \
                --arg topic "${BASE_TOPIC}/last_discovery_time" \
                '{
                    name: "Last Discovery Time",
                    unique_id: "'${ID_PROXMOX}'_'${VMID}'_last_discovery_time",
                    state_topic: $topic,
                    value_template: "{{ value_json }}",
                    device_class: "timestamp",
                    device: $dev
                }')
            mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/sensor/sl_docker_${ID_PROXMOX}_${VMID}_last_discovery_time/config" \
                "$(echo "$DISCOVERY_TIME_CONFIG" | jq -c .)"
            
            # 4. Last monitor time sensor
            MONITOR_TIME_CONFIG=$(jq -n \
                --argjson dev "$DEVICE_JSON" \
                --arg topic "${BASE_TOPIC}/last_monitor_time" \
                '{
                    name: "Last Monitor Time",
                    unique_id: "'${ID_PROXMOX}'_'${VMID}'_last_monitor_time",
                    state_topic: $topic,
                    value_template: "{{ value_json }}",
                    device_class: "timestamp",
                    device: $dev
                }')
            mqtt_publish_retain "${HA_DISCOVERY_PREFIX}/sensor/sl_docker_${ID_PROXMOX}_${VMID}_last_monitor_time/config" \
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









    fi














else
    box_end
    box_title "⚠ VM/CT deployment skipped (VM/CT $VMID not available)"
fi