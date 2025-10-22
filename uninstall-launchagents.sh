#!/bin/bash
# Uninstall VK Uploader LaunchAgents

set -euo pipefail

LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"

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
  osascript -e "display notification \"$message\" with title \"VK Uploader\" subtitle \"$title\"" 2>/dev/null || true
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
print_status "$BLUE" "║   VK Uploader LaunchAgent Uninstallation      ║"
print_status "$BLUE" "╚════════════════════════════════════════════════╝"
echo ""

# Define agents to uninstall
AGENTS=(
  "com.vk.uploader.agent.plist"
  "com.vk.uploader.trash-cleanup.plist"
  "com.vk.uploader.watch.plist"  # Old watcher
)

# Uninstall each agent
for plist in "${AGENTS[@]}"; do
  label="${plist%.plist}"

  if [ -f "$LAUNCHAGENTS_DIR/$plist" ]; then
    print_status "$BLUE" "Uninstalling: $plist"

    # Unload if loaded
    if launchctl list | grep -q "$label" 2>/dev/null; then
      print_status "$YELLOW" "  - Unloading agent..."
      launchctl unload "$LAUNCHAGENTS_DIR/$plist" 2>/dev/null || true
    fi

    # Remove plist
    rm "$LAUNCHAGENTS_DIR/$plist"
    print_status "$GREEN" "  ✓ Removed from $LAUNCHAGENTS_DIR"
  else
    print_status "$YELLOW" "  - Not installed: $plist"
  fi

  echo ""
done

# Verify uninstallation
echo ""
print_status "$BLUE" "Verifying uninstallation..."
echo ""

still_running=false
for plist in "${AGENTS[@]}"; do
  label="${plist%.plist}"
  if launchctl list | grep -q "$label" 2>/dev/null; then
    print_status "$YELLOW" "⚠ $label is still running"
    still_running=true
  else
    print_status "$GREEN" "✓ $label is not running"
  fi
done

echo ""

if [ "$still_running" = true ]; then
  print_status "$YELLOW" "Some agents are still running. Try logging out and back in."
else
  print_status "$GREEN" "🎉 All VK Uploader LaunchAgents have been uninstalled!"
  notify "Uninstallation Complete" "VK Uploader LaunchAgents removed"
fi

echo ""
print_status "$BLUE" "Note: This does not remove the Docker image or application files."
print_status "$BLUE" "To remove the Docker image, run: docker rmi vk-uploader"
echo ""
