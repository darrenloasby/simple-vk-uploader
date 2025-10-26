#!/bin/bash
# Setup configuration from Home Assistant options.json

set -e

CONFIG_PATH="/data/options.json"

echo "Reading Home Assistant configuration..."

if [ ! -f "$CONFIG_PATH" ]; then
    echo "ERROR: Home Assistant config not found at $CONFIG_PATH"
    exit 1
fi

# Extract configuration using jq
export VK_TOKEN=$(jq -r '.vk_token // empty' "$CONFIG_PATH")
export VIDEO_DIR=$(jq -r '.videos_path // "/media/videos"' "$CONFIG_PATH")
export POLL_INTERVAL=$(jq -r '.poll_interval // 300' "$CONFIG_PATH")
export MAX_CONCURRENT=$(jq -r '.max_concurrent // 5' "$CONFIG_PATH")
export UPLOAD_CHUNK_SIZE_MB=$(jq -r '.upload_chunk_size_mb // 10' "$CONFIG_PATH")
export PARALLEL_WORKERS=$(jq -r '.parallel_workers // 3' "$CONFIG_PATH")
export LOG_LEVEL=$(jq -r '.log_level // "INFO"' "$CONFIG_PATH")
export TZ=$(jq -r '.timezone // "UTC"' "$CONFIG_PATH")
export WIREGUARD_DIR="/app/wireguard"

# Validate required config
if [ -z "$VK_TOKEN" ]; then
    echo "ERROR: vk_token is required in addon configuration"
    exit 1
fi

# Create WireGuard configs from Home Assistant configuration
mkdir -p "$WIREGUARD_DIR"
chmod 700 "$WIREGUARD_DIR"

# Count WireGuard configs
wg_count=$(jq '.wireguard_configs | length' "$CONFIG_PATH")

if [ "$wg_count" -gt 0 ]; then
    echo "Generating $wg_count WireGuard configuration(s)..."

    for i in $(seq 0 $((wg_count - 1))); do
        config_name=$(jq -r ".wireguard_configs[$i].name" "$CONFIG_PATH")
        private_key=$(jq -r ".wireguard_configs[$i].interface_private_key" "$CONFIG_PATH")
        address=$(jq -r ".wireguard_configs[$i].interface_address" "$CONFIG_PATH")
        dns=$(jq -r ".wireguard_configs[$i].interface_dns // \"\"" "$CONFIG_PATH")
        public_key=$(jq -r ".wireguard_configs[$i].peer_public_key" "$CONFIG_PATH")
        endpoint=$(jq -r ".wireguard_configs[$i].peer_endpoint" "$CONFIG_PATH")
        allowed_ips=$(jq -r ".wireguard_configs[$i].peer_allowed_ips // \"0.0.0.0/0\"" "$CONFIG_PATH")

        config_file="$WIREGUARD_DIR/$config_name"

        cat > "$config_file" <<EOF
[Interface]
PrivateKey = $private_key
Address = $address
EOF

        if [ -n "$dns" ]; then
            echo "DNS = $dns" >> "$config_file"
        fi

        cat >> "$config_file" <<EOF

[Peer]
PublicKey = $public_key
AllowedIPs = $allowed_ips
Endpoint = $endpoint
EOF

        chmod 600 "$config_file"
        echo "  ✓ Created: $config_name"
    done
else
    echo "⚠ No WireGuard configurations provided (VPN disabled)"
fi

echo ""
echo "Configuration loaded successfully:"
echo "  Videos path: $VIDEO_DIR"
echo "  Poll interval: ${POLL_INTERVAL}s"
echo "  Max concurrent: $MAX_CONCURRENT"
echo "  WireGuard configs: $wg_count"
echo ""
