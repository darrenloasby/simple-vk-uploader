# VK Video Uploader

Automated VK video uploader with WireGuard VPN rotation, folder-based playlists, and concurrent uploads.

## Features

- **Automatic Processing**: Runs every 5 minutes via LaunchAgent (macOS), systemd (Linux), or continuous Docker polling
- **Smart Playlists**: Creates VK albums based on folder structure
- **WireGuard Rotation**: Cycles through VPN configs for each upload
- **Concurrent Uploads**: 5 videos upload simultaneously with different VPN connections
- **Standalone Docker**: All-in-one container with continuous polling (no host dependencies)
- **Notifications**: Upload status alerts (macOS host mode only)
- **File Tagging**: Uploaded files tagged BLUE, completed folders tagged PURPLE (macOS host mode only)
- **Parallel Uploads**: Efficient chunked uploads for large files
- **Cross-Platform**: Full support for macOS, Linux, and Docker

## Quick Start

### Docker (Standalone - Recommended)

**Perfect for:** Any platform, servers, NAS devices, always-on setups

```bash
# 1. Create .env file
cp .env.example .env
# Edit .env and add your VK_TOKEN

# 2. (Optional) Encode WireGuard configs
./scripts/wg-config-converter.sh encode
cat .env.wg-configs >> .env

# 3. Run with docker-compose
docker-compose up -d

# 4. View logs
docker-compose logs -f
```

The standalone container continuously polls your videos directory and uploads up to 5 videos concurrently with automatic WireGuard rotation.

### macOS (Host Integration)

1. **Setup environment**:
   ```bash
   cp .env.example .env
   # Edit .env and add your VK_TOKEN
   ```

2. **Install**:
   ```bash
   ./scripts/install-launchagents.sh
   ```

### Linux (Debian/Ubuntu)

1. **Setup environment**:
   ```bash
   cp .env.example .env
   # Edit .env and add your VK_TOKEN
   ```

2. **Install systemd services**:
   ```bash
   ./scripts/install-systemd.sh
   ```

That's it! The uploader will now run automatically every 5 minutes.

## Configuration

Edit `.env` to customize:

```bash
VK_TOKEN=your_vk_token_here
VIDEOS_DIR=$HOME/Videos              # Default if not set
WIREGUARD_DIR=$HOME/wireguard        # Optional, for VPN
LOG_LEVEL=INFO
SKIP_WIREGUARD=false                 # Set to true to disable VPN
```

### WireGuard Configuration (Portable)

WireGuard configs contain sensitive keys and should NOT be committed to git. There are two ways to configure them:

#### Option 1: Local .conf files (Simple)

Place your `.conf` files directly in the `wireguard/` directory:
```bash
wireguard/
├── privado.syd-012.conf
├── privado.sin-005.conf
├── privado.akl-012.conf
├── privado.lax-016.conf
└── privado.sfo-009.conf
```

These files are automatically ignored by git.

#### Option 2: Environment Variables (Portable)

For portability across machines, encode configs as base64 and store in `.env`:

```bash
# 1. Encode all .conf files to base64
./scripts/wg-config-converter.sh encode

# 2. Append to your .env
cat .env.wg-configs >> .env

# 3. Clean up (optional)
rm .env.wg-configs
```

To decode back to `.conf` files on a new machine:

```bash
# Just run decode - it reads from .env automatically
./scripts/wg-config-converter.sh decode
```

The converter script handles all the base64 encoding/decoding automatically.

**Benefits of Option 2:**
- Portable across machines (just copy `.env`)
- Works in CI/CD pipelines
- Bidirectional conversion with one command
- No manual base64 encoding needed
- Still excluded from git (via `.env` in `.gitignore`)

## Folder Structure

Videos are organized into VK playlists based on folder names:

```
videos/
├── Vacation 2024/       → Creates "Vacation 2024" playlist
│   ├── video1.mp4
│   └── video2.mp4
└── Birthday Party/      → Creates "Birthday Party" playlist
    └── party.mp4
```

## Management

### Docker Standalone

**View logs**:
```bash
docker-compose logs -f
# Or specific lines:
docker-compose logs --tail=100 -f
```

**Stop/start container**:
```bash
# Stop
docker-compose stop

# Start
docker-compose start

# Restart
docker-compose restart

# Check status
docker-compose ps
```

**Update to latest image**:
```bash
docker-compose pull
docker-compose up -d
```

**Access container shell**:
```bash
docker-compose exec vk-uploader bash
```

**View WireGuard status inside container**:
```bash
docker-compose exec vk-uploader sudo wg show
```

**Remove everything**:
```bash
docker-compose down
# Or with volumes:
docker-compose down -v
```

### Host Integration (macOS/Linux)

**View logs**:
```bash
tail -f logs/launchagent.log  # Service logs
tail -f logs/uploader.log     # Python uploader logs
```

**Manual run** (for testing):
```bash
./scripts/vk-uploader-agent-concurrent.sh
```

### macOS Specific

