#!/bin/bash
# VK Trash Cleanup - Moves files from app trash to macOS Trash
# Runs periodically via LaunchAgent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load environment
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

TRASH_DIR="${TRASH_DIR:-$SCRIPT_DIR/trash}"
LOGS_DIR="${LOGS_DIR:-$SCRIPT_DIR/logs}"
MACOS_TRASH="$HOME/.Trash"

# Ensure directories exist
mkdir -p "$LOGS_DIR"

# Resolve directories
TRASH_DIR="$(cd "$TRASH_DIR" 2>/dev/null && pwd || echo "$TRASH_DIR")"
LOGS_DIR="$(cd "$LOGS_DIR" && pwd)"

# Log helper
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGS_DIR/trash-cleanup.log"
}

# Notification helper
notify() {
  local title="$1"
  local message="$2"
  osascript -e "display notification \"$message\" with title \"VK Uploader\" subtitle \"$title\"" 2>/dev/null || true
}

# Check if trash directory exists and has files
if [ ! -d "$TRASH_DIR" ]; then
  log "Trash directory does not exist: $TRASH_DIR"
  exit 0
fi

# Count files in trash
file_count=$(find "$TRASH_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')

if [ "$file_count" -eq 0 ]; then
  log "No files in trash to clean up"
  exit 0
fi

log "Found $file_count file(s) in trash, moving to macOS Trash..."

# Move files to macOS Trash
moved_count=0
failed_count=0

find "$TRASH_DIR" -type f -print0 2>/dev/null | while IFS= read -r -d '' file; do
  filename="$(basename "$file")"
  destination="$MACOS_TRASH/$filename"

  # Handle filename conflicts
  if [ -f "$destination" ]; then
    base="${filename%.*}"
    ext="${filename##*.}"
    if [ "$base" = "$ext" ]; then
      # No extension
      counter=1
      while [ -f "$MACOS_TRASH/${filename}_${counter}" ]; do
        counter=$((counter + 1))
      done
      destination="$MACOS_TRASH/${filename}_${counter}"
    else
      counter=1
      while [ -f "$MACOS_TRASH/${base}_${counter}.${ext}" ]; do
        counter=$((counter + 1))
      done
      destination="$MACOS_TRASH/${base}_${counter}.${ext}"
    fi
  fi

  if mv "$file" "$destination" 2>/dev/null; then
    moved_count=$((moved_count + 1))
    log "Moved: $filename"
  else
    failed_count=$((failed_count + 1))
    log "Failed to move: $filename"
  fi
done

log "Cleanup complete: $moved_count moved, $failed_count failed"

if [ "$moved_count" -gt 0 ]; then
  notify "Trash Cleanup" "Moved $moved_count file(s) to macOS Trash"
fi

# Clean up empty directories
find "$TRASH_DIR" -type d -empty -delete 2>/dev/null || true

exit 0
