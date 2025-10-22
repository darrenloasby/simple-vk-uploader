#!/usr/bin/env python3
"""
Simplified VK Video Uploader with WireGuard Rotation
Processes one video file per run and rotates WireGuard configurations
"""

import os
import sys
import logging
import subprocess
import time
import json
import glob
import random
import shutil
import socket
from pathlib import Path
from typing import Optional, List, Dict
from concurrent.futures import ThreadPoolExecutor, as_completed
import psutil
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from vk_api import VkApi
from vk_api.exceptions import VkApiError
from tqdm import tqdm

# Custom rotating log handler that writes to top of file
class TopRotatingFileHandler(logging.Handler):
    """Log handler that keeps only the most recent N lines, newest at top"""

    def __init__(self, filename, max_lines=1000):
        super().__init__()
        self.filename = filename
        self.max_lines = max_lines
        self.lock = None

    def emit(self, record):
        try:
            msg = self.format(record)

            # Read existing lines
            existing_lines = []
            if os.path.exists(self.filename):
                try:
                    with open(self.filename, 'r') as f:
                        existing_lines = f.readlines()
                except Exception:
                    existing_lines = []

            # Write new line at top, keep only max_lines
            with open(self.filename, 'w') as f:
                f.write(msg + '\n')
                # Keep existing lines but limit to max_lines - 1
                for line in existing_lines[:self.max_lines - 1]:
                    f.write(line)

        except Exception:
            self.handleError(record)

# Configure logging
log_level = os.getenv('LOG_LEVEL', 'INFO').upper()
max_log_lines = int(os.getenv('MAX_LOG_LINES', '1000'))

# Create handlers
file_handler = TopRotatingFileHandler('/app/logs/uploader.log', max_lines=max_log_lines)
file_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))

console_handler = logging.StreamHandler(sys.stdout)
console_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))

# Setup logger
logger = logging.getLogger(__name__)
logger.setLevel(getattr(logging, log_level, logging.INFO))
logger.addHandler(file_handler)
logger.addHandler(console_handler)


def _keepalive_socket_options() -> List[tuple]:
    """Return socket options that enable TCP keepalive with sane defaults."""
    options: List[tuple] = [(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)]

    # Linux-specific keepalive settings
    if hasattr(socket, "TCP_KEEPIDLE"):
        options.append((socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 60))
    elif hasattr(socket, "TCP_KEEPALIVE"):
        # macOS uses TCP_KEEPALIVE for the idle timer
        options.append((socket.IPPROTO_TCP, socket.TCP_KEEPALIVE, 60))

    if hasattr(socket, "TCP_KEEPINTVL"):
        options.append((socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 30))

    if hasattr(socket, "TCP_KEEPCNT"):
        options.append((socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 5))

    return options


class KeepAliveAdapter(HTTPAdapter):
    """HTTP adapter that enables TCP keepalive and retry logic for large uploads."""

    def __init__(self, *args, **kwargs):
        self._keepalive_options = kwargs.pop("socket_options", None) or _keepalive_socket_options()
        super().__init__(*args, **kwargs)

    def _merge_socket_options(self, existing: Optional[List[tuple]]) -> List[tuple]:
        merged: List[tuple] = list(existing) if existing else []
        for option in self._keepalive_options:
            if option not in merged:
                merged.append(option)
        return merged

    def init_poolmanager(self, *args, **kwargs):
        kwargs["socket_options"] = self._merge_socket_options(kwargs.get("socket_options"))
        super().init_poolmanager(*args, **kwargs)

    def proxy_manager_for(self, *args, **kwargs):
        kwargs["socket_options"] = self._merge_socket_options(kwargs.get("socket_options"))
        return super().proxy_manager_for(*args, **kwargs)


class IncompleteUploadError(Exception):
    """Raised when the remote upload completes before all bytes are sent."""


