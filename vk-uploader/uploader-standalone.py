#!/usr/bin/env python3
"""
VK Video Uploader - Standalone Continuous Mode
Continuously polls directory and uploads up to 5 videos concurrently with WireGuard rotation
"""

import os
import sys
import time
import logging
import subprocess
import threading
from pathlib import Path
from typing import List, Optional
from queue import Queue
from uploader import VKVideoUploader

# Setup logging
logging.basicConfig(
    level=os.getenv('LOG_LEVEL', 'INFO'),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class WireGuardManager:
    """Manages WireGuard connections for concurrent uploads"""

    def __init__(self, wg_dir: Path, max_concurrent: int = 5):
        self.wg_dir = wg_dir
        self.max_concurrent = max_concurrent
        self.configs = self._discover_configs()
        self.active_connections = {}
        self.lock = threading.Lock()

    def _discover_configs(self) -> List[Path]:
        """Discover all WireGuard configs"""
        if not self.wg_dir.exists():
            logger.warning(f"WireGuard directory not found: {self.wg_dir}")
            return []

        configs = sorted(self.wg_dir.glob("*.conf"))
        logger.info(f"Discovered {len(configs)} WireGuard config(s)")
        return configs

    def get_interface_name(self, worker_id: int) -> str:
        """Get interface name for worker"""
        return f"wg{worker_id}"

    def connect(self, worker_id: int, config: Path) -> bool:
        """Establish WireGuard connection for a worker"""
        interface = self.get_interface_name(worker_id)

        try:
            # Bring down any existing interface
            subprocess.run(
                ['wg-quick', 'down', interface],
                capture_output=True,
                timeout=10
            )
        except Exception:
            pass  # Interface might not exist

        try:
            logger.info(f"[Worker {worker_id}] Connecting to {config.name} on {interface}")

            # Create config for this interface
            temp_config = Path(f"/tmp/{interface}.conf")
            temp_config.write_text(config.read_text())

            # Bring up interface
            result = subprocess.run(
                ['wg-quick', 'up', str(temp_config)],
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode == 0:
                with self.lock:
                    self.active_connections[worker_id] = {
                        'interface': interface,
                        'config': config.name
                    }
                logger.info(f"[Worker {worker_id}] Connected successfully")
                return True
            else:
                logger.error(f"[Worker {worker_id}] Failed to connect: {result.stderr}")
                return False

        except Exception as e:
            logger.error(f"[Worker {worker_id}] Connection error: {e}")
            return False

    def disconnect(self, worker_id: int):
        """Disconnect WireGuard for a worker"""
        interface = self.get_interface_name(worker_id)

        try:
            logger.info(f"[Worker {worker_id}] Disconnecting {interface}")
            subprocess.run(
                ['wg-quick', 'down', interface],
                capture_output=True,
                timeout=10
            )

            with self.lock:
                if worker_id in self.active_connections:
                    del self.active_connections[worker_id]

        except Exception as e:
            logger.error(f"[Worker {worker_id}] Disconnect error: {e}")

    def get_config_for_worker(self, worker_id: int) -> Optional[Path]:
        """Get WireGuard config for a worker"""
        if not self.configs:
            return None
        return self.configs[worker_id % len(self.configs)]


class VideoWorker:
    """Worker thread that processes video uploads"""

    def __init__(self, worker_id: int, work_queue: Queue, wg_manager: WireGuardManager):
        self.worker_id = worker_id
        self.work_queue = work_queue
        self.wg_manager = wg_manager
        self.uploader = None
        self.thread = None
        self.running = False

    def start(self):
        """Start the worker thread"""
        self.running = True
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def stop(self):
        """Stop the worker thread"""
        self.running = False
        if self.thread:
            self.thread.join(timeout=5)

    def _run(self):
        """Main worker loop"""
        logger.info(f"[Worker {self.worker_id}] Started")

        while self.running:
            try:
                # Get video from queue (blocking with timeout)
                video_file = self.work_queue.get(timeout=1)

                if video_file is None:  # Poison pill
                    break

                self._process_video(video_file)
                self.work_queue.task_done()

            except Exception as e:
                if self.running:  # Only log if not shutting down
                    logger.error(f"[Worker {self.worker_id}] Error: {e}")
                continue

        logger.info(f"[Worker {self.worker_id}] Stopped")

    def _process_video(self, video_file: Path):
        """Process a single video upload"""
        try:
            logger.info(f"[Worker {self.worker_id}] Processing: {video_file.name}")

            # Connect to WireGuard
            config = self.wg_manager.get_config_for_worker(self.worker_id)
            if config:
                if not self.wg_manager.connect(self.worker_id, config):
                    logger.error(f"[Worker {self.worker_id}] Failed to connect to VPN, skipping")
                    return

            # Create uploader instance for this worker
            if not self.uploader:
                self.uploader = VKVideoUploader(
                    vk_token=os.getenv('VK_TOKEN'),
                    videos_dir=Path(os.getenv('VIDEO_DIR', '/app/videos')),
                    wg_dir=self.wg_manager.wg_dir
                )

            # Determine playlist
            playlist_name = video_file.parent.name if video_file.parent.name != 'videos' else None
            playlist_id = None
            if playlist_name:
                playlist_id = self.uploader.get_or_create_playlist(playlist_name)

            # Upload video
            success = self.uploader.upload_video(video_file, playlist_id=playlist_id)

            if success:
                # Mark as uploaded
                self.uploader.mark_file_uploaded(video_file)
                logger.info(f"[Worker {self.worker_id}] ✓ Uploaded: {video_file.name}")
            else:
                logger.error(f"[Worker {self.worker_id}] ✗ Failed: {video_file.name}")

        except Exception as e:
            logger.error(f"[Worker {self.worker_id}] Error processing {video_file.name}: {e}")

        finally:
            # Disconnect VPN
            if config:
                self.wg_manager.disconnect(self.worker_id)


class StandaloneUploader:
    """Standalone continuous uploader with concurrent workers"""

    def __init__(self):
        self.videos_dir = Path(os.getenv('VIDEO_DIR', '/app/videos'))
        self.wg_dir = Path(os.getenv('WIREGUARD_DIR', '/app/wireguard'))
        self.poll_interval = int(os.getenv('POLL_INTERVAL', '300'))  # 5 minutes
        self.max_concurrent = int(os.getenv('MAX_CONCURRENT', '5'))

        self.wg_manager = WireGuardManager(self.wg_dir, self.max_concurrent)
        self.work_queue = Queue()
        self.workers = []
        self.running = False

        logger.info(f"Initialized standalone uploader:")
        logger.info(f"  Videos directory: {self.videos_dir}")
        logger.info(f"  WireGuard directory: {self.wg_dir}")
        logger.info(f"  Poll interval: {self.poll_interval}s")
        logger.info(f"  Max concurrent: {self.max_concurrent}")
        logger.info(f"  WireGuard configs: {len(self.wg_manager.configs)}")

    def _setup_wireguard_from_env(self):
        """Setup WireGuard configs from environment variables"""
        self.wg_dir.mkdir(parents=True, exist_ok=True)

        import base64
        config_count = 0

        for i in range(1, 11):  # Check up to 10 configs
            var_name = f"WG_CONFIG_{i}"
            name_var = f"WG_CONFIG_{i}_NAME"

            config_base64 = os.getenv(var_name)
            config_name = os.getenv(name_var, f"wg{i}.conf")

            if config_base64:
                try:
                    config_data = base64.b64decode(config_base64)
                    config_path = self.wg_dir / config_name
                    config_path.write_bytes(config_data)
                    config_path.chmod(0o600)
                    config_count += 1
                    logger.info(f"Created WireGuard config: {config_name}")
                except Exception as e:
                    logger.error(f"Failed to decode WG_CONFIG_{i}: {e}")

        if config_count > 0:
            logger.info(f"Generated {config_count} WireGuard config(s) from environment")
            # Refresh discovered configs
            self.wg_manager.configs = self.wg_manager._discover_configs()

    def _find_videos(self) -> List[Path]:
        """Find all unprocessed videos"""
        videos = []

        video_extensions = {'.mp4', '.avi', '.mov', '.mkv', '.wmv', '.flv', '.webm', '.m4v'}

        for ext in video_extensions:
            for video_file in self.videos_dir.rglob(f"*{ext}"):
                # Skip if already uploaded
                marker_file = video_file.with_suffix(video_file.suffix + '.uploaded')
                if not marker_file.exists():
                    videos.append(video_file)

        return sorted(videos)

    def _start_workers(self):
        """Start worker threads"""
        num_workers = min(self.max_concurrent, len(self.wg_manager.configs) or 1)

        logger.info(f"Starting {num_workers} worker(s)...")

        for i in range(num_workers):
            worker = VideoWorker(i, self.work_queue, self.wg_manager)
            worker.start()
            self.workers.append(worker)

    def _stop_workers(self):
        """Stop all worker threads"""
        logger.info("Stopping workers...")

        # Send poison pills
        for _ in self.workers:
            self.work_queue.put(None)

        # Wait for workers to finish
        for worker in self.workers:
            worker.stop()

        self.workers.clear()

    def run(self):
        """Main continuous polling loop"""
        self.running = True

        # Setup WireGuard from env if provided
        self._setup_wireguard_from_env()

        # Start workers
        self._start_workers()

        logger.info("Starting continuous polling...")

        try:
            while self.running:
                # Find videos to upload
                videos = self._find_videos()

                if videos:
                    logger.info(f"Found {len(videos)} video(s) to upload")

                    # Add videos to queue
                    for video in videos:
                        self.work_queue.put(video)

                    # Wait for queue to be processed
                    self.work_queue.join()
                    logger.info("Upload batch completed")
                else:
                    logger.debug("No videos found to upload")

                # Sleep until next poll
                logger.info(f"Sleeping for {self.poll_interval}s...")
                time.sleep(self.poll_interval)

        except KeyboardInterrupt:
            logger.info("Received shutdown signal")

        finally:
            self.running = False
            self._stop_workers()
            logger.info("Shutdown complete")


def main():
    """Main entry point"""
    uploader = StandaloneUploader()
    uploader.run()


if __name__ == '__main__':
    main()
