#!/bin/bash
#
# @file setup-vmct.sh
# @author CmPi <github.com/CmPi>
# @brief Deploy SentryLab monitoring to Proxmox VM or CT
# @date 2026-01-11
# @version 0.1.11
#

set -e

CONFIG_FILE="/usr/local/etc/sentrylab.conf"
TEMPLATES_DIR="/usr/local/share/sentrylab/templates"

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Run install.sh first!"
    exit 1
fi

# Source configuration
source "$CONFIG_FILE"

# Check required variables
if [ -z "$BROKER" ]; then
    echo "ERROR: BROKER not set in $CONFIG_FILE"
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
    echo "ERROR: VM/CT $VMID not found"
    echo ""
    echo "Available containers:"
    pct list 2>/dev/null || echo "  (none)"
    echo ""
    echo "Available VMs:"
    qm list 2>/dev/null || echo "  (none)"
    exit 1
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

# Generate device identifiers
DEVICE_NAME="Docker ${VM_NAME}"
DEVICE_ID="docker_$(echo $VM_NAME | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_')"

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

# Create deployment directory
echo "Creating deployment directory..."
exec_cmd mkdir -p "$DEPLOY_PATH/logs"
echo "✓ Directory created: $DEPLOY_PATH"
echo ""

# Copy files
echo "Deploying files..."

pct push "$VMID" "$TEMPLATES_DIR/discovery.py" "$DEPLOY_PATH/discovery.py"
echo "✓ Copied: discovery.py"

pct push "$VMID" "$TEMPLATES_DIR/monitoring.py" "$DEPLOY_PATH/monitoring.py"
echo "✓ Copied: monitoring.py"

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
exec_cmd chmod +x "$DEPLOY_PATH/monitoring.py"
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
echo "================================================"