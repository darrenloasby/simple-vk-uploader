#!/usr/bin/env bash
# Install VK Uploader LaunchAgents
# This script installs the uploader agent and trash cleanup agent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

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
print_status "$BLUE" "║   VK Uploader LaunchAgent Installation        ║"
print_status "$BLUE" "╚════════════════════════════════════════════════╝"
echo ""

# Ensure LaunchAgents directory exists
mkdir -p "$LAUNCHAGENTS_DIR"

# Define agents to install (simple arrays for bash 3.2 compatibility)
AGENT_PLISTS=(
  "com.vk.uploader.agent.plist"
  "com.vk.uploader.trash-cleanup.plist"
)

AGENT_DESCRIPTIONS=(
  "VK Uploader Agent (runs every 5 minutes)"
  "Trash Cleanup (runs daily at 2 AM)"
)


# Install each agent
for i in "${!AGENT_PLISTS[@]}"; do
  plist="${AGENT_PLISTS[$i]}"
  description="${AGENT_DESCRIPTIONS[$i]}"

  print_status "$BLUE" "Installing: $description"
  print_status "$BLUE" "  Plist: $plist"

  # Check if plist file exists
  if [ ! -f "launchagents/$plist" ]; then
    print_status "$RED" "  ✗ Error: $plist not found in $PROJECT_ROOT/launchagents"
    continue
  fi

  # Unload if already loaded
  if launchctl list | grep -q "${plist%.plist}"; then
    print_status "$YELLOW" "  - Unloading existing agent..."
    launchctl unload "$LAUNCHAGENTS_DIR/$plist" 2>/dev/null || true
  fi

  # Replace $HOME and other variables in plist file
  print_status "$BLUE" "  - Expanding variables in plist..."
  sed -e "s|\$HOME|$HOME|g" \
      -e "s|/Users/dlo|$HOME|g" \
      "launchagents/$plist" > "$LAUNCHAGENTS_DIR/$plist"
  print_status "$GREEN" "  ✓ Installed to $LAUNCHAGENTS_DIR"

  # Load the agent
  if launchctl load "$LAUNCHAGENTS_DIR/$plist" 2>/dev/null; then
    print_status "$GREEN" "  ✓ Loaded and activated"
  else
    print_status "$RED" "  ✗ Failed to load agent"
    print_status "$RED" "    Try: launchctl load -w $LAUNCHAGENTS_DIR/$plist"
  fi

  echo ""
done

# Verify installation
echo ""
print_status "$BLUE" "Verifying installation..."
echo ""

for plist in "${AGENT_PLISTS[@]}"; do
  label="${plist%.plist}"
  if launchctl list | grep -q "$label"; then
    print_status "$GREEN" "✓ $label is running"
  else
    print_status "$YELLOW" "⚠ $label is not running"
  fi
done

echo ""
print_status "$BLUE" "Installation complete!"
echo ""

# Show management instructions
print_status "$YELLOW" "Management Commands:"
echo ""
echo "  View logs:"
echo "    tail -f $PROJECT_ROOT/logs/agent.log"
echo "    tail -f $PROJECT_ROOT/logs/trash-cleanup.log"
echo ""
echo "  Unload agents:"
echo "    launchctl unload ~/Library/LaunchAgents/com.vk.uploader.agent.plist"
echo "    launchctl unload ~/Library/LaunchAgents/com.vk.uploader.trash-cleanup.plist"
echo ""
echo "  Reload agents:"
echo "    launchctl load ~/Library/LaunchAgents/com.vk.uploader.agent.plist"
echo "    launchctl load ~/Library/LaunchAgents/com.vk.uploader.trash-cleanup.plist"
echo ""
echo "  Check status:"
echo "    launchctl list | grep vk.uploader"
echo ""

# Build Docker image
print_status "$BLUE" "Building Docker image..."
if docker build --no-cache -t vk-uploader . >/dev/null 2>&1; then
  print_status "$GREEN" "✓ Docker image built successfully"
else
  print_status "$YELLOW" "⚠ Could not build Docker image (will build on first run)"
fi

echo ""
notify "Installation Complete" "VK Uploader LaunchAgents are now installed and running"

print_status "$GREEN" "🎉 All done! The VK Uploader will now run automatically."
print_status "$GREEN" "   - Videos will be processed every 5 minutes"
print_status "$GREEN" "   - Trash cleanup runs daily at 2 AM"
print_status "$GREEN" "   - Playlists are created based on folder names"
echo ""

# Show optional system monitor info
print_status "$YELLOW" "Optional: System Monitoring"
echo ""
echo "  To enable system monitoring (logs CPU, memory, network stats every 3 minutes):"
echo "    launchctl load ~/Library/LaunchAgents/com.vk.system-monitor.plist"
echo ""
echo "  To disable it later:"
echo "    launchctl unload ~/Library/LaunchAgents/com.vk.system-monitor.plist"
echo ""
echo "  View monitoring logs:"
echo "    tail -f $PROJECT_ROOT/logs/system-monitor.log"
echo ""