class NetworkTrafficMonitor:
    """Monitor network traffic during upload"""
    
    def __init__(self):
        self.start_bytes = 0
        self.interface = self.get_active_interface()
    
    def get_active_interface(self) -> str:
        """Get the active network interface"""
        try:
            # Try to find WireGuard interface first
            for interface in psutil.net_if_stats():
                if interface.startswith('wg'):
                    return interface
            
            # Fall back to default interface
            stats = psutil.net_if_stats()
            for interface, stat in stats.items():
                if stat.isup and interface != 'lo':
                    return interface
        except Exception as e:
            logger.warning(f"Could not determine network interface: {e}")
        
        return 'eth0'  # Default fallback
    
    def start_monitoring(self):
        """Start monitoring network traffic"""
        try:
            stats = psutil.net_io_counters(pernic=True)
            if self.interface in stats:
                self.start_bytes = stats[self.interface].bytes_sent
            else:
                # Use total if specific interface not found
                self.start_bytes = psutil.net_io_counters().bytes_sent
        except Exception as e:
            logger.warning(f"Could not start traffic monitoring: {e}")
            self.start_bytes = 0
    
    def get_upload_bytes(self) -> int:
        """Get bytes uploaded since monitoring started"""
        try:
            stats = psutil.net_io_counters(pernic=True)
            if self.interface in stats:
                current_bytes = stats[self.interface].bytes_sent
            else:
                current_bytes = psutil.net_io_counters().bytes_sent
            
            return max(0, current_bytes - self.start_bytes)
        except Exception as e:
            logger.warning(f"Could not get traffic stats: {e}")
            return 0

