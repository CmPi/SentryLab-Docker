#!/bin/bash

# ==============================================================================
# SentryLab Docker - Launch Container Discovery
# ==============================================================================
# Publish Home Assistant discovery topics for containers on a VM/CT
#
# Usage: ./launch-vmct-discovery.sh <VMID> [PROXMOX_HOST]
#
# Specification:
# 1) Use utils.sh (for config loading and MQTT publishing)
# 2) Publish Home Assistant discovery topics for the VM/CT's Docker containers
#    21) Ensure the sentrylab container is running
#    22) Trigger discovery.py to scan and publish container discovery configs
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
    echo "  $0 101                    # Launch discovery on VM/CT 101"
    echo "  $0 101 pve-host-1         # Launch discovery on specific Proxmox host"
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
# Ensure Container Running (Specification 2.21: Ensure sentrylab is running)
# ==============================================================================
echo "Checking container status..."
echo ""

# Execute check in the CT
if [ -z "${VMID:-}" ] || ! type pct &>/dev/null; then
    echo "ERROR: Unable to access CT tools"
    exit 1
fi

# Check if container is running, start if not
CONTAINER_STATUS=$(pct exec "$VMID" -- docker inspect "$CONTAINER_NAME" --format='{{.State.Running}}' 2>/dev/null || echo "false")

if [ "$CONTAINER_STATUS" = "true" ]; then
    echo "  ✓ Container is running"
else
    echo "  Container not running, starting..."
    if pct exec "$VMID" -- docker start "$CONTAINER_NAME" 2>/dev/null || true; then
        echo "  ✓ Container started"
    else
        echo "  ERROR: Unable to start container"
        exit 1
    fi
fi

echo ""

# ==============================================================================
# Trigger Discovery (Specification 2.22: Run discovery.py)
# ==============================================================================
box_line "Triggering container discovery..."
box_line ""

# Execute discovery.py inside the container
if pct exec "$VMID" -- docker exec "$CONTAINER_NAME" python3 /app/discovery.py 2>&1; then
    echo ""
    box_line "✓ Discovery completed successfully"
else
    echo ""
    box_line "⚠ Discovery encountered warnings (see above)"
fi

echo ""
box_line "✓ Discovery launched for VMID $VMID"
box_end
echo ""
