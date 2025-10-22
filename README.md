# VK Video Uploader - LaunchAgent Edition

Automatic VK video uploader with WireGuard rotation, playlist management, and macOS LaunchAgent integration.

## Features

- **Automatic Upload Daemon**: Runs every 5 minutes via macOS LaunchAgent
- **VK Playlist Management**: Automatically creates playlists based on folder structure
- **macOS Notifications**: Get notified about upload status and progress
- **WireGuard Rotation**: Automatically rotates through WireGuard configurations
- **Trash Management**: Automatic cleanup of processed videos to macOS Trash
- **Chunked Uploads**: Efficient parallel chunked uploads for large files
- **Self-Installing**: Simple installation script sets up everything

## Usage

### Build the Docker image

```bash
cd simple-uploader
docker build -t vk-simple-uploader .
```

### Run with a video directory

```bash
docker run --rm \
  --privileged \
  --cap-add=NET_ADMIN \
  -e VK_TOKEN="your_vk_token_here" \
  -v "/path/to/videos:/app/videos:ro" \
  -v "/path/to/wireguard/configs:/app/wireguard:ro" \
  -v "/path/to/logs:/app/logs" \
  -v "/path/to/trash:/app/trash" \
  vk-simple-uploader
```

### Required Environment Variables

- `VK_TOKEN`: Your VK API token

### Optional Environment Variables

- `VIDEO_DIR`: Path to video directory inside container (default: `/app/videos`)
- `LOG_LEVEL`: Logging level (default: `INFO`)

### Volume Mounts

- `/app/videos`: Directory containing video files (read-only)
- `/app/wireguard`: Directory containing WireGuard `.conf` files (read-only)
- `/app/logs`: Directory for log files
- `/app/trash`: Directory where processed videos are moved

## Example Command

```bash
docker run --rm \
  --privileged \
  --cap-add=NET_ADMIN \
  -e VK_TOKEN="vk1.a.your_token_here" \
  -v "/Users/username/Videos:/app/videos:ro" \
  -v "/Users/username/wireguard:/app/wireguard:ro" \
  -v "/Users/username/logs:/app/logs" \
  -v "/Users/username/.Trash:/app/trash" \
  vk-simple-uploader
```

## Behavior

1. Rotates to next WireGuard configuration
2. Finds first video file in the specified directory
3. Uploads video to VK
4. Moves video to trash directory
5. Logs network traffic and upload statistics
6. Exits

For continuous processing, run the container repeatedly (e.g., via cron job or loop).

## Logs

- `uploader.log`: Main application logs
- `last_wg_conf.txt`: Tracks last used WireGuard configuration

## Technical Details

- Uses Python virtual environment (`/app/venv`) for dependency isolation
- All Python packages installed in venv, not system-wide
- Alpine Linux base image for minimal size
- Non-root user (`appuser`) for security

## Security Notes

- Container requires `--privileged` and `NET_ADMIN` capabilities for WireGuard
- WireGuard configurations should have proper file permissions (600)
- VK token should be kept secure
- Dependencies isolated in virtual environment