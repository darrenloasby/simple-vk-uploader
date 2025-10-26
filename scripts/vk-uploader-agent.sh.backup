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
mkdir -p "$LOGS_DIR"

# Set up log files
AGENT_LOG="$LOGS_DIR/agent.log"
UPLOADER_LOG="$LOGS_DIR/uploader.log"

# Wrapper for log helper (to maintain backward compatibility)
agent_log() {
  log "$*" "$AGENT_LOG"
}

# Tag file with blue Finder tag
tag_file_blue() {
  local file_path="$1"
  if [ -f "$file_path" ]; then
    xattr -w com.apple.metadata:_kMDItemUserTags \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><string>Blue
6</string></array></plist>' \
      "$file_path" 2>/dev/null
    agent_log "Tagged file BLUE: $(basename "$file_path")"
  fi
}

# Tag folder with purple Finder tag
tag_folder_purple() {
  local folder_path="$1"
  if [ -d "$folder_path" ]; then
    xattr -w com.apple.metadata:_kMDItemUserTags \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><string>Purple
5</string></array></plist>' \
      "$folder_path" 2>/dev/null
    agent_log "Tagged folder PURPLE: $(basename "$folder_path")"
  fi
}

# Check if all videos in a folder have .uploaded markers
all_videos_uploaded() {
  local folder="$1"
  local has_videos=false
  local all_uploaded=true

  # Check all video files in this folder (not recursive)
  while IFS= read -r -d '' video_file; do
    has_videos=true
    marker_file="${video_file}.uploaded"
    if [ ! -f "$marker_file" ]; then
      all_uploaded=false
      break
    fi
  done < <(find "$folder" -maxdepth 1 -type f \( \
    -iname '*.mp4' -o -iname '*.avi' -o -iname '*.mkv' -o \
    -iname '*.mov' -o -iname '*.flv' -o -iname '*.wmv' -o \
    -iname '*.webm' \) -print0 2>/dev/null)

  # Return true if has videos AND all are uploaded
  if [ "$has_videos" = true ] && [ "$all_uploaded" = true ]; then
    return 0
  else
    return 1
  fi
}

# Recursively tag folders purple from uploaded video up to VIDEOS_DIR
tag_folders_recursive() {
  local video_file="$1"
  local videos_dir="$2"

  local current_folder
  current_folder="$(dirname "$video_file")"

  # Work up the directory tree until we reach videos_dir
  while [ "$current_folder" != "$videos_dir" ] && [ "$current_folder" != "/" ]; do
    # Check if all videos in this folder are uploaded
    if all_videos_uploaded "$current_folder"; then
      tag_folder_purple "$current_folder"
      # Move up to parent
      current_folder="$(dirname "$current_folder")"
    else
      # Not all videos done yet, stop checking parents
      break
    fi
  done
}

# Resolve directories
VIDEOS_DIR="$(cd "$VIDEOS_DIR" 2>/dev/null && pwd || echo "$VIDEOS_DIR")"
WIREGUARD_DIR="$(cd "$WIREGUARD_DIR" 2>/dev/null && pwd || echo "$WIREGUARD_DIR")"
LOGS_DIR="$(cd "$LOGS_DIR" && pwd)"

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
    "$IMAGE_NAME"
  )

  if "${docker_cmd[@]}"; then
    # Check if there was a failure (exit code 0 but upload failed)
    if ! check_upload_failure; then
      return 1
    fi

    agent_log "Upload completed successfully"

    # Tag uploaded file and folders (done on host, not in container)
    if [ -f "$LOGS_DIR/last_uploaded.txt" ]; then
      # Read relative path from container
      local relative_path
      relative_path="$(cat "$LOGS_DIR/last_uploaded.txt")"

      # Convert to absolute host path
      local uploaded_file_path="$VIDEOS_DIR/$relative_path"

      agent_log "Tagging uploaded file: $uploaded_file_path"

      # Tag the uploaded video file blue
      if [ -f "$uploaded_file_path" ]; then
        tag_file_blue "$uploaded_file_path"

        # Tag folders purple recursively if all videos are done
        tag_folders_recursive "$uploaded_file_path" "$VIDEOS_DIR"
      else
        agent_log "WARNING: Uploaded file not found at: $uploaded_file_path"
      fi

      # Clean up
      rm -f "$LOGS_DIR/last_uploaded.txt"
    fi

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
