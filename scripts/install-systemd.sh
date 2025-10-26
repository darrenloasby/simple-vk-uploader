#!/usr/bin/env bash
# Install VK Uploader systemd services (Linux/Debian)
# This script installs the uploader service and optional system monitor

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Notification helper (uses notify-send if available)
notify() {
  local title="$1"
  local message="$2"
  if command -v notify-send &> /dev/null; then
    notify-send "VK Uploader - $title" "$message" 2>/dev/null || true
  fi
}

# Print colored message
print_status() {
  local color="$1"
  local message="$2"
  echo -e "${color}${message}${NC}"
}

# Print header
echo ""
print_status "$BLUE" "╔════════════════════════════════════════════════╗"
print_status "$BLUE" "║   VK Uploader systemd Installation (Linux)    ║"
print_status "$BLUE" "╚════════════════════════════════════════════════╝"
echo ""

# Check if systemd is available
if ! command -v systemctl &> /dev/null; then
  print_status "$RED" "✗ Error: systemctl not found. This script requires systemd."
  exit 1
fi

# Ensure systemd user directory exists
mkdir -p "$SYSTEMD_USER_DIR"

# Define services to install
SERVICE_FILES=(
  "vk-uploader.service"
  "vk-uploader.timer"
)

SERVICE_DESCRIPTIONS=(
  "VK Uploader Service (main)"
  "VK Uploader Timer (runs every 5 minutes)"
)

# Install each service
for i in "${!SERVICE_FILES[@]}"; do
  service_file="${SERVICE_FILES[$i]}"
  description="${SERVICE_DESCRIPTIONS[$i]}"

  print_status "$BLUE" "Installing: $description"
  print_status "$BLUE" "  File: $service_file"

  # Check if service file exists
  if [ ! -f "systemd/$service_file" ]; then
    print_status "$RED" "  ✗ Error: $service_file not found in $PROJECT_ROOT/systemd"
    continue
  fi

  # Stop service if already running
  service_name="${service_file}"
  if systemctl --user is-active "$service_name" &>/dev/null; then
    print_status "$YELLOW" "  - Stopping existing service..."
    systemctl --user stop "$service_name" 2>/dev/null || true
  fi

  # Disable if already enabled
  if systemctl --user is-enabled "$service_name" &>/dev/null; then
    print_status "$YELLOW" "  - Disabling existing service..."
    systemctl --user disable "$service_name" 2>/dev/null || true
  fi

  # Replace $HOME and other variables in service file
  print_status "$BLUE" "  - Expanding variables in service file..."
  sed -e "s|%h/simple-vk-uploader|$PROJECT_ROOT|g" \
      "systemd/$service_file" > "$SYSTEMD_USER_DIR/$service_file"
  print_status "$GREEN" "  ✓ Installed to $SYSTEMD_USER_DIR"

  echo ""
done

# Reload systemd daemon
print_status "$BLUE" "Reloading systemd daemon..."
systemctl --user daemon-reload
print_status "$GREEN" "✓ Daemon reloaded"
echo ""

# Enable and start the timer (which will trigger the service)
print_status "$BLUE" "Enabling and starting VK Uploader timer..."
if systemctl --user enable vk-uploader.timer 2>/dev/null; then
  print_status "$GREEN" "✓ Timer enabled"
else
  print_status "$RED" "✗ Failed to enable timer"
fi

if systemctl --user start vk-uploader.timer 2>/dev/null; then
  print_status "$GREEN" "✓ Timer started"
else
  print_status "$RED" "✗ Failed to start timer"
fi
echo ""

# Enable lingering (allows services to run even when user is not logged in)
print_status "$BLUE" "Enabling user lingering (services run without login)..."
if sudo loginctl enable-linger "$USER" 2>/dev/null; then
  print_status "$GREEN" "✓ Lingering enabled for user $USER"
else
  print_status "$YELLOW" "⚠ Could not enable lingering (requires sudo)"
  print_status "$YELLOW" "  Services will only run when you're logged in"
  print_status "$YELLOW" "  To enable: sudo loginctl enable-linger $USER"
fi
echo ""

# Verify installation
echo ""
print_status "$BLUE" "Verifying installation..."
echo ""

if systemctl --user is-active vk-uploader.timer &>/dev/null; then
  print_status "$GREEN" "✓ vk-uploader.timer is active"
else
  print_status "$YELLOW" "⚠ vk-uploader.timer is not active"
fi

echo ""
print_status "$BLUE" "Installation complete!"
echo ""

# Show management instructions
print_status "$YELLOW" "Management Commands:"
echo ""
echo "  View logs:"
echo "    tail -f $PROJECT_ROOT/logs/launchagent.log"
echo "    tail -f $PROJECT_ROOT/logs/uploader.log"
echo ""
echo "  Check service status:"
echo "    systemctl --user status vk-uploader.timer"
echo "    systemctl --user status vk-uploader.service"
echo ""
echo "  View recent runs:"
echo "    systemctl --user list-timers vk-uploader.timer"
echo ""
echo "  Stop timer:"
echo "    systemctl --user stop vk-uploader.timer"
echo ""
echo "  Start timer:"
echo "    systemctl --user start vk-uploader.timer"
echo ""
echo "  Restart timer:"
echo "    systemctl --user restart vk-uploader.timer"
echo ""
echo "  View service logs (systemd journal):"
echo "    journalctl --user -u vk-uploader.service -f"
echo ""

# Build Docker image
print_status "$BLUE" "Building Docker image..."
if docker build --no-cache -t vk-uploader . >/dev/null 2>&1; then
  print_status "$GREEN" "✓ Docker image built successfully"
else
  print_status "$YELLOW" "⚠ Could not build Docker image (will build on first run)"
fi

echo ""
notify "Installation Complete" "VK Uploader systemd services are now installed and running"

print_status "$GREEN" "🎉 All done! The VK Uploader will now run automatically."
print_status "$GREEN" "   - Videos will be processed every 5 minutes"
print_status "$GREEN" "   - Playlists are created based on folder names"
print_status "$GREEN" "   - Kernel WireGuard provides ~10x faster VPN on Linux!"
echo ""

# Show optional system monitor info
print_status "$YELLOW" "Optional: System Monitoring"
echo ""
echo "  To enable system monitoring (logs CPU, memory, network stats every 3 minutes):"
echo "    # Install monitor service files"
echo "    sed 's|%h/simple-vk-uploader|$PROJECT_ROOT|g' systemd/vk-system-monitor.service > $SYSTEMD_USER_DIR/vk-system-monitor.service"
echo "    sed 's|%h/simple-vk-uploader|$PROJECT_ROOT|g' systemd/vk-system-monitor.timer > $SYSTEMD_USER_DIR/vk-system-monitor.timer"
echo "    systemctl --user daemon-reload"
echo "    systemctl --user enable --now vk-system-monitor.timer"
echo ""
echo "  To disable it later:"
echo "    systemctl --user disable --now vk-system-monitor.timer"
echo ""
echo "  View monitoring logs:"
echo "    tail -f $PROJECT_ROOT/logs/system-monitor.log"
echo ""