class WireGuardManager:
    """Manage WireGuard configurations and rotation"""
    
    def __init__(self, wg_dir: str = "/app/wireguard"):
        self.wg_dir = Path(wg_dir)
        self.current_config = None
        self.last_config_file = Path("/app/logs/last_wg_conf.txt")
    
    def get_available_configs(self) -> List[Path]:
        """Get list of available WireGuard configuration files"""
        configs = list(self.wg_dir.glob("*.conf"))
        if not configs:
            logger.warning(f"No WireGuard configs found in {self.wg_dir}")
        return configs
    
    def get_next_config(self) -> Optional[Path]:
        """Get the next WireGuard configuration to use"""
        configs = self.get_available_configs()
        if not configs:
            return None
        
        # Read last used config
        last_config = None
        if self.last_config_file.exists():
            try:
                last_config = self.last_config_file.read_text().strip()
            except Exception as e:
                logger.warning(f"Could not read last config file: {e}")
        
        # Find next config (simple rotation)
        if last_config:
            try:
                last_path = Path(last_config)
                last_index = configs.index(last_path)
                next_index = (last_index + 1) % len(configs)
                return configs[next_index]
            except (ValueError, IndexError):
                pass
        
        # Return first config or random if last not found
        return configs[0]
    
    def connect_wireguard(self, config_path: Path) -> bool:
        """Connect to WireGuard using specified config"""
        try:
            # Check if this config is already connected
            config_name = config_path.stem  # e.g., "wg0" from "wg0.conf"

            # Check active WireGuard interfaces
            check_result = subprocess.run(["sudo", "wg", "show"], capture_output=True, text=True)
            if check_result.returncode == 0 and config_name in check_result.stdout:
                logger.info(f"WireGuard {config_name} already connected, using existing connection")
                self.current_config = config_path
                self.last_config_file.write_text(str(config_path))
                self.log_connection_info()
                return True

            # Disconnect any existing WG connections
            self.disconnect_wireguard()

            # Connect with new config
            cmd = ["sudo", "wg-quick", "up", str(config_path)]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

            if result.returncode == 0 or "already exists" in result.stderr:
                # Success or already exists (both are fine)
                self.current_config = config_path
                # Save current config
                self.last_config_file.write_text(str(config_path))
                logger.info(f"Successfully connected to WireGuard: {config_path.name}")

                # Log connection details
                self.log_connection_info()
                return True
            else:
                logger.error(f"Failed to connect WireGuard: {result.stderr}")
                return False

        except subprocess.TimeoutExpired:
            logger.error("WireGuard connection timed out")
            return False
        except Exception as e:
            logger.error(f"Error connecting WireGuard: {e}")
            return False
    
    def disconnect_wireguard(self):
        """Disconnect all WireGuard connections"""
        try:
            # Get list of active WG interfaces
            result = subprocess.run(["sudo", "wg", "show"], capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip():
                interfaces = []
                for line in result.stdout.split('\n'):
                    if line and not line.startswith(' '):
                        interface = line.split(':')[0]
                        interfaces.append(interface)
                
                # Disconnect each interface
                for interface in interfaces:
                    subprocess.run(["sudo", "wg-quick", "down", interface], 
                                 capture_output=True, timeout=10)
                    logger.info(f"Disconnected WireGuard interface: {interface}")
                    
        except Exception as e:
            logger.warning(f"Error disconnecting WireGuard: {e}")
    
    def log_connection_info(self):
        """Log current connection information (optional, non-critical)"""
        try:
            # Get public IP with longer timeout and fewer retries
            response = requests.get("https://api.ipify.org?format=json", timeout=5)
            response.raise_for_status()

            # Parse JSON response
            try:
                ip_info = response.json()
                logger.info(f"Public IP: {ip_info.get('ip', 'Unknown')}")
            except json.JSONDecodeError as e:
                logger.debug(f"Could not parse IP response: {e}")

            # Log WireGuard status
            result = subprocess.run(["sudo", "wg", "show"], capture_output=True, text=True)
            if result.returncode == 0:
                logger.info(f"WireGuard status: {result.stdout.strip()}")

        except requests.Timeout:
            logger.debug(f"IP check timed out (skipping, non-critical)")
        except requests.RequestException as e:
            logger.debug(f"Could not fetch connection info: {e}")
        except Exception as e:
            logger.debug(f"Could not log connection info: {e}")

class VKUploader:
    """Handle VK video uploads with playlist support"""

    def __init__(self, token: str):
        self.token = token
        self.vk_session = VkApi(token=token)
        self.traffic_monitor = NetworkTrafficMonitor()
        self.chunk_size = self._determine_chunk_size()
        self.upload_session = self._create_upload_session()
        self._playlists_cache = None  # Cache playlists to avoid repeated API calls

    def _determine_chunk_size(self) -> int:
        """Determine upload chunk size (defaults to 5 MB for better throughput)."""
        env_value = os.getenv("UPLOAD_CHUNK_SIZE_MB")
        if env_value:
            try:
                size_mb = int(env_value)
                if size_mb > 0:
                    chunk_bytes = size_mb * 1024 * 1024
                    logger.info(f"Using custom upload chunk size: {size_mb} MB")
                    return chunk_bytes
                logger.warning("UPLOAD_CHUNK_SIZE_MB must be positive; falling back to 5 MB")
            except ValueError:
                logger.warning("Invalid UPLOAD_CHUNK_SIZE_MB value; falling back to 5 MB")
        # Increased default from 1 MB to 5 MB for better throughput with parallel uploads
        return 5 * 1024 * 1024

    def _create_upload_session(self) -> requests.Session:
        """Create a requests session with retries and TCP keepalive enabled."""
        retry = Retry(
            total=2,
            connect=2,
            read=2,
            backoff_factor=0.5,  # Faster retry backoff
            status_forcelist=[500, 502, 503, 504],
            allowed_methods=False,
            respect_retry_after_header=True,
        )
        # Increased pool size for parallel uploads
        adapter = KeepAliveAdapter(max_retries=retry, pool_maxsize=10, pool_block=False)
        session = requests.Session()
        session.mount("https://", adapter)
        session.mount("http://", adapter)
        session.headers.update({"Connection": "keep-alive"})
        return session

    def get_playlists(self) -> Dict[str, int]:
        """Get all video playlists (albums) from VK, with caching"""
        if self._playlists_cache is not None:
            return self._playlists_cache

        try:
            response = self.vk_session.method("video.getAlbums")
            if not isinstance(response, dict) or "items" not in response:
                logger.warning(f"Unexpected response from video.getAlbums: {response}")
                self._playlists_cache = {}
                return {}

            playlists = {}
            for item in response["items"]:
                if "title" in item and "id" in item:
                    playlists[item["title"]] = item["id"]

            self._playlists_cache = playlists
            logger.debug(f"Loaded {len(playlists)} playlists from VK")
            return playlists

        except VkApiError as e:
            logger.error(f"VK API error getting playlists: {e}")
            self._playlists_cache = {}
            return {}
        except Exception as e:
            logger.error(f"Error getting playlists: {e}")
            self._playlists_cache = {}
            return {}

    def create_playlist(self, title: str) -> Optional[int]:
        """Create a new VK video playlist (album)"""
        try:
            logger.info(f"Creating playlist: {title}")
            response = self.vk_session.method("video.addAlbum", {
                "title": title,
                "privacy": ["only_me"]  # VK API v5.131+ uses array format
            })

            # Handle different response formats
            playlist_id = None
            if isinstance(response, dict):
                if "album_id" in response:
                    playlist_id = response["album_id"]
                elif "response" in response and isinstance(response["response"], dict):
                    playlist_id = response["response"].get("album_id")

            if playlist_id:
                # Update cache
                if self._playlists_cache is None:
                    self._playlists_cache = {}
                self._playlists_cache[title] = playlist_id
                logger.info(f"Created playlist '{title}' with ID {playlist_id}")
                return playlist_id
            else:
                logger.error(f"Could not extract playlist ID from response: {response}")
                return None

        except VkApiError as e:
            logger.error(f"VK API error creating playlist '{title}': {e}")
            return None
        except Exception as e:
            logger.error(f"Error creating playlist '{title}': {e}")
            return None

    def get_or_create_playlist(self, folder_name: str) -> Optional[int]:
        """Get existing playlist ID or create new one"""
        playlists = self.get_playlists()

        if folder_name in playlists:
            logger.debug(f"Using existing playlist '{folder_name}' (ID: {playlists[folder_name]})")
            return playlists[folder_name]

        return self.create_playlist(folder_name)
    
    def find_video_file(self, directory: str) -> Optional[Path]:
        """Find the first valid video file in directory"""
        video_extensions = {'.mp4', '.avi', '.mkv', '.mov', '.flv', '.wmv', '.webm'}
        
        directory_path = Path(directory)
        if not directory_path.exists():
            logger.error(f"Directory does not exist: {directory}")
            return None
        
        # Find all video files
        video_files = []
        for ext in video_extensions:
            video_files.extend(directory_path.glob(f"**/*{ext}"))
            video_files.extend(directory_path.glob(f"**/*{ext.upper()}"))
        
        if not video_files:
            logger.warning(f"No video files found in {directory}")
            return None
        
        # Return first video file found
        video_file = video_files[0]
        logger.info(f"Found video file: {video_file}")
        return video_file
    
    def _check_upload_status(self, upload_url: str) -> int:
        """Check the upload status and return the last known byte"""
        try:
            response = self.upload_session.get(upload_url, timeout=30)
            response.raise_for_status()

            # Parse the Range header or X-Last-Known-Byte header
            last_byte = 0
            if 'Range' in response.headers:
                # Format: bytes=0-12345
                range_header = response.headers['Range']
                if 'bytes=' in range_header:
                    parts = range_header.replace('bytes=', '').split('-')
                    if len(parts) == 2 and parts[1]:
                        last_byte = int(parts[1]) + 1  # Range is inclusive, so add 1
            elif 'X-Last-Known-Byte' in response.headers:
                last_byte = int(response.headers['X-Last-Known-Byte'])

            logger.debug(f"Upload status check: last known byte = {last_byte}")
            return last_byte
        except Exception as e:
            logger.warning(f"Could not check upload status: {e}")
            return 0

    def _upload_chunk(self, upload_url: str, chunk_data: bytes, start_byte: int,
                     total_size: int, filename: str, timeout: int) -> tuple[bool, int]:
        """
        Upload a single chunk of the file.
        Returns (success, bytes_uploaded)
        """
        try:
            actual_chunk_size = len(chunk_data)

            if actual_chunk_size == 0:
                logger.debug("No data to upload (EOF)")
                return True, 0

            end_byte = start_byte + actual_chunk_size - 1

            # Prepare headers for chunked upload
            headers = {
                'Content-Range': f'bytes {start_byte}-{end_byte}/{total_size}',
                'Content-Type': 'application/octet-stream',
                'Content-Disposition': f'attachment; filename="{filename}"',
                'Content-Length': str(actual_chunk_size)
            }

            logger.debug(f"Uploading chunk: {start_byte}-{end_byte}/{total_size} ({actual_chunk_size / (1024*1024):.2f} MB)")

            response = self.upload_session.post(
                upload_url,
                data=chunk_data,
                headers=headers,
                timeout=(30, timeout)  # Reduced connection timeout
            )

            logger.debug(f"Chunk response: status={response.status_code}")

            # 201 = partial upload in progress, 200 = upload complete
            if response.status_code not in [200, 201]:
                logger.error(f"Unexpected status code: {response.status_code}")
                logger.error(f"Response: {response.text[:500]}")
                return False, 0

            return True, actual_chunk_size

        except Exception as e:
            logger.error(f"Error uploading chunk at byte {start_byte}: {e}")
            return False, 0

    def upload_video(self, video_path: Path, playlist_id: Optional[int] = None, max_retries: int = 3) -> bool:
        """Upload video to VK using chunked upload with retry logic and parallel uploads

        Args:
            video_path: Path to the video file
            playlist_id: Optional VK playlist (album) ID to add the video to
            max_retries: Maximum number of retry attempts

        Returns:
            True if upload successful, False otherwise
        """

        for attempt in range(max_retries):
            try:
                # Start traffic monitoring
                self.traffic_monitor.start_monitoring()
                start_time = time.time()

                # Get upload URL
                save_params = {
                    "name": video_path.stem,
                    "privacy_view": "only_me",
                    "privacy_comment": "only_me",
                    "wallpost": False
                }

                # Add to playlist if specified
                if playlist_id is not None:
                    save_params["album_id"] = playlist_id
                    logger.info(f"Uploading to playlist ID: {playlist_id}")
                else:
                    logger.info("Uploading without playlist (root folder)")

                save_response = self.vk_session.method("video.save", save_params)

                upload_url = save_response["upload_url"]
                file_size = video_path.stat().st_size

                if attempt > 0:
                    logger.info(f"Retry attempt {attempt + 1}/{max_retries}")
                logger.info(f"Starting chunked upload of {video_path.name} ({file_size / (1024*1024):.2f} MB)")
                logger.debug(f"Upload chunk size: {self.chunk_size / (1024 * 1024):.2f} MB")

                # Calculate timeout per chunk (optimized for faster uploads)
                # 3 seconds per MB of chunk + 30 second base (reduced from 5s + 60s)
                chunk_timeout = max(90, int((self.chunk_size / (1024*1024)) * 3) + 30)
                logger.info(f"Chunk timeout: {chunk_timeout} seconds")

                # Check if there's an existing partial upload
                start_byte = 0
                if attempt > 0:
                    start_byte = self._check_upload_status(upload_url)
                    if start_byte > 0:
                        logger.info(f"Resuming upload from byte {start_byte} ({start_byte / (1024*1024):.2f} MB)")

                # Pre-read entire file into memory for faster chunk access
                logger.debug("Reading file into memory for faster chunked uploads...")
                with open(video_path, 'rb') as f:
                    f.seek(start_byte)
                    file_data = f.read()

                # Prepare chunks
                chunks_to_upload = []
                bytes_uploaded = start_byte
                filename = video_path.name

                while bytes_uploaded < file_size:
                    current_chunk_size = min(self.chunk_size, file_size - bytes_uploaded)
                    chunk_offset = bytes_uploaded - start_byte
                    chunk_data = file_data[chunk_offset:chunk_offset + current_chunk_size]

                    chunks_to_upload.append((bytes_uploaded, chunk_data))
                    bytes_uploaded += len(chunk_data)

                logger.info(f"Prepared {len(chunks_to_upload)} chunks for upload")

                # Upload chunks with limited parallelism (3 concurrent chunks)
                pbar = tqdm(total=file_size, initial=start_byte, unit='B', unit_scale=True, desc="Uploading")
                total_uploaded = start_byte
                max_workers = min(3, len(chunks_to_upload))  # Max 3 parallel uploads

                try:
                    with ThreadPoolExecutor(max_workers=max_workers) as executor:
                        # Submit chunks in order but allow parallel execution
                        future_to_chunk = {}
                        for chunk_start, chunk_data in chunks_to_upload:
                            future = executor.submit(
                                self._upload_chunk,
                                upload_url,
                                chunk_data,
                                chunk_start,
                                file_size,
                                filename,
                                chunk_timeout
                            )
                            future_to_chunk[future] = chunk_start

                        # Process results as they complete
                        for future in as_completed(future_to_chunk):
                            chunk_start = future_to_chunk[future]
                            try:
                                success, chunk_bytes = future.result()
                                if not success:
                                    raise IncompleteUploadError(
                                        f"Failed to upload chunk at byte {chunk_start}"
                                    )
                                pbar.update(chunk_bytes)
                            except Exception as e:
                                raise IncompleteUploadError(f"Chunk upload failed: {e}")

                    pbar.close()
                    logger.info(f"✓ Upload completed successfully!")
                except Exception:
                    pbar.close()
                    raise

                # Log upload statistics
                upload_time = time.time() - start_time
                network_bytes = self.traffic_monitor.get_upload_bytes()

                logger.info(f"  Upload time: {upload_time:.2f} seconds ({upload_time/60:.1f} minutes)")
                logger.info(f"  File size: {file_size / (1024*1024):.2f} MB")
                logger.info(f"  Network traffic: {network_bytes / (1024*1024):.2f} MB")
                if upload_time > 0:
                    logger.info(f"  Average speed: {(file_size / upload_time) / (1024*1024):.2f} MB/s")

                return True

            except VkApiError as e:
                logger.error(f"VK API error: {e}")
                if attempt < max_retries - 1:
                    wait_time = 5 * (attempt + 1)  # Reduced from 10s
                    logger.info(f"Waiting {wait_time} seconds before retry...")
                    time.sleep(wait_time)
                    continue
                return False
            except requests.Timeout as e:
                logger.error(f"Upload timeout: {e}")
                if attempt < max_retries - 1:
                    wait_time = 10 * (attempt + 1)  # Reduced from 15s
                    logger.info(f"Waiting {wait_time} seconds before retry...")
                    time.sleep(wait_time)
                    continue
                return False
            except IncompleteUploadError as e:
                logger.error(f"Incomplete upload: {e}")
                if attempt < max_retries - 1:
                    wait_time = 10 * (attempt + 1)  # Reduced from 20s
                    logger.info(f"Waiting {wait_time} seconds before retry...")
                    time.sleep(wait_time)
                    continue
                return False
            except requests.RequestException as e:
                logger.error(f"Upload error: {e}")
                if attempt < max_retries - 1:
                    wait_time = 5 * (attempt + 1)  # Reduced from 10s
                    logger.info(f"Waiting {wait_time} seconds before retry...")
                    time.sleep(wait_time)
                    continue
                return False
            except Exception as e:
                logger.error(f"Unexpected error during upload: {e}")
                if attempt < max_retries - 1:
                    wait_time = 5 * (attempt + 1)  # Reduced from 10s
                    logger.info(f"Waiting {wait_time} seconds before retry...")
                    time.sleep(wait_time)
                    continue
                return False

        logger.error(f"All {max_retries} upload attempts failed")
        return False
    
    def move_to_trash(self, video_path: Path):
        """Move video file to trash directory (macOS Trash if mounted)"""
        try:
            trash_dir = Path("/app/trash")

            # Check if trash is mounted (macOS .Trash directory)
            if not trash_dir.exists():
                trash_dir.mkdir(exist_ok=True)
                logger.debug(f"Created trash directory: {trash_dir}")

            destination = trash_dir / video_path.name

            # Handle filename conflicts
            if destination.exists():
                base = destination.stem
                ext = destination.suffix
                counter = 1
                while destination.exists():
                    destination = trash_dir / f"{base}_{counter}{ext}"
                    counter += 1

            # Use shutil.move instead of Path.rename to handle cross-device moves
            shutil.move(str(video_path), str(destination))
            logger.info(f"Moved {video_path.name} to trash")

        except Exception as e:
            logger.error(f"Error moving file to trash: {e}")

def main():
    """Main application logic"""
    # Get environment variables
    vk_token = os.getenv('VK_TOKEN')
    video_dir = os.getenv('VIDEO_DIR', '/app/videos')

    if not vk_token:
        logger.error("VK_TOKEN environment variable is required")
        sys.exit(1)

    logger.info("Starting VK Video Uploader")
    logger.info(f"Video directory: {video_dir}")

    # Initialize components
    wg_manager = WireGuardManager()
    uploader = VKUploader(vk_token)

    try:
        # Rotate WireGuard configuration
        next_config = wg_manager.get_next_config()
        if next_config:
            if not wg_manager.connect_wireguard(next_config):
                logger.error("Failed to connect WireGuard, proceeding without VPN")
        else:
            logger.warning("No WireGuard configurations available")

        # Find video file
        video_file = uploader.find_video_file(video_dir)
        if not video_file:
            logger.info("No video files found to process")
            sys.exit(0)

        # Determine playlist based on folder structure
        video_dir_path = Path(video_dir).resolve()
        video_parent = video_file.parent.resolve()
        playlist_id = None

        # Check if video is in a subfolder (not in root)
        if video_parent != video_dir_path:
            # Get the immediate parent folder name relative to video_dir
            try:
                relative_path = video_parent.relative_to(video_dir_path)
                # Use the first folder name in the relative path
                folder_name = relative_path.parts[0]
                logger.info(f"Video is in subfolder: {folder_name}")

                # Get or create playlist for this folder
                playlist_id = uploader.get_or_create_playlist(folder_name)
                if playlist_id:
                    logger.info(f"Will upload to playlist: {folder_name} (ID: {playlist_id})")
                else:
                    logger.warning(f"Could not create/get playlist for folder '{folder_name}', uploading without playlist")
            except ValueError:
                # video_parent is not relative to video_dir_path
                logger.warning(f"Video path {video_file} is not within {video_dir}, uploading without playlist")
        else:
            logger.info("Video is in root folder, no playlist will be assigned")

        # Upload video with playlist
        if uploader.upload_video(video_file, playlist_id=playlist_id):
            uploader.move_to_trash(video_file)
            logger.info("Video processing completed successfully")
        else:
            logger.error("Video upload failed")
            sys.exit(1)

    except KeyboardInterrupt:
        logger.info("Interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(1)
    finally:
        # Cleanup
        wg_manager.disconnect_wireguard()
        logger.info("Cleanup completed")

if __name__ == "__main__":
    main()
