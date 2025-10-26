#!/opt/homebrew/bin/bash
# VK System Monitor - Periodic system stats with notifications
# Monitors network traffic, CPU, memory, and disk I/O

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

LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

# Ensure directories exist
mkdir -p "$LOGS_DIR"

# Resolve directories
LOGS_DIR="$(cd "$LOGS_DIR" && pwd)"

# Set up log file
MONITOR_LOG="$LOGS_DIR/system-monitor.log"
STATS_FILE="$LOGS_DIR/monitor-stats.json"

# Wrapper for log helper
monitor_log() {
  log "$*" "$MONITOR_LOG"
}

# Notification helper with VK logo
notify() {
  local title="$1"
  local message="$2"
  local logfile="${3:-}"
  local logo_path="$PROJECT_ROOT/vk-logo.png"

  if command -v terminal-notifier >/dev/null 2>&1; then
    # Use terminal-notifier for clickable notifications with VK logo
    local notify_cmd=(terminal-notifier -title "VK System Monitor" -subtitle "$title" -message "$message")

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
    osascript -e "display notification \"$message\" with title \"VK System Monitor\" subtitle \"$title\"" 2>/dev/null || true
  fi
}

# Get WireGuard interface name
get_wg_interface() {
  # Check if any vk-uploader container is running
  if ! "$DOCKER_BIN" ps --filter "name=vk-uploader-" --format "{{.Names}}" 2>/dev/null | grep -q "vk-uploader-"; then
    echo ""
    return
  fi

  # Get the first running container
  local container_name
  container_name=$("$DOCKER_BIN" ps --filter "name=vk-uploader-" --format "{{.Names}}" 2>/dev/null | head -n1)

  if [ -n "$container_name" ]; then
    # Get WireGuard interface from inside container
    "$DOCKER_BIN" exec "$container_name" sh -c "ip link show | grep -o 'wg[0-9]*' | head -n1" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Get network stats from WireGuard interface
get_network_stats() {
  local wg_interface="$1"
  local container_name="$2"

  if [ -z "$wg_interface" ] || [ -z "$container_name" ]; then
    echo "0 0"
    return
  fi

  # Get bytes sent/received from container
  local stats
  stats=$("$DOCKER_BIN" exec "$container_name" sh -c "cat /sys/class/net/$wg_interface/statistics/tx_bytes /sys/class/net/$wg_interface/statistics/rx_bytes" 2>/dev/null || echo "0 0")
  echo "$stats"
}

# Get container stats (CPU, memory)
get_container_stats() {
  local container_name="$1"

  if [ -z "$container_name" ]; then
    echo "0 0 0"
    return
  fi

  # Get stats from docker stats (format: CPU%, MEM USAGE, MEM %)
  local stats
  stats=$("$DOCKER_BIN" stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}} {{.MemPerc}}" "$container_name" 2>/dev/null || echo "0% 0B/0B 0%")

  # Parse CPU percentage (remove %)
  local cpu_pct
  cpu_pct=$(echo "$stats" | awk '{print $1}' | tr -d '%')

  # Parse memory usage (e.g., "123.4MiB / 2GiB")
  local mem_usage
  mem_usage=$(echo "$stats" | awk '{print $2}')

  local mem_limit
  mem_limit=$(echo "$stats" | awk '{print $4}')

  # Parse memory percentage (remove %)
  local mem_pct
  mem_pct=$(echo "$stats" | awk '{print $5}' | tr -d '%')

  echo "$cpu_pct $mem_usage $mem_limit $mem_pct"
}

# Get disk I/O stats from container
get_disk_io_stats() {
  local container_name="$1"

  if [ -z "$container_name" ]; then
    echo "0 0"
    return
  fi

  # Get block I/O stats
  local io_stats
  io_stats=$("$DOCKER_BIN" stats --no-stream --format "{{.BlockIO}}" "$container_name" 2>/dev/null || echo "0B / 0B")

  # Parse read/write (e.g., "1.2MB / 3.4MB")
  local io_read
  io_read=$(echo "$io_stats" | awk '{print $1}')

  local io_write
  io_write=$(echo "$io_stats" | awk '{print $3}')

  echo "$io_read $io_write"
}

# Convert bytes to human readable format
human_bytes() {
  local bytes=$1

  # Handle empty or non-numeric values
  if [ -z "$bytes" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
    echo "0B"
    return
  fi

  if [ "$bytes" -lt 1024 ]; then
    echo "${bytes}B"
  elif [ "$bytes" -lt 1048576 ]; then
    echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1024}")KB"
  elif [ "$bytes" -lt 1073741824 ]; then
    echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}")MB"
  else
    echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB"
  fi
}

