#!/bin/bash

# ==============================================================================
# SentryLab Docker - Stop Container Monitoring
# ==============================================================================
# Stop monitoring Docker containers on a VM/CT
#
# Usage: ./stop-vmct-monitor.sh <VMID> [PROXMOX_HOST]
#
# Specification:
# 1) Use utils.sh (for config loading and MQTT publishing)
# 2) Stop monitoring Docker containers
#    21) Stop the sentrylab container
#    22) Publish MQTT retained message to indicate monitoring status is "stopped"
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

# ==============================================================================
# Parse Arguments
# ==============================================================================
if [ $# -lt 1 ]; then
    echo "Usage: $0 <VMID> [PROXMOX_HOST]"
    echo ""
    echo "Examples:"
    echo "  $0 101                    # Stop monitoring on VM/CT 101"
    echo "  $0 101 pve-host-1         # Stop monitoring on specific Proxmox host"
    exit 1
fi

VMID="$1"
PROXMOX_HOST="${2:-$(hostname -s)}"
CONTAINER_NAME="sentrylab"

box_begin
box_line "VMID:          $VMID"
box_line "Proxmox Host:  $PROXMOX_HOST"
box_line "Container:     $CONTAINER_NAME"
box_line ""

if [ -z "${BROKER:-}" ]; then
    box_line "WARNING: MQTT broker not configured"
fi

# ==============================================================================
# Stop Monitoring (Specification 2.21: Stop the sentrylab container)
# ==============================================================================
echo "Stopping monitoring..."
echo ""

# Execute stop command in the CT
if [ -z "${VMID:-}" ] || ! type pct &>/dev/null; then
    echo "ERROR: Unable to access CT tools"
    exit 1
fi

# Stop the container inside the CT
echo "  Stopping container: $CONTAINER_NAME"
if pct exec "$VMID" -- docker stop "$CONTAINER_NAME" 2>/dev/null || true; then
    echo "  ✓ Container stopped"
else
    echo "  ⚠ Container already stopped or not found"
fi

echo ""

# ==============================================================================
# Publish Status (Specification 2.22: Publish monitoring status)
# ==============================================================================
if [ -n "${BROKER:-}" ] && type mqtt_publish_retain >/dev/null 2>&1; then
    TOPIC="sl_docker/${PROXMOX_HOST}/${VMID}/monitoring_status"
    box_line "Publishing monitoring status..."
    mqtt_publish_retain "$TOPIC" "stopped"
    box_line "  ✓ Published: monitoring_status = stopped"
fi

echo ""
box_line "✓ Monitoring stopped for VMID $VMID"
box_end
echo ""
