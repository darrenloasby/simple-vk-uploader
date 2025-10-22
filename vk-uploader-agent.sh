#!/opt/homebrew/bin/bash
# VK Video Uploader Agent - Runs periodically via LaunchAgent
# Processes one video per run with notifications

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GP="/Users/dlo/Downloads/Gay Porn"

# Load environment
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

VK_TOKEN="${VK_TOKEN:-}"
VIDEOS_DIR="${VIDEOS_DIR:-$GP}"
WIREGUARD_DIR="${WIREGUARD_DIR:-$SCRIPT_DIR/wireguard}"
LOGS_DIR="${LOGS_DIR:-$SCRIPT_DIR/logs}"
TRASH_DIR="${TRASH_DIR:-$SCRIPT_DIR/trash}"
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

# Notification helper
notify() {
  local title="$1"
  local message="$2"
  osascript -e "display notification \"$message\" with title \"VK Uploader\" subtitle \"$title\"" 2>/dev/null || true
}

# Log helper
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGS_DIR/agent.log"
}

# Ensure directories exist
mkdir -p "$LOGS_DIR" "$TRASH_DIR"

# Resolve directories
VIDEOS_DIR="$(cd "$VIDEOS_DIR" 2>/dev/null && pwd || echo "$VIDEOS_DIR")"
WIREGUARD_DIR="$(cd "$WIREGUARD_DIR" 2>/dev/null && pwd || echo "$WIREGUARD_DIR")"
LOGS_DIR="$(cd "$LOGS_DIR" && pwd)"
TRASH_DIR="$(cd "$TRASH_DIR" && pwd)"

# Validate VK_TOKEN
if [ -z "$VK_TOKEN" ]; then
  log "ERROR: VK_TOKEN is not set"
  notify "Error" "VK_TOKEN not configured"
  exit 1
fi

# Check for Docker
if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
  log "ERROR: Docker not found: $DOCKER_BIN"
  notify "Error" "Docker not found"
  exit 1
fi

# Ensure image exists
ensure_image() {
  local image_exists
  image_exists=$("$DOCKER_BIN" images -q "$IMAGE_NAME" 2>/dev/null || true)
  if [ -z "$image_exists" ]; then
    log "Building Docker image..."
    "$DOCKER_BIN" build -t "$IMAGE_NAME" "$SCRIPT_DIR" >> "$LOGS_DIR/agent.log" 2>&1
  fi
}

# Check if any videos exist
has_videos() {
  find "$VIDEOS_DIR" -maxdepth 3 -type f \( \
    -iname '*.mp4' -o -iname '*.avi' -o -iname '*.mkv' -o \
    -iname '*.mov' -o -iname '*.flv' -o -iname '*.wmv' -o \
    -iname '*.webm' \) -print -quit 2>/dev/null | grep -q .
}

# Process one video
process_video() {
  if ! has_videos; then
    log "No videos found to process"
    return 0
  fi

  log "Processing video..."

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
    -v "$VIDEOS_DIR:/app/videos:rw"
    -v "$WIREGUARD_DIR:/app/wireguard:ro"
    -v "$LOGS_DIR:/app/logs"
    -v "$TRASH_DIR:/app/trash"
    "$IMAGE_NAME"
  )

  if "${docker_cmd[@]}" >> "$LOGS_DIR/agent.log" 2>&1; then
    log "Upload completed successfully"
    notify "Upload Complete" "Video uploaded successfully"

    # Check if more videos remain
    if has_videos; then
      local remaining
      remaining=$(find "$VIDEOS_DIR" -maxdepth 3 -type f \( \
        -iname '*.mp4' -o -iname '*.avi' -o -iname '*.mkv' -o \
        -iname '*.mov' -o -iname '*.flv' -o -iname '*.wmv' -o \
        -iname '*.webm' \) 2>/dev/null | wc -l | tr -d ' ')
      notify "Videos Remaining" "$remaining video(s) remaining"
    fi

    return 0
  else
    log "Upload failed"
    notify "Upload Failed" "Check logs for details"
    return 1
  fi
}

# Main
log "Agent run started"
ensure_image
process_video
log "Agent run completed"
