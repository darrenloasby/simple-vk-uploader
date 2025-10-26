# VK Video Uploader - Home Assistant Addon

Automatically upload videos to VK with WireGuard VPN rotation and concurrent uploads.

## Features

- **Continuous Polling**: Checks for new videos every 5 minutes (configurable)
- **Concurrent Uploads**: Up to 5 videos upload simultaneously
- **WireGuard VPN Rotation**: Each upload uses a different VPN connection
- **Smart Playlists**: Creates VK albums based on folder structure
- **Efficient Uploads**: Chunked parallel uploads for large files
- **Auto-Retry**: Automatically retries failed uploads
- **Kernel WireGuard**: ~10x faster VPN on Linux vs userspace

## Installation

1. Add this repository to your Home Assistant:
   - **Settings** → **Add-ons** → **Add-on Store** (⋮ menu) → **Repositories**
   - Add URL: `https://github.com/YOUR_USERNAME/simple-vk-uploader`

2. Install "VK Video Uploader" addon

3. Configure the addon (see Configuration below)

4. Start the addon

## Configuration

### Basic Configuration

```yaml
vk_token: "your_vk_api_token_here"
videos_path: "/media/videos"
poll_interval: 300
max_concurrent: 5
upload_chunk_size_mb: 10
parallel_workers: 3
log_level: "INFO"
timezone: "UTC"
```

### Options

| Option | Type | Required | Default | Description |
|--------|------|----------|---------|-------------|
| `vk_token` | string | **Yes** | - | VK API token for authentication |
| `videos_path` | string | No | `/media/videos` | Path to your videos directory |
| `poll_interval` | int | No | `300` | Seconds between checking for new videos (60-3600) |
| `max_concurrent` | int | No | `5` | Maximum concurrent uploads (1-10) |
| `upload_chunk_size_mb` | int | No | `10` | Upload chunk size in MB (5-50) |
| `parallel_workers` | int | No | `3` | Parallel workers per upload (1-10) |
| `log_level` | string | No | `INFO` | Logging level: DEBUG, INFO, WARNING, ERROR |
| `timezone` | string | No | `UTC` | Timezone for logs |
| `wireguard_configs` | list | No | `[]` | WireGuard VPN configurations (see below) |

### WireGuard Configuration

To use VPN rotation, add WireGuard configurations:

```yaml
wireguard_configs:
  - name: "privado-syd.conf"
    interface_private_key: "YOUR_PRIVATE_KEY"
    interface_address: "100.64.51.175/32"
    interface_dns: "198.18.0.1,198.18.0.2"
    peer_public_key: "KgTUh3KLijVluDvNpzDCJJfrJ7EyLzYLmdHCksG4sRg="
    peer_endpoint: "85.12.5.128:51820"
    peer_allowed_ips: "0.0.0.0/0"

  - name: "privado-sin.conf"
    interface_private_key: "ANOTHER_PRIVATE_KEY"
    interface_address: "100.64.51.176/32"
    interface_dns: "198.18.0.1"
    peer_public_key: "AnotherPublicKey..."
    peer_endpoint: "another.server.com:51820"
    peer_allowed_ips: "0.0.0.0/0"
```

**WireGuard Options:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Config filename (must end in .conf) |
| `interface_private_key` | Yes | Your WireGuard private key |
| `interface_address` | Yes | Your VPN IP address (e.g., 100.64.51.175/32) |
| `interface_dns` | No | DNS servers (comma-separated) |
| `peer_public_key` | Yes | VPN server's public key |
| `peer_endpoint` | Yes | VPN server address:port |
| `peer_allowed_ips` | No | IPs to route through VPN (default: 0.0.0.0/0 for all) |

## How It Works

1. **Continuous Polling**: Addon checks your videos directory every 5 minutes (or custom interval)
2. **Smart Detection**: Finds unprocessed video files (.mp4, .avi, .mov, .mkv, etc.)
3. **Concurrent Upload**: Up to 5 videos upload simultaneously
4. **VPN Rotation**: Each upload uses a different WireGuard connection
5. **Playlist Creation**: Creates VK albums based on folder names
6. **Efficient Transfer**: Uses chunked parallel uploads for speed
7. **Completion Tracking**: Marks uploaded files to avoid re-uploads

### Folder Organization

Videos are organized into VK playlists based on folder structure:

```
/media/videos/
├── Vacation 2024/       → Creates "Vacation 2024" playlist
│   ├── video1.mp4
│   └── video2.mp4
└── Birthday Party/      → Creates "Birthday Party" playlist
    └── party.mp4
```

## Usage

### Getting Your VK Token

1. Go to [VK Developers](https://vk.com/dev)
2. Create a new application
3. Get your access token with `video` permissions
4. Add token to addon configuration

### Uploading Videos

1. Place videos in your configured directory (default: `/media/videos`)
2. Organize into folders (optional, for playlists)
3. The addon automatically detects and uploads new videos
4. Check logs to monitor progress

### Monitoring

View addon logs in Home Assistant:
- **Settings** → **Add-ons** → **VK Video Uploader** → **Log**

Look for:
- `✓ Uploaded:` - Successful uploads
- `Found X video(s) to upload` - Detection
- `[Worker N] Connecting to` - VPN connections
- `Sleeping for Xs...` - Polling interval

## Troubleshooting

### No videos being uploaded

1. Check addon logs for errors
2. Verify `vk_token` is correct
3. Ensure videos path exists and is accessible
4. Check file extensions are supported (.mp4, .avi, .mov, etc.)

### VPN not working

1. Verify WireGuard configs are correct
2. Check private/public keys match your VPN provider
3. Ensure `peer_allowed_ips` is set to `0.0.0.0/0` for full tunnel
4. Try removing VPN configs to test without VPN first

### Slow uploads

- **Using VPN**: VPN adds overhead, especially userspace WireGuard on some systems
- **On Linux**: Addon uses kernel WireGuard (~10x faster than macOS/userspace)
- **Increase chunk size**: Try `upload_chunk_size_mb: 20`
- **Reduce concurrent uploads**: Try `max_concurrent: 3`

### Addon won't start

1. Check required `vk_token` is set
2. Verify videos path exists
3. Check for port conflicts (unlikely with this addon)
4. Review addon logs for startup errors

## Performance Tips

1. **Linux Performance**: Addon runs ~10x faster on Linux due to kernel WireGuard support
2. **Optimal Concurrency**: 5 concurrent uploads balances speed and resource usage
3. **Chunk Size**: 10MB chunks work well for most connections
4. **Poll Interval**: 300s (5 min) is good for regular use; reduce for faster detection
5. **VPN Selection**: Use VPN servers geographically close to you and VK's servers

## Support

Report issues at: [GitHub Issues](https://github.com/YOUR_USERNAME/simple-vk-uploader/issues)

## License

MIT License - see LICENSE file
