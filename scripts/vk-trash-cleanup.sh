#!/bin/bash
# VK Trash Cleanup - Moves files from app trash to macOS Trash
# Runs periodically via LaunchAgent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Load shared log helper
source "$SCRIPT_DIR/log-helper.sh"

# Load environment
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

TRASH_DIR="${TRASH_DIR:-$PROJECT_ROOT/trash}"
LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"
MACOS_TRASH="$HOME/.Trash"

# Ensure directories exist
mkdir -p "$LOGS_DIR"

# Resolve directories
TRASH_DIR="$(cd "$TRASH_DIR" 2>/dev/null && pwd || echo "$TRASH_DIR")"
LOGS_DIR="$(cd "$LOGS_DIR" && pwd)"

# Set up log file
CLEANUP_LOG="$LOGS_DIR/trash-cleanup.log"

# Wrapper for log helper
cleanup_log() {
  log "$*" "$CLEANUP_LOG"
}

# Notification helper with optional log file to open on click
notify() {
  local title="$1"
  local message="$2"
  local logfile="${3:-}"
  local logo_path="$PROJECT_ROOT/vk-logo.png"

  if command -v terminal-notifier >/dev/null 2>&1; then
    # Use terminal-notifier for clickable notifications with VK logo
    local notify_cmd=(terminal-notifier -title "VK Uploader" -subtitle "$title" -message "$message")

    # Add custom image if it exists (use -contentImage for PNG files)
    if [ -f "$logo_path" ]; then
      notify_cmd+=(-contentImage "$logo_path")
    fi

    # Add click action if log file specified
    if [ -n "$logfile" ] && [ -f "$logfile" ]; then
      notify_cmd+=(-execute "open -a Console $logfile")
    fi

    "${notify_cmd[@]}" 2>/dev/null || true
  else
    # Fallback to osascript
    osascript -e "display notification \"$message\" with title \"VK Uploader\" subtitle \"$title\"" 2>/dev/null || true
  fi
}

# Check if trash directory exists and has files
if [ ! -d "$TRASH_DIR" ]; then
  cleanup_log "Trash directory does not exist: $TRASH_DIR"
  exit 0
fi

# Count files in trash
file_count=$(find "$TRASH_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')

if [ "$file_count" -eq 0 ]; then
  cleanup_log "No files in trash to clean up"
  exit 0
fi

cleanup_log "Found $file_count file(s) in trash, moving to macOS Trash..."

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
    cleanup_log "Moved: $filename"
  else
    failed_count=$((failed_count + 1))
    cleanup_log "Failed to move: $filename"
  fi
done

cleanup_log "Cleanup complete: $moved_count moved, $failed_count failed"

if [ "$moved_count" -gt 0 ]; then
  notify "Trash Cleanup" "Moved $moved_count file(s) to macOS Trash" "$CLEANUP_LOG"
fi

# Clean up empty directories
find "$TRASH_DIR" -type d -empty -delete 2>/dev/null || true

exit 0
