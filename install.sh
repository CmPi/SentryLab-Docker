#!/bin/bash
#
# @file install.sh
# @author CmPi <github.com/CmPi>
# @repo https://github.com/CmPi/SentryLab-Docker
# @brief Root installation script for SentryLab-Docker
# @date creation 2026-01-11
# @version 0.1.11
# @usage sudo ./install.sh
#

set -euo pipefail

BOX_WIDTH=80

# Print text line in a box (for display inside box sections)
# Usage: box_simple_line "Text" [width]
box_simple_line() {
    local text="${1-}"
    local width="${2-$BOX_WIDTH}"
    
    # Validate width
    if [[ ! "$width" =~ ^[0-9]+$ ]]; then
        width=$BOX_WIDTH
    fi
    
    local inner=$((width - 4))
    
    if [[ -z "$text" ]]; then
        printf "│ %*s │\n" "$inner" ""
    else
        # Simple padding - just add spaces to reach inner width
        local text_len=${#text}
        if (( text_len >= inner )); then
            printf "│ %s │\n" "${text:0:$inner}"
        else
            local padding=$((inner - text_len))
            printf "│ %s%*s │\n" "$text" "$padding" ""
        fi
    fi
}

clear

echo "┌─ SentryLab-Docker Installer ─────────────────────────────────────────────────┐"
box_simple_line ""
box_simple_line ""

# Check prerequisites

# Check if running on Proxmox
if [ ! -f /etc/pve/.version ]; then
    box_simple_line "⚠ Warning: This doesn't appear to be a Proxmox host"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "└──────────────────────────────────────────────────────────────────────────────┘"
        exit 1
    fi
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    box_simple_line "This script must be run as root"
    echo "└──────────────────────────────────────────────────────────────────────────────┘"    
    exit 1
fi

CONF_FILE="/usr/local/etc/sentrylab.conf"
DEST_DIR="/usr/local/bin/sentrylab"
SHARE_DIR="/usr/local/share/sentrylab"
TPL_DIR="/usr/local/share/sentrylab/templates"

box_simple_line "Creating directories..."
mkdir -p "$DEST_DIR"
mkdir -p "$(dirname $CONF_FILE)"
mkdir -p "$TPL_DIR"
box_simple_line "✓ Directories created"
box_simple_line ""

box_simple_line "Copying scripts..."
cp scripts/setup-vmct.sh "$DEST_DIR/"
cp scripts/utils.sh "$DEST_DIR/"
chmod +x "$DEST_DIR/setup-vmct.sh"
box_simple_line "✓ Copied: setup-vmct.sh"
box_simple_line "✓ Copied: utils.sh"
box_simple_line ""

box_simple_line "Copying templates..."
cp templates/discovery.py "$TPL_DIR/"
cp templates/monitor.py "$TPL_DIR/"
cp templates/startup.sh "$TPL_DIR/"
cp templates/compose.yml "$TPL_DIR/"
chmod +x "$TPL_DIR/discovery.py"
chmod +x "$TPL_DIR/monitor.py"
chmod +x "$TPL_DIR/startup.sh"
box_simple_line "✓ Copied: discovery.py"
box_simple_line "✓ Copied: monitor.py"
box_simple_line "✓ Copied: startup.sh"
box_simple_line "✓ Copied: compose.yml"
box_simple_line ""

box_simple_line "Copying VERSION file..."
cp VERSION "$SHARE_DIR/VERSION"
box_simple_line "✓ Copied: VERSION"
box_simple_line ""

echo "Creating configuration..."
if [ -f "$CONF_FILE" ]; then
    echo "⚠ Configuration file already exists: $CONF_FILE"
    echo "  Keeping existing configuration"
else
    cp scripts/sentrylab.conf "$CONF_FILE"
    box_simple_line "✓ Created: $CONF_FILE"
    box_simple_line ""
    box_simple_line "⚠ IMPORTANT: Edit the configuration file:"
    box_simple_line "  sudo nano $CONF_FILE"
    box_simple_line ""
    box_simple_line "  Update these values:"
    box_simple_line "    - BROKER (MQTT broker IP/hostname)"
    box_simple_line "    - USER (MQTT username)"
    box_simple_line "    - PASS (MQTT password)"
fi

box_simple_line ""
box_simple_line "Installation Complete!"
echo "└──────────────────────────────────────────────────────────────────────────────┘"
echo ""

# Display next steps

echo "┌─ Next steps ─────────────────────────────────────────────────────────────────┐"
box_simple_line ""
box_simple_line "1. Configure MQTT settings:"
box_simple_line "   sudo nano $CONF_FILE"
box_simple_line ""
box_simple_line "2. Deploy to a VM/CT:"
box_simple_line "   sudo $DEST_DIR/setup-vmct.sh <VMID>"
box_simple_line ""
box_simple_line "Example:"
box_simple_line "   sudo $DEST_DIR/setup-vmct.sh 100"
box_simple_line ""
echo "└──────────────────────────────────────────────────────────────────────────────┘"