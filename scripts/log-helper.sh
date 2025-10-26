#!/bin/bash
# Shared logging helper for VK Uploader scripts
# Writes new log entries at the top and maintains max 1000 lines

# Top-rotating log function
# Usage: log "message" "logfile"
log() {
  local message="$1"
  local logfile="${2:-}"
  local max_lines=1000

  if [ -z "$logfile" ]; then
    echo "Error: log() requires a logfile parameter" >&2
    return 1
  fi

  # Format the log message (use TZ env var if set)
  local formatted_msg="[$(TZ="${TZ:-UTC}" date '+%Y-%m-%d %H:%M:%S %Z')] $message"

  # Create a temp file
  local temp_file
  temp_file=$(mktemp)

  # Write new message at top
  echo "$formatted_msg" > "$temp_file"

  # Append existing log lines (up to max_lines - 1)
  if [ -f "$logfile" ]; then
    head -n $((max_lines - 1)) "$logfile" >> "$temp_file" 2>/dev/null || true
  fi

  # Atomically replace the log file
  mv "$temp_file" "$logfile"
}
