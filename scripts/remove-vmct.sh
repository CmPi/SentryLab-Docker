#!/bin/bash

# ==============================================================================
# SentryLab Docker - Remove Container MQTT Topics
# ==============================================================================
# Requirements:
# 1) Use utils.sh for MQTT publishing
# 2) Remove all topics related to this VMCT (* is a wildcard)
#    21) Discovery topics
#        211) homeassistant/sensor/sl_<proxmox_node>_<vmid>_*/config
#        212) homeassistant/binary_sensor/sl_<proxmox_node>_<vmid>_*/config
#    22) Data topics
#        221) sl_docker/<proxmox_node>/<vmid>/*
#        222) proxmox/<proxmox_node>/<vmid>/*
#        223) sentrylab/<proxmox_node>/<vmid>/*
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Source Configuration (Requirement 1: Use utils.sh)
# ==============================================================================
CONFIG_FILE="${CONFIG_FILE:-/usr/local/etc/sentrylab.conf}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please run install.sh first"
    exit 1
fi
source "$CONFIG_FILE"

# Source utilities (Requirement 1: Use utils.sh)
UTILS_PATH="/usr/local/bin/sentrylab/utils.sh"
if [ ! -f "$UTILS_PATH" ]; then
    echo "ERROR: utils.sh not found at $UTILS_PATH"
    echo "Please run install.sh first"
    exit 1
fi
source "$UTILS_PATH"

# ==============================================================================
# Parse Arguments
# ==============================================================================
if [ $# -lt 1 ]; then
    echo "Usage: $0 <VMID> [PROXMOX_HOST]"
    echo ""
    echo "Examples:"
    echo "  $0 101                    # Remove topics for VM/CT 101 (uses PROXMOX_HOST from config)"
    echo "  $0 101 pve-host-1         # Remove topics for VM/CT 101 on specific Proxmox host"
    exit 1
fi

VMID="$1"
PROXMOX_HOST="${2:-$(hostname -s)}"

box_begin
box_line "VMID:          $VMID"
box_line "Proxmox Host:  $PROXMOX_HOST"
box_line "MQTT Broker:   ${BROKER:-not configured}"
box_line ""

if [ -z "${BROKER:-}" ]; then
    box_line "WARNING: MQTT broker not configured"
    box_line "No topics will be deleted"
    box_end
    exit 0
fi

# ==============================================================================
# Remove Topics
# ==============================================================================
box_line "Removing MQTT topics... 19h42 ?"
box_line ""

# Count of topics deleted
TOPICS_DELETED=0

# Requirement 2.21.1: Remove homeassistant/sensor discovery configs (sl_<proxmox_node>_<vmid>_*)
# VM/CT Status discovery
TOPIC="homeassistant/sensor/sl_${PROXMOX_HOST}_${VMID}_status/config"
if mqtt_delete_safe "$TOPIC"; then ((TOPICS_DELETED++)); fi

# Docker Status discovery
TOPIC="homeassistant/sensor/sl_${PROXMOX_HOST}_${VMID}_docker_status/config"
if mqtt_delete_safe "$TOPIC"; then ((TOPICS_DELETED++)); fi

# Requirement 2.21.2: Remove homeassistant/binary_sensor discovery configs (sl_<proxmox_node>_<vmid>_*)
# (Container status binary sensors from discovery.py)
TOPIC="homeassistant/binary_sensor/sl_${PROXMOX_HOST}_${VMID}_deployment_status/config"
if mqtt_delete_safe "$TOPIC"; then ((TOPICS_DELETED++)); fi

# Requirement 2.22.1: Remove sl_docker/<proxmox_node>/<vmid>/* data topics
TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/status"
if mqtt_delete_safe "$TOPIC"; then ((TOPICS_DELETED++)); fi

TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/docker_status"
if mqtt_delete_safe "$TOPIC"; then ((TOPICS_DELETED++)); fi

TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/deployed"
if mqtt_delete_safe "$TOPIC"; then ((TOPICS_DELETED++)); fi

TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/deployed_time"
if mqtt_delete_safe "$TOPIC"; then ((TOPICS_DELETED++)); fi

TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/last_discovery_time"
if mqtt_delete_safe "$TOPIC"; then ((TOPICS_DELETED++)); fi

TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/last_monitor_time"
if mqtt_delete_safe "$TOPIC"; then ((TOPICS_DELETED++)); fi

TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/containers"
if mqtt_delete_safe "$TOPIC" "(and all subtopics)"; then ((TOPICS_DELETED++)); fi

# Requirement 2.22.2: Remove proxmox/<proxmox_node>/<vmid>/* data topics (legacy)
echo ""
echo "  Cleaning up legacy proxmox/* topics..."
TOPIC="proxmox/${PROXMOX_HOST}/${VMID}"
if mqtt_delete_safe "$TOPIC" "(and all subtopics)"; then ((TOPICS_DELETED++)); fi

# Requirement 2.22.3: Remove sentrylab/<proxmox_node>/<vmid>/* data topics (unified standard)
echo ""
echo "  Cleaning up standard sentrylab/* topics..."
TOPIC="sentrylab/${PROXMOX_HOST}/${VMID}"
if mqtt_delete_safe "$TOPIC" "(and all subtopics)"; then ((TOPICS_DELETED++)); fi

echo ""
box_line "✓ Removed $TOPICS_DELETED MQTT topics for VMID $VMID"
box_end
echo ""

S_SUBTOPIC_LST=("total" "running" "stopped")
for S_SUBTOPIC in "${S_SUBTOPIC_LST[@]}"; do
    if mqtt_delete_safe "homeassistant/sensor/docker_docker_albusnexus_$VMID/${S_SUBTOPIC}/config"; then ((TOPICS_DELETED++)); fi
done

S_CONTAINER_LST=("portainer" "adguardhome" "amp_mysql" "amp_php" "mqtt" "sentrylab" "traefik")

for S_CONTAINER in "${S_CONTAINER_LST[@]}"; do
    if mqtt_delete_safe "homeassistant/sensor/sl_docker_albusnexus_$VMID_${S_CONTAINER}_uptime/config"; then ((TOPICS_DELETED++)); fi
done