**Stop/start agents**:
```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.vk.uploader.agent.plist

# Start
launchctl load ~/Library/LaunchAgents/com.vk.uploader.agent.plist

# Check status
launchctl list | grep vk.uploader
```

**Uninstall**:
```bash
./scripts/uninstall-launchagents.sh
```

### Linux Specific

**Stop/start services**:
```bash
# Stop timer
systemctl --user stop vk-uploader.timer

# Start timer
systemctl --user start vk-uploader.timer

# Check status
systemctl --user status vk-uploader.timer
systemctl --user status vk-uploader.service

# View recent runs
systemctl --user list-timers vk-uploader.timer

# View systemd logs
journalctl --user -u vk-uploader.service -f
```

**Uninstall**:
```bash
./scripts/uninstall-systemd.sh
```

## Optional: System Monitoring

Monitor network, CPU, memory, and disk I/O (logs only, no notifications).

### macOS

```bash
# Enable
launchctl load ~/Library/LaunchAgents/com.vk.system-monitor.plist

# Disable
launchctl unload ~/Library/LaunchAgents/com.vk.system-monitor.plist

# View stats
tail -f logs/system-monitor.log
```

### Linux

```bash
# Enable (run from project directory)
sed "s|%h/simple-vk-uploader|$PWD|g" systemd/vk-system-monitor.service > ~/.config/systemd/user/vk-system-monitor.service
sed "s|%h/simple-vk-uploader|$PWD|g" systemd/vk-system-monitor.timer > ~/.config/systemd/user/vk-system-monitor.timer
systemctl --user daemon-reload
systemctl --user enable --now vk-system-monitor.timer

# Disable
systemctl --user disable --now vk-system-monitor.timer

# View stats
tail -f logs/system-monitor.log
```

## How It Works

1. Agent runs every 5 minutes
2. Connects to next WireGuard VPN config
3. Finds first untagged video in your videos folder
4. Creates/uses VK playlist based on video's subfolder
5. Uploads with parallel chunking for speed
6. Tags uploaded video file **BLUE** in Finder
7. If all videos in folder are uploaded, tags folder **PURPLE**
8. Works recursively up to tag parent folders purple when complete
9. Sends notification with results

**Visual Organization**:
- 🔵 Blue files = Uploaded to VK
- 🟣 Purple folders = All videos uploaded, folder complete

## Requirements

- macOS or Linux
- Docker ([OrbStack](https://orbstack.dev/) recommended for macOS, faster than Docker Desktop)
- [terminal-notifier](https://github.com/julienXX/terminal-notifier) (for rich notifications on macOS)
- WireGuard configs (optional, can be disabled)

Install terminal-notifier (macOS):
```bash
brew install terminal-notifier
```

## Docker Images

Pre-built multi-platform images are available via GitHub Container Registry:

### Standalone (Recommended)

```bash
# Pull latest standalone image
docker pull ghcr.io/darrenloasby/vk-uploader-standalone:latest

# Or use in docker-compose.yml (already configured)
docker-compose pull
```

**Use this for:** Self-contained deployment, continuous polling, no host scripts needed

### Base Image

```bash
# Pull latest base image (requires host scripts)
docker pull ghcr.io/darrenloasby/vk-uploader:latest
```

**Use this for:** Host-integrated mode with LaunchAgent (macOS) or systemd (Linux)

### Supported Platforms

Both images are automatically built for:
- `linux/amd64` (Intel/AMD - best WireGuard performance on Linux)
- `linux/arm64` (Apple Silicon, ARM servers, Raspberry Pi)

**Performance Note**: On Linux, WireGuard runs in kernel mode (~10x faster). On macOS, it runs in userspace mode (slower but still functional).

## Troubleshooting

**No notifications?**
- Install `terminal-notifier`: `brew install terminal-notifier`

**Upload fails?**
- Check `logs/uploader.log` for errors
- Try disabling VPN: set `SKIP_WIREGUARD=true` in `.env`

**Agent not running?**
- Check status: `launchctl list | grep vk.uploader`
- View stderr: `cat logs/*-stderr.log`

**Docker options?**
- **OrbStack** (recommended): Faster, lighter, native macOS performance
- **Docker Desktop**: Works fine, just slower and heavier
- **Linux**: Best performance with kernel WireGuard (~10x faster than macOS)

**Want to remove Finder tags?**
```bash
# Remove tag from a file
xattr -d com.apple.metadata:_kMDItemUserTags "filename.mp4"

# Remove tag from a folder
xattr -d com.apple.metadata:_kMDItemUserTags "foldername"
```

## Development

### Building Docker Images Locally

```bash
# Build for your current platform
docker build -t vk-uploader:local .

# Build for multiple platforms (requires buildx)
docker buildx build --platform linux/amd64,linux/arm64 -t vk-uploader:multi .
```

### CI/CD Pipeline

GitHub Actions automatically builds multi-platform Docker images on:
- **Push to main**: Creates `latest` tag
- **Version tags** (v1.0.0): Creates semantic version tags
- **Pull requests**: Builds without pushing (validation only)

Images are cached using GitHub Actions cache for faster builds.

## License

MIT
