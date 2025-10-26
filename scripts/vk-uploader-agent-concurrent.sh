#!/opt/homebrew/bin/bash
# VK Video Uploader Agent - CONCURRENT VERSION
# Uploads 3 videos in parallel

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
    local notify_cmd=(terminal-notifier -title "VK Uploader" -subtitle "$title" -message "$message")
    if [ -f "$logo_path" ]; then
      notify_cmd+=(-contentImage "$logo_path")
    fi
    if [ -n "$logfile" ] && [ -f "$logfile" ]; then
      notify_cmd+=(-execute "open -a Console $logfile")
    fi
    "${notify_cmd[@]}" 2>/dev/null || true
  else
    osascript -e "display notification \"$message\" with title \"VK Uploader\" subtitle \"$title\"" 2>/dev/null || true
  fi
}

# Ensure directories exist
mkdir -p "$LOGS_DIR"

# Set up log files
AGENT_LOG="$LOGS_DIR/agent.log"
UPLOADER_LOG="$LOGS_DIR/uploader.log"

# Wrapper for log helper
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

  if [ "$has_videos" = true ] && [ "$all_uploaded" = true ]; then
    return 0
  else
    return 1
  fi
}

# Recursively tag folders purple
tag_folders_recursive() {
  local video_file="$1"
  local videos_dir="$2"
  local current_folder
  current_folder="$(dirname "$video_file")"

  while [ "$current_folder" != "$videos_dir" ] && [ "$current_folder" != "/" ]; do
    if all_videos_uploaded "$current_folder"; then
      tag_folder_purple "$current_folder"
      current_folder="$(dirname "$current_folder")"
    else
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
  else
    local image_exists
    image_exists=$("$DOCKER_BIN" images -q "$IMAGE_NAME" 2>/dev/null || true)
    if [ -z "$image_exists" ]; then
      agent_log "Building Docker image..."
      "$DOCKER_BIN" build -t "$IMAGE_NAME" "$PROJECT_ROOT" >/dev/null 2>&1
    fi
  fi
}

# Check if any videos exist
has_videos() {
  find "$VIDEOS_DIR" -maxdepth 3 -type f \( \
    -iname '*.mp4' -o -iname '*.avi' -o -iname '*.mkv' -o \
    -iname '*.mov' -o -iname '*.flv' -o -iname '*.wmv' -o \
    -iname '*.webm' \) -print -quit 2>/dev/null | grep -q .
}

# Get available WireGuard configs
get_wg_configs() {
  find "$WIREGUARD_DIR" -maxdepth 1 -type f -name "*.conf" | sort
}

