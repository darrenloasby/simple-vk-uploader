#!/bin/bash
set -e

# Create logs directory
mkdir -p /app/logs /app/trash

# Set proper permissions
sudo chown -R appuser:appuser /app/logs /app/trash

# Load WireGuard kernel module if needed (skip on macOS/Docker Desktop)
if [ -d "/lib/modules" ]; then
    if ! lsmod | grep -q wireguard 2>/dev/null; then
        echo "Loading WireGuard kernel module..."
        sudo modprobe wireguard 2>/dev/null || echo "Note: WireGuard kernel module not available (using userspace)"
    fi
else
    echo "Note: Running without kernel modules (Docker Desktop/macOS - WireGuard will use userspace)"
fi

# Ensure proper permissions for WireGuard configs
if [ -d "/app/wireguard" ]; then
    sudo chmod 600 /app/wireguard/*.conf 2>/dev/null || true
fi

echo "Starting VK Video Uploader..."
echo "Video directory: ${VIDEO_DIR:-/app/videos}"
echo "VK Token: ${VK_TOKEN:+***configured***}"
echo "Python: $(which python3)"
echo "Virtual environment: ${VIRTUAL_ENV}"

# Run the uploader using venv python
exec /app/venv/bin/python /app/uploader.py