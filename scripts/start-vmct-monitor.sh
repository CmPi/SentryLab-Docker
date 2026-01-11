#!/bin/bash

# ==============================================================================
# SentryLab Docker - Start Container Monitoring
# ==============================================================================
# Start monitoring Docker containers on a VM/CT
#
# Usage: ./start-vmct-monitor.sh <VMID> [PROXMOX_HOST]
#
# Specification:
# 1) Use utils.sh (for config loading and MQTT publishing)
# 2) Start monitoring Docker containers
#    21) Start the sentrylab container
#    22) Publish MQTT retained message to indicate monitoring status is "starting"
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Source Configuration (Specification 1: Use utils.sh)
# ==============================================================================
CONFIG_FILE="${CONFIG_FILE:-/usr/local/etc/sentrylab.conf}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please run install.sh first"
    exit 1
fi
source "$CONFIG_FILE"

# Source utilities (Specification 1: Use utils.sh)
UTILS_PATH="/usr/local/bin/sentrylab/utils.sh"
if [ ! -f "$UTILS_PATH" ]; then
    echo "ERROR: utils.sh not found at $UTILS_PATH"
    echo "Please run install.sh first"
    exit 1
fi
source "$UTILS_PATH"

box_title "Start VM/CT Container Monitoring"

# ==============================================================================
# Parse Arguments
# ==============================================================================
if [ $# -lt 1 ]; then
    box_begin "Missing argument"
    box_line ""
    box_line "Usage: $0 <VMID> [PROXMOX_HOST]"
    box_line ""
    box_line "Examples:"
    box_line "  $0 101                    # Start monitoring on VM/CT 101"
    box_line "  $0 101 pve-host-1         # Start monitoring on specific Proxmox host"
    box_end
    exit 1
fi

VMID="$1"
PROXMOX_HOST="${2:-$(hostname -s)}"
CONTAINER_NAME="sentrylab"

box_begin
box_line "Proxmox Host:  $PROXMOX_HOST"
box_line "VMID:          $VMID"
box_line "Container:     $CONTAINER_NAME"
box_line ""

if [ -z "${BROKER:-}" ]; then
    box_line "WARNING: MQTT broker not configured"
fi

# ==============================================================================
# Start Monitoring (Specification 2.21: Start the sentrylab container)
# ==============================================================================
# Publish starting status before starting container
if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/monitoring_status"
    mqtt_publish_retain "$TOPIC" "starting"
fi

# Start the container inside the CT
echo "  Starting container: $CONTAINER_NAME"
if pct exec "$VMID" -- docker start "$CONTAINER_NAME" 2>/dev/null || true; then
    echo "  ✓ Container started"
else
    echo "  ⚠ Container already running or not found"
fi

echo ""

# ==============================================================================
# Publish Status (Specification 2.22: Publish monitoring status)
# ==============================================================================
if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/monitoring_status"
    box_line "Publishing monitoring status..."
    mqtt_publish_retain "$TOPIC" "running"
    box_line "  ✓ Published: monitoring_status = running"
fi

echo ""
box_line "✓ Monitoring started for VMID $VMID"
box_end
echo ""
