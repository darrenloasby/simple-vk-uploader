#!/opt/homebrew/bin/bash
# VK Video Uploader Agent - Runs periodically via LaunchAgent
# Processes one video per run with notifications

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

VK_TOKEN="${VK_TOKEN:-}"
VIDEOS_DIR="${VIDEOS_DIR:-$HOME/Videos}"
WIREGUARD_DIR="${WIREGUARD_DIR:-$PROJECT_ROOT/wireguard}"
LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"
TRASH_DIR="${TRASH_DIR:-$PROJECT_ROOT/trash}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
MEMORY_LIMIT="${MEMORY_LIMIT:-2g}"
MEMORY_SWAP="${MEMORY_SWAP:-3g}"
SHM_SIZE="${SHM_SIZE:-512m}"
TMPFS_RUN_SIZE="${TMPFS_RUN_SIZE:-32m}"
TMPFS_TMP_SIZE="${TMPFS_TMP_SIZE:-256m}"
IMAGE_NAME="${IMAGE_NAME:-vk-uploader}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
UPLOAD_CHUNK_SIZE_MB="${UPLOAD_CHUNK_SIZE_MB:-5}"
CPU_QUOTA="${CPU_QUOTA:-}"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-3}"
SKIP_WIREGUARD="${SKIP_WIREGUARD:-false}"

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

# Ensure directories exist
mkdir -p "$LOGS_DIR" "$TRASH_DIR"

# Set up log files
AGENT_LOG="$LOGS_DIR/agent.log"
UPLOADER_LOG="$LOGS_DIR/uploader.log"

# Wrapper for log helper (to maintain backward compatibility)
agent_log() {
  log "$*" "$AGENT_LOG"
}

# Resolve directories
VIDEOS_DIR="$(cd "$VIDEOS_DIR" 2>/dev/null && pwd || echo "$VIDEOS_DIR")"
WIREGUARD_DIR="$(cd "$WIREGUARD_DIR" 2>/dev/null && pwd || echo "$WIREGUARD_DIR")"
LOGS_DIR="$(cd "$LOGS_DIR" && pwd)"
TRASH_DIR="$(cd "$TRASH_DIR" && pwd)"

# Validate VK_TOKEN
if [ -z "$VK_TOKEN" ]; then
  agent_log "ERROR: VK_TOKEN is not set"
  notify "Error" "VK_TOKEN not configured" "$AGENT_LOG"
  exit 1
fi

# Check for Docker
if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
  agent_log "ERROR: Docker not found: $DOCKER_BIN"
  notify "Error" "Docker not found" "$AGENT_LOG"
  exit 1
fi

# Ensure image exists
ensure_image() {
  local force_rebuild="${FORCE_REBUILD:-false}"

  if [ "$force_rebuild" = "true" ]; then
    agent_log "Force rebuilding Docker image..."
    "$DOCKER_BIN" build --no-cache -t "$IMAGE_NAME" "$PROJECT_ROOT" 2>&1 | tee -a "$AGENT_LOG"
    agent_log "Docker image rebuilt successfully"
  else
    local image_exists
    image_exists=$("$DOCKER_BIN" images -q "$IMAGE_NAME" 2>/dev/null || true)
    if [ -z "$image_exists" ]; then
      agent_log "Building Docker image..."
      "$DOCKER_BIN" build -t "$IMAGE_NAME" "$SCRIPT_DIR" >/dev/null 2>&1
      agent_log "Docker image built successfully"
    fi
  fi
}

# Check if a vk-uploader container is already running
is_container_running() {
  "$DOCKER_BIN" ps --filter "name=vk-uploader-" --format "{{.Names}}" 2>/dev/null | grep -q "vk-uploader-"
}

# Check if any videos exist
has_videos() {
  find "$VIDEOS_DIR" -maxdepth 3 -type f \( \
    -iname '*.mp4' -o -iname '*.avi' -o -iname '*.mkv' -o \
    -iname '*.mov' -o -iname '*.flv' -o -iname '*.wmv' -o \
    -iname '*.webm' \) -print -quit 2>/dev/null | grep -q .
}

