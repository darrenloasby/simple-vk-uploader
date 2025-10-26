#!/bin/bash
set -e

echo "========================================="
echo "VK Video Uploader - Home Assistant Addon"
echo "========================================="
echo ""

# Setup configuration from Home Assistant
if [ -f "/app/setup-ha-config.sh" ]; then
    source /app/setup-ha-config.sh
fi

# Create directories
mkdir -p /app/logs /app/wireguard
chmod 755 /app/logs /app/wireguard

# Load WireGuard kernel module if available
if [ -d "/lib/modules" ]; then
    if ! lsmod | grep -q wireguard 2>/dev/null; then
        echo "Loading WireGuard kernel module..."
        modprobe wireguard 2>/dev/null || echo "Note: WireGuard kernel module not available (using userspace)"
    else
        echo "✓ WireGuard kernel module loaded"
    fi
else
    echo "Note: Running without kernel modules (using userspace WireGuard)"
fi

# Ensure proper permissions for WireGuard configs
if [ -d "/app/wireguard" ]; then
    chmod 600 /app/wireguard/*.conf 2>/dev/null || true
fi

# Run the standalone uploader
echo "Starting continuous uploader..."
echo "========================================="
echo ""

exec /app/venv/bin/python /app/uploader-standalone.py
