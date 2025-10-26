# VK Video Uploader - Home Assistant Addon

**Automatically upload videos to VK with WireGuard VPN rotation and concurrent uploads.**

## Installation

1. **Add Repository** to Home Assistant:
   - Navigate to: **Settings** → **Add-ons** → **Add-on Store**
   - Click the menu (⋮) in the top right
   - Select **Repositories**
   - Add URL: `https://github.com/darrenloasby/simple-vk-uploader`

2. **Install the Addon**:
   - Find "VK Video Uploader" in the add-on store
   - Click **Install**

3. **Configure** (see Configuration section below)

4. **Start** the addon

## Quick Configuration

Minimal configuration to get started:

```yaml
vk_token: "your_vk_api_token_here"
videos_path: "/media/videos"
```

That's it! The addon will:
- Check for new videos every 5 minutes
- Upload up to 5 videos concurrently
- Create VK playlists based on folder names

## Full Documentation

See **[DOCS.md](DOCS.md)** for complete documentation including:
- Full configuration options
- WireGuard VPN setup
- Troubleshooting guide
- Performance tips

## Features

- ✅ Continuous automatic video uploads
- ✅ Concurrent uploads (up to 5 simultaneous)
- ✅ WireGuard VPN rotation for privacy
- ✅ Smart playlist creation from folders
- ✅ Efficient chunked uploads
- ✅ Automatic retry on failures
- ✅ Kernel WireGuard for speed (~10x faster on Linux)

## Getting Your VK Token

1. Go to [VK Developers](https://vk.com/dev)
2. Create a new application
3. Get an access token with `video` permissions
4. Add the token to your addon configuration

## Support

- 📖 [Full Documentation](DOCS.md)
- 🐛 [Report Issues](https://github.com/darrenloasby/simple-vk-uploader/issues)
- 💬 [Discussions](https://github.com/darrenloasby/simple-vk-uploader/discussions)

## License

MIT