# Check for upload failure and notify
check_upload_failure() {
  local failure_file="$LOGS_DIR/upload_failure.txt"

  if [ -f "$failure_file" ]; then
    local video_name=$(grep "^FAILED:" "$failure_file" | cut -d' ' -f2-)
    local reason=$(grep "^REASON:" "$failure_file" | cut -d' ' -f2-)

    agent_log "Upload failed: $video_name - $reason"
    notify "Upload Failed" "File: $video_name\nReason: $reason" "$UPLOADER_LOG"

    # Remove the failure file after notifying
    rm -f "$failure_file"
    return 1
  fi

  return 0
}

# Process one video
process_video() {
  if ! has_videos; then
    agent_log "No videos found to process"
    return 0
  fi

  agent_log "Processing video..."

  # Build docker command
  local docker_cmd=(
    "$DOCKER_BIN" run --rm
    --name "vk-uploader-$(date +%s)"
    --privileged
    --cap-add=NET_ADMIN
    --device /dev/net/tun
    --sysctl net.ipv4.conf.all.src_valid_mark=1
    --sysctl net.ipv4.conf.default.src_valid_mark=1
    --memory "$MEMORY_LIMIT"
    --memory-swap "$MEMORY_SWAP"
    --shm-size "$SHM_SIZE"
    --tmpfs "/run:size=$TMPFS_RUN_SIZE"
    --tmpfs "/tmp:size=$TMPFS_TMP_SIZE"
  )

  if [ -n "$CPU_QUOTA" ]; then
    docker_cmd+=(--cpus "$CPU_QUOTA")
  fi

  docker_cmd+=(
    -e VK_TOKEN="$VK_TOKEN"
    -e VIDEO_DIR="/app/videos"
    -e LOG_LEVEL="$LOG_LEVEL"
    -e UPLOAD_CHUNK_SIZE_MB="$UPLOAD_CHUNK_SIZE_MB"
    -e PARALLEL_WORKERS="$PARALLEL_WORKERS"
    -e SKIP_WIREGUARD="$SKIP_WIREGUARD"
  )

  # Add TZ if set
  if [ -n "${TZ:-}" ]; then
    docker_cmd+=(-e TZ="$TZ")
  fi

  docker_cmd+=(
    -v "$VIDEOS_DIR:/app/videos:rw"
    -v "$WIREGUARD_DIR:/app/wireguard:ro"
    -v "$LOGS_DIR:/app/logs"
    -v "$TRASH_DIR:/app/trash"
    "$IMAGE_NAME"
  )

  if "${docker_cmd[@]}"; then
    # Check if there was a failure (exit code 0 but upload failed)
    if ! check_upload_failure; then
      return 1
    fi

    agent_log "Upload completed successfully"
    notify "Upload Complete" "Video uploaded successfully" "$UPLOADER_LOG"

    # Check if more videos remain
    if has_videos; then
      local remaining
      remaining=$(find "$VIDEOS_DIR" -maxdepth 3 -type f \( \
        -iname '*.mp4' -o -iname '*.avi' -o -iname '*.mkv' -o \
        -iname '*.mov' -o -iname '*.flv' -o -iname '*.wmv' -o \
        -iname '*.webm' \) 2>/dev/null | wc -l | tr -d ' ')
      notify "Videos Remaining" "${remaining} videos remaining" "$AGENT_LOG"
    fi

    return 0
  else
    agent_log "Upload container failed - check uploader.log for details"
    check_upload_failure  # Check for detailed failure reason
    notify "Upload Failed" "Container failed - check logs" "$UPLOADER_LOG"
    return 1
  fi
}

# Main
agent_log "Agent run started"

# Check if a container is already running
if is_container_running; then
  agent_log "Skipping: container already running from previous job"
  notify "Upload In Progress" "Previous job still running, skipping this run" "$AGENT_LOG"
  exit 0
fi

ensure_image
process_video
agent_log "Agent run completed"
