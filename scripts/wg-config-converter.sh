#!/usr/bin/env bash
# WireGuard Config Converter - Convert between .conf files and base64 env variables
# Usage: ./wg-config-converter.sh [encode|decode]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WG_DIR="$PROJECT_ROOT/wireguard"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
  local color="$1"
  local message="$2"
  echo -e "${color}${message}${NC}"
}

print_header() {
  echo ""
  print_status "$BLUE" "╔════════════════════════════════════════════════╗"
  print_status "$BLUE" "║    WireGuard Config Converter                 ║"
  print_status "$BLUE" "╚════════════════════════════════════════════════╝"
  echo ""
}

# Encode .conf files to base64 env variables
encode_configs() {
  print_status "$BLUE" "Encoding .conf files to base64 environment variables..."
  echo ""

  if [ ! -d "$WG_DIR" ]; then
    print_status "$RED" "✗ Error: wireguard/ directory not found"
    exit 1
  fi

  # Find all .conf files
  mapfile -t conf_files < <(find "$WG_DIR" -maxdepth 1 -name "*.conf" -type f | sort)

  if [ ${#conf_files[@]} -eq 0 ]; then
    print_status "$YELLOW" "⚠ No .conf files found in $WG_DIR"
    exit 1
  fi

  print_status "$GREEN" "Found ${#conf_files[@]} config file(s)"
  echo ""

  # Output file
  output_file="$PROJECT_ROOT/.env.wg-configs"

  print_status "$BLUE" "Generating environment variables..."
  echo ""
  echo "# WireGuard Configurations (Base64 encoded)" > "$output_file"
  echo "# Generated: $(date)" >> "$output_file"
  echo "# Add these to your .env file" >> "$output_file"
  echo "" >> "$output_file"

  counter=1
  for conf_file in "${conf_files[@]}"; do
    filename=$(basename "$conf_file")
    print_status "$BLUE" "  [$counter] $filename"

    # Base64 encode (platform compatible)
    if base64 --version 2>&1 | grep -q "GNU"; then
      # GNU base64 (Linux)
      encoded=$(base64 -w 0 < "$conf_file")
    else
      # BSD base64 (macOS)
      encoded=$(base64 < "$conf_file" | tr -d '\n')
    fi

    # Write to output file
    echo "WG_CONFIG_${counter}=${encoded}" >> "$output_file"
    echo "WG_CONFIG_${counter}_NAME=${filename}" >> "$output_file"
    echo "" >> "$output_file"

    ((counter++))
  done

  echo ""
  print_status "$GREEN" "✓ Encoded ${#conf_files[@]} config(s) successfully!"
  echo ""
  print_status "$YELLOW" "Output saved to: $output_file"
  echo ""
  print_status "$BLUE" "Next steps:"
  echo "  1. Review: cat $output_file"
  echo "  2. Append to .env: cat $output_file >> .env"
  echo "  3. Or manually copy the variables into your .env"
  echo ""
  print_status "$YELLOW" "⚠ WARNING: These contain sensitive keys! Keep .env private."
  echo ""
}

# Decode base64 env variables to .conf files
decode_configs() {
  print_status "$BLUE" "Decoding base64 environment variables to .conf files..."
  echo ""

  # Load .env if it exists
  if [ ! -f "$PROJECT_ROOT/.env" ]; then
    print_status "$RED" "✗ Error: .env file not found in $PROJECT_ROOT"
    print_status "$YELLOW" "  Create a .env file with WG_CONFIG_* variables first"
    exit 1
  fi

  # Source .env
  set -a
  source "$PROJECT_ROOT/.env"
  set +a

  mkdir -p "$WG_DIR"

  decoded_count=0

  # Check for WG_CONFIG_* variables
  for i in {1..10}; do
    var_name="WG_CONFIG_${i}"
    name_var="WG_CONFIG_${i}_NAME"

    # Get values using indirect expansion
    config_base64="${!var_name:-}"
    config_name="${!name_var:-privado.wg${i}.conf}"

    if [ -n "$config_base64" ]; then
      config_path="$WG_DIR/$config_name"

      # Decode base64
      if echo "$config_base64" | base64 -d > "$config_path" 2>/dev/null; then
        chmod 600 "$config_path"
        print_status "$GREEN" "  ✓ Decoded: $config_name"
        ((decoded_count++))
      else
        print_status "$RED" "  ✗ Failed to decode WG_CONFIG_${i}"
      fi
    fi
  done

  echo ""
  if [ $decoded_count -eq 0 ]; then
    print_status "$YELLOW" "⚠ No WG_CONFIG_* variables found in .env"
    echo ""
    print_status "$BLUE" "Expected format in .env:"
    echo "  WG_CONFIG_1=W0ludGVyZmFjZV0K..."
    echo "  WG_CONFIG_1_NAME=privado.syd-012.conf"
    echo "  WG_CONFIG_2=..."
    echo ""
  else
    print_status "$GREEN" "✓ Decoded $decoded_count config(s) successfully to $WG_DIR"
    echo ""
  fi
}

# Show usage
show_usage() {
  print_header
  echo "Convert WireGuard configs between .conf files and base64 env variables"
  echo ""
  print_status "$YELLOW" "Usage:"
  echo "  $0 encode    # .conf files → base64 env variables"
  echo "  $0 decode    # base64 env variables → .conf files"
  echo ""
  print_status "$YELLOW" "Examples:"
  echo ""
  echo "  # Encode your .conf files for portability:"
  echo "  $0 encode"
  echo "  cat .env.wg-configs >> .env"
  echo ""
  echo "  # Decode env variables back to .conf files:"
  echo "  $0 decode"
  echo ""
  print_status "$BLUE" "Why use this?"
  echo "  • Encode: Make configs portable (store in .env, copy to other machines)"
  echo "  • Decode: Regenerate .conf files from environment variables"
  echo "  • Security: .conf files never committed to git"
  echo ""
}

# Main
print_header

case "${1:-}" in
  encode)
    encode_configs
    ;;
  decode)
    decode_configs
    ;;
  *)
    show_usage
    exit 1
    ;;
esac
