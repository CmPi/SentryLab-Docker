#!/bin/bash
#
# @file install.sh
# @author CmPi <github.com/CmPi>
# @repo https://github.com/CmPi/SentryLab-Docker
# @brief Root installation script for SentryLab-Docker
# @date creation 2026-01-11
# @version 1.0.11
# @usage sudo ./install.sh
#

set -euo pipefail

echo "================================================"
echo "SentryLab-Docker Installer"
echo "================================================"
echo ""

# Check prerequisites

# Check if running on Proxmox
if [ ! -f /etc/pve/.version ]; then
    echo "⚠ Warning: This doesn't appear to be a Proxmox host"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

CONF_FILE="/usr/local/etc/sentrylab.conf"
DEST_DIR="/usr/local/bin/sentrylab"
TPL_DIR="/usr/local/bin/sentrylab/templates"

echo "Creating directories..."
mkdir -p "$DEST_DIR"
mkdir -p "$(dirname $CONF_FILE)"
mkdir -p "$TPL_DIR"
echo "✓ Directories created"
echo ""