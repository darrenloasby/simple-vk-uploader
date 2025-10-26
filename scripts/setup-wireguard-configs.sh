#!/usr/bin/env bash
# Setup WireGuard configurations from environment variables
# This allows portable, non-committed WireGuard configs via .env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WG_DIR="$PROJECT_ROOT/wireguard"

# Create wireguard directory if it doesn't exist
mkdir -p "$WG_DIR"

# Counter for configs created
config_count=0

# Check for WG_CONFIG_* environment variables and decode them
for i in {1..10}; do
  var_name="WG_CONFIG_${i}"
  config_name_var="WG_CONFIG_${i}_NAME"

  # Get the base64 encoded config
  config_base64="${!var_name:-}"

  # Get the config filename (default to privado.wg${i}.conf if not specified)
  config_name="${!config_name_var:-privado.wg${i}.conf}"

  if [ -n "$config_base64" ]; then
    # Decode base64 and write to file
    config_path="$WG_DIR/$config_name"
    echo "$config_base64" | base64 -d > "$config_path"
    chmod 600 "$config_path"
    ((config_count++))
    echo "✓ Created WireGuard config: $config_name"
  fi
done

if [ $config_count -eq 0 ]; then
  # No env configs found, check if .conf files already exist
  if ls "$WG_DIR"/*.conf &>/dev/null; then
    echo "✓ Using existing WireGuard configs in $WG_DIR"
  else
    echo "⚠ Warning: No WireGuard configs found in env variables or $WG_DIR"
    echo "  Set WG_CONFIG_1, WG_CONFIG_2, etc. in .env or add .conf files to wireguard/"
  fi
else
  echo "✓ Generated $config_count WireGuard config(s) from environment variables"
fi