# Calculate transfer rate (bytes per second)
calculate_rate() {
  local current_bytes=$1
  local previous_bytes=$2
  local time_diff=$3

  # Handle empty or non-numeric values
  if [ -z "$current_bytes" ] || ! [[ "$current_bytes" =~ ^[0-9]+$ ]]; then
    current_bytes=0
  fi
  if [ -z "$previous_bytes" ] || ! [[ "$previous_bytes" =~ ^[0-9]+$ ]]; then
    previous_bytes=0
  fi
  if [ -z "$time_diff" ] || ! [[ "$time_diff" =~ ^[0-9]+$ ]] || [ "$time_diff" -eq 0 ]; then
    echo 0
    return
  fi

  local diff=$((current_bytes - previous_bytes))
  local rate=$((diff / time_diff))
  echo "$rate"
}

# Format rate for display
format_rate() {
  local rate_bytes=$1

  # Handle empty or non-numeric values
  if [ -z "$rate_bytes" ] || ! [[ "$rate_bytes" =~ ^-?[0-9]+$ ]]; then
    echo "0B/s"
    return
  fi

  # Handle negative rates (just show 0)
  if [ "$rate_bytes" -lt 0 ]; then
    echo "0B/s"
    return
  fi

  if [ "$rate_bytes" -lt 1024 ]; then
    echo "${rate_bytes}B/s"
  elif [ "$rate_bytes" -lt 1048576 ]; then
    echo "$(awk "BEGIN {printf \"%.1f\", $rate_bytes/1024}")KB/s"
  else
    echo "$(awk "BEGIN {printf \"%.2f\", $rate_bytes/1048576}")MB/s"
  fi
}

# Main monitoring function
monitor_system() {
  monitor_log "Starting system monitoring check"

  # Check if uploader container is running
  local container_name
  container_name=$("$DOCKER_BIN" ps --filter "name=vk-uploader-" --format "{{.Names}}" 2>/dev/null | head -n1)

  if [ -z "$container_name" ]; then
    monitor_log "No uploader container running, skipping monitoring"
    return
  fi

  monitor_log "Monitoring container: $container_name"

  # Get WireGuard interface
  local wg_interface
  wg_interface=$(get_wg_interface)

  # Get current timestamp
  local current_time
  current_time=$(date +%s)

  # Read previous stats if they exist
  local prev_tx_bytes=0
  local prev_rx_bytes=0
  local prev_time=0

  if [ -f "$STATS_FILE" ]; then
    prev_tx_bytes=$(jq -r '.tx_bytes // 0' "$STATS_FILE" 2>/dev/null || echo 0)
    prev_rx_bytes=$(jq -r '.rx_bytes // 0' "$STATS_FILE" 2>/dev/null || echo 0)
    prev_time=$(jq -r '.timestamp // 0' "$STATS_FILE" 2>/dev/null || echo 0)
  fi

  # Get current network stats
  local tx_bytes=0
  local rx_bytes=0

  if [ -n "$wg_interface" ]; then
    read -r tx_bytes rx_bytes <<< "$(get_network_stats "$wg_interface" "$container_name")"
  fi

  # Calculate time difference
  local time_diff=$((current_time - prev_time))

  # Calculate transfer rates
  local tx_rate
  tx_rate=$(calculate_rate "$tx_bytes" "$prev_tx_bytes" "$time_diff")

  local rx_rate
  rx_rate=$(calculate_rate "$rx_bytes" "$prev_rx_bytes" "$time_diff")

  # Get container stats
  read -r cpu_pct mem_usage mem_limit mem_pct <<< "$(get_container_stats "$container_name")"

  # Get disk I/O stats
  read -r io_read io_write <<< "$(get_disk_io_stats "$container_name")"

  # Save current stats for next run
  cat > "$STATS_FILE" <<EOF
{
  "timestamp": $current_time,
  "tx_bytes": $tx_bytes,
  "rx_bytes": $rx_bytes
}
EOF

  # Format message
  local message=""

  # Network stats
  if [ -n "$wg_interface" ]; then
    local tx_rate_str
    tx_rate_str=$(format_rate "$tx_rate")
    local rx_rate_str
    rx_rate_str=$(format_rate "$rx_rate")

    local tx_total_str
    tx_total_str=$(human_bytes "$tx_bytes")
    local rx_total_str
    rx_total_str=$(human_bytes "$rx_bytes")

    message+="Network (${wg_interface}):\n"
    message+="  ↑ ${tx_rate_str} (total: ${tx_total_str})\n"
    message+="  ↓ ${rx_rate_str} (total: ${rx_total_str})\n\n"
  else
    message+="Network: No WireGuard active\n\n"
  fi

  # CPU and Memory
  message+="CPU: ${cpu_pct}%\n"
  message+="Memory: ${mem_usage} / ${mem_limit} (${mem_pct}%)\n\n"

  # Disk I/O
  message+="Disk I/O:\n"
  message+="  Read: ${io_read}\n"
  message+="  Write: ${io_write}"

  # Log stats (no notification - just logging)
  monitor_log "Network: TX ${tx_rate_str}, RX ${rx_rate_str}"
  monitor_log "CPU: ${cpu_pct}%, Memory: ${mem_pct}%"
  monitor_log "Disk I/O: Read ${io_read}, Write ${io_write}"
}

# Run monitoring
monitor_system
monitor_log "Monitoring check completed"
