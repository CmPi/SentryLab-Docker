#!/bin/sh
#
# @file startup.sh
# @author CmPi <github.com/CmPi>
# @brief Container startup script for SentryLab-Docker
# @date 2026-01-11
# @version 0.1.11
#

set -e

echo "================================================"
echo "SentryLab-Docker Container Starting"
echo "================================================"

# Display configuration
echo "Device: ${DEVICE_NAME:-Unknown}"
echo "Device ID: ${DEVICE_ID:-Unknown}"
echo "Broker: ${BROKER:-Unknown}:${PORT:-1883}"
echo "Poll Interval: ${POLL_INTERVAL:-30}s"
echo "Log Level: ${LOG_LEVEL:-INFO}"
echo "Debug Mode: ${DEBUG:-false}"
echo ""

# Install required Python packages
echo "Installing Python dependencies..."
pip install --no-cache-dir docker paho-mqtt > /dev/null 2>&1
echo "✓ Dependencies installed"
echo ""

# Run discovery on startup if enabled
if [ "${RUN_DISCOVERY_ON_STARTUP:-true}" = "true" ]; then
    echo "Running initial discovery..."
    python3 /app/discovery.py
    echo "✓ Discovery complete"
    echo ""
fi

# Start monitoring
echo "Starting container monitoring..."
echo "================================================"
exec python3 /app/monitor.py
