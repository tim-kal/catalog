"""Volume mount/unmount detection using watchdog."""

import signal
import sys
from pathlib import Path
from typing import Callable

from watchdog.events import DirCreatedEvent, DirDeletedEvent, FileSystemEventHandler
from watchdog.observers import Observer

# Path to monitor for mount/unmount events
VOLUMES_PATH = Path("/Volumes")


class VolumeEventHandler(FileSystemEventHandler):
    """Handle mount/unmount events in /Volumes directory."""

    def __init__(
        self,
        db_path: Path,
        on_mount_callback: Callable[[Path], None],
        on_unmount_callback: Callable[[Path], None],
    ) -> None:
        """Initialize the event handler.

        Args:
            db_path: Path to the database (for future use).
            on_mount_callback: Called when a volume is mounted.
            on_unmount_callback: Called when a volume is unmounted.
        """
        super().__init__()
        self.db_path = db_path
        self.on_mount_callback = on_mount_callback
        self.on_unmount_callback = on_unmount_callback

    def on_created(self, event) -> None:
        """Handle directory creation (mount) events."""
        if isinstance(event, DirCreatedEvent):
            path = Path(event.src_path)
            # Filter out hidden directories (e.g., .Trashes)
            if not path.name.startswith("."):
                self.on_mount_callback(path)

    def on_deleted(self, event) -> None:
        """Handle directory deletion (unmount) events."""
        if isinstance(event, DirDeletedEvent):
            path = Path(event.src_path)
            # Filter out hidden directories
            if not path.name.startswith("."):
                self.on_unmount_callback(path)


def start_volume_watcher(handler: VolumeEventHandler) -> Observer:
    """Start watching /Volumes for mount/unmount events.

    Args:
        handler: The event handler to use.

    Returns:
        The started Observer instance for caller to manage.
    """
    observer = Observer()
    observer.schedule(handler, str(VOLUMES_PATH), recursive=False)
    observer.start()
    return observer


def get_mounted_volumes() -> list[Path]:
    """Get list of currently mounted volumes.

    Returns:
        List of Path objects for each mounted volume (excluding hidden).
    """
    if not VOLUMES_PATH.exists():
        return []

    volumes = []
    for entry in VOLUMES_PATH.iterdir():
        # Filter out hidden entries (e.g., .Trashes)
        if not entry.name.startswith(".") and entry.is_dir():
            volumes.append(entry)

    return volumes


def run_watcher(
    db_path: Path,
    on_mount: Callable[[Path], None],
    on_unmount: Callable[[Path], None],
) -> None:
    """Run the volume watcher as a foreground process.

    This is the main entry point for the CLI. It sets up signal handlers
    for graceful shutdown and loops until terminated.

    Args:
        db_path: Path to the database.
        on_mount: Callback for mount events.
        on_unmount: Callback for unmount events.
    """
    # Create handler and start observer
    handler = VolumeEventHandler(db_path, on_mount, on_unmount)
    observer = start_volume_watcher(handler)

    # Set up graceful shutdown on SIGTERM/SIGINT
    def shutdown(signum, frame):
        observer.stop()
        observer.join()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Loop with timeout for responsive shutdown
    try:
        while observer.is_alive():
            observer.join(timeout=1)
    finally:
        observer.stop()
        observer.join()