# Process one video in a container
process_video_single() {
  local container_id="$1"
  local wg_config_file="$2"

  # Create unique log directory for this container
  local container_logs="$LOGS_DIR/container-${container_id}"
  mkdir -p "$container_logs"

  # Build docker command
  local docker_cmd=(
    "$DOCKER_BIN" run --rm
    --name "vk-uploader-${container_id}-$(date +%s)"
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

  # Force specific WireGuard config (just filename, not full path)
  local wg_config
  wg_config="$(basename "$wg_config_file")"

  docker_cmd+=(
    -e VK_TOKEN="$VK_TOKEN"
    -e VIDEO_DIR="/app/videos"
    -e LOG_LEVEL="$LOG_LEVEL"
    -e UPLOAD_CHUNK_SIZE_MB="$UPLOAD_CHUNK_SIZE_MB"
    -e PARALLEL_WORKERS="$PARALLEL_WORKERS"
    -e SKIP_WIREGUARD="$SKIP_WIREGUARD"
    -e FORCE_WG_CONFIG="$wg_config"
  )

  if [ -n "${TZ:-}" ]; then
    docker_cmd+=(-e TZ="$TZ")
  fi

  docker_cmd+=(
    -v "$VIDEOS_DIR:/app/videos:rw"
    -v "$WIREGUARD_DIR:/app/wireguard:ro"
    -v "$container_logs:/app/logs"
    "$IMAGE_NAME"
  )

  agent_log "Container ${container_id}: Starting with $wg_config"

  if "${docker_cmd[@]}" >> "$container_logs/docker-output.log" 2>&1; then
    agent_log "Container ${container_id}: Success"
    # Return uploaded file path
    if [ -f "$container_logs/last_uploaded.txt" ]; then
      cat "$container_logs/last_uploaded.txt"
    fi
    return 0
  else
    agent_log "Container ${container_id}: Failed"
    return 1
  fi
}

# Process up to 5 videos concurrently
process_videos_concurrent() {
  if ! has_videos; then
    agent_log "No videos found to process"
    return 0
  fi

  # Get available WireGuard configs
  local wg_configs_array=()
  while IFS= read -r config; do
    wg_configs_array+=("$config")
  done < <(get_wg_configs)

  local num_configs=${#wg_configs_array[@]}
  if [ "$num_configs" -eq 0 ]; then
    agent_log "ERROR: No WireGuard configs found"
    return 1
  fi

  # Use up to 5 concurrent uploads (or number of configs, whichever is less)
  local num_concurrent=5
  if [ "$num_configs" -lt 5 ]; then
    num_concurrent=$num_configs
  fi

  agent_log "Starting $num_concurrent concurrent uploads (no wait)..."

  local pids=()
  local temp_files=()

  # Launch containers immediately in parallel
  for i in $(seq 0 $((num_concurrent - 1))); do
    # Assign WireGuard config (cycle through if needed)
    local config_index=$((i % num_configs))
    local wg_config="${wg_configs_array[$config_index]}"

    local temp_file=$(mktemp)
    (process_video_single "$i" "$wg_config" > "$temp_file") &
    pids[$i]=$!
    temp_files[$i]="$temp_file"
  done

  # Wait for all to complete
  local success_count=0
  local fail_count=0

  for i in $(seq 0 $((num_concurrent - 1))); do
    if wait "${pids[$i]}"; then
      success_count=$((success_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
  done

  agent_log "Upload results: $success_count succeeded, $fail_count failed"

  # Tag all successfully uploaded files
  for i in $(seq 0 $((num_concurrent - 1))); do
    if [ -f "${temp_files[$i]}" ]; then
      local relative_path
      relative_path=$(cat "${temp_files[$i]}")

      if [ -n "$relative_path" ]; then
        local uploaded_file_path="$VIDEOS_DIR/$relative_path"

        if [ -f "$uploaded_file_path" ]; then
          tag_file_blue "$uploaded_file_path"
          tag_folders_recursive "$uploaded_file_path" "$VIDEOS_DIR"
        fi
      fi

      rm -f "${temp_files[$i]}"
    fi
  done

  # Clean up container logs after delay
  (sleep 120 && rm -rf "$LOGS_DIR/container-"*) &

  # Notify
  if [ $success_count -gt 0 ]; then
    notify "Upload Complete" "${success_count} of ${num_concurrent} videos uploaded" "$UPLOADER_LOG"
  fi
  if [ $fail_count -gt 0 ]; then
    notify "Upload Warning" "${fail_count} of ${num_concurrent} uploads failed" "$UPLOADER_LOG"
  fi

  # Check remaining
  if has_videos; then
    local remaining
    remaining=$(find "$VIDEOS_DIR" -maxdepth 3 -type f \( \
      -iname '*.mp4' -o -iname '*.avi' -o -iname '*.mkv' -o \
      -iname '*.mov' -o -iname '*.flv' -o -iname '*.wmv' -o \
      -iname '*.webm' \) 2>/dev/null | wc -l | tr -d ' ')
    notify "Videos Remaining" "${remaining} videos remaining" "$AGENT_LOG"
  fi
}

# Main
agent_log "Agent run started (CONCURRENT MODE)"

ensure_image
process_videos_concurrent
agent_log "Agent run completed"
