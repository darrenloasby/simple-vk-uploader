#!/usr/bin/env bash
# Uninstall VK Uploader systemd services (Linux/Debian)

set -euo pipefail

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Notification helper
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
print_status "$BLUE" "║   VK Uploader systemd Uninstallation (Linux)  ║"
print_status "$BLUE" "╚════════════════════════════════════════════════╝"
echo ""

# Check if systemd is available
if ! command -v systemctl &> /dev/null; then
  print_status "$RED" "✗ Error: systemctl not found. This script requires systemd."
  exit 1
fi

# Define services to uninstall
SERVICES=(
  "vk-uploader.service"
  "vk-uploader.timer"
  "vk-system-monitor.service"
  "vk-system-monitor.timer"
)

# Uninstall each service
for service in "${SERVICES[@]}"; do
  service_name="$service"

  if [ -f "$SYSTEMD_USER_DIR/$service" ]; then
    print_status "$BLUE" "Uninstalling: $service"

    # Stop if running
    if systemctl --user is-active "$service_name" &>/dev/null; then
      print_status "$YELLOW" "  - Stopping service..."
      systemctl --user stop "$service_name" 2>/dev/null || true
    fi

    # Disable if enabled
    if systemctl --user is-enabled "$service_name" &>/dev/null; then
      print_status "$YELLOW" "  - Disabling service..."
      systemctl --user disable "$service_name" 2>/dev/null || true
    fi

    # Remove service file
    rm "$SYSTEMD_USER_DIR/$service"
    print_status "$GREEN" "  ✓ Removed from $SYSTEMD_USER_DIR"
  else
    print_status "$YELLOW" "  - Not installed: $service"
  fi

  echo ""
done

# Reload systemd daemon
print_status "$BLUE" "Reloading systemd daemon..."
systemctl --user daemon-reload
print_status "$GREEN" "✓ Daemon reloaded"
echo ""

# Verify uninstallation
echo ""
print_status "$BLUE" "Verifying uninstallation..."
echo ""

still_running=false
for service in "${SERVICES[@]}"; do
  service_name="$service"
  if systemctl --user is-active "$service_name" &>/dev/null; then
    print_status "$YELLOW" "⚠ $service_name is still running"
    still_running=true
  else
    print_status "$GREEN" "✓ $service_name is not running"
  fi
done

echo ""

if [ "$still_running" = true ]; then
  print_status "$YELLOW" "Some services are still running. Try: systemctl --user reset-failed"
else
  print_status "$GREEN" "🎉 All VK Uploader systemd services have been uninstalled!"
  notify "Uninstallation Complete" "VK Uploader systemd services removed"
fi

# Clean up log files
echo ""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS_DIR="$PROJECT_ROOT/logs"

if [ -d "$LOGS_DIR" ]; then
  print_status "$BLUE" "Cleaning up log files..."

  # List log files to be deleted
  log_count=$(find "$LOGS_DIR" -type f \( -name "*.log" -o -name "*.txt" \) 2>/dev/null | wc -l | tr -d ' ')

  if [ "$log_count" -gt 0 ]; then
    print_status "$YELLOW" "  Found $log_count log file(s) in $LOGS_DIR"
    find "$LOGS_DIR" -type f \( -name "*.log" -o -name "*.txt" \) -exec rm -f {} \;
    print_status "$GREEN" "  ✓ Deleted all log files"

    # Remove logs directory if empty
    if [ -z "$(ls -A "$LOGS_DIR" 2>/dev/null)" ]; then
      rmdir "$LOGS_DIR"
      print_status "$GREEN" "  ✓ Removed empty logs directory"
    fi
  else
    print_status "$YELLOW" "  - No log files to clean up"
  fi
fi

echo ""
print_status "$BLUE" "Note: This does not remove the Docker image or application files."
print_status "$BLUE" "To remove the Docker image, run: docker rmi vk-uploader"
echo ""
print_status "$BLUE" "To disable user lingering (stop services from running without login):"
print_status "$BLUE" "  sudo loginctl disable-linger $USER"
echo ""
