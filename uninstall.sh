#!/bin/bash
#
# @file uninstall.sh
# @author CmPi <github.com/CmPi>
# @repo https://github.com/CmPi/SentryLab-Docker
# @brief Uninstallation script for SentryLab-Docker
# @date creation 2026-01-11
# @version 0.1.11
# @usage sudo ./uninstall.sh
#

set -uo pipefail

# Color codes
RED='\033[0;31m'
NC='\033[0m' # No Color

# Error handler
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root"
fi

