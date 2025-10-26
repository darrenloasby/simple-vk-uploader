# VK Video Uploader

Automated VK video uploader with WireGuard VPN rotation, folder-based playlists, and macOS notifications.

## Features

- **Automatic Processing**: Runs every 5 minutes via macOS LaunchAgent
- **Smart Playlists**: Creates VK albums based on folder structure
- **WireGuard Rotation**: Cycles through VPN configs for each upload
- **Notifications**: Upload status alerts with VK logo (clickable to view logs)
- **Auto Cleanup**: Moves uploaded videos to macOS Trash
- **Parallel Uploads**: Efficient chunked uploads for large files

## Quick Start

1. **Setup environment**:
   ```bash
   cp .env.example .env
   # Edit .env and add your VK_TOKEN
   ```

2. **Install**:
   ```bash
   ./scripts/install-launchagents.sh
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

**View logs**:
```bash
tail -f logs/agent.log
tail -f logs/uploader.log
```

**Manual run** (for testing):
```bash
./scripts/vk-uploader-agent.sh
```

**Stop/start agents**:
```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.vk.uploader.agent.plist

# Start
launchctl load ~/Library/LaunchAgents/com.vk.uploader.agent.plist
```

**Uninstall**:
```bash
./scripts/uninstall-launchagents.sh
```

## Optional: System Monitoring

Monitor network, CPU, memory, and disk I/O (logs only, no notifications):

```bash
# Enable
launchctl load ~/Library/LaunchAgents/com.vk.system-monitor.plist

# View stats
tail -f logs/system-monitor.log
```

## How It Works

1. Agent runs every 5 minutes
2. Connects to next WireGuard VPN config
3. Finds first video in your videos folder
4. Creates/uses VK playlist based on video's subfolder
5. Uploads with parallel chunking for speed
6. Moves video to Trash
7. Sends notification with results

## Requirements

- macOS
- Docker Desktop
- [terminal-notifier](https://github.com/julienXX/terminal-notifier) (for rich notifications)
- WireGuard configs (optional, can be disabled)

Install terminal-notifier:
```bash
brew install terminal-notifier
```

## Troubleshooting

**No notifications?**
- Install `terminal-notifier`: `brew install terminal-notifier`

**Upload fails?**
- Check `logs/uploader.log` for errors
- Try disabling VPN: set `SKIP_WIREGUARD=true` in `.env`

**Agent not running?**
- Check status: `launchctl list | grep vk.uploader`
- View stderr: `cat logs/*-stderr.log`

## License

MIT
