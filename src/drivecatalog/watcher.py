"""Volume mount/unmount detection using watchdog."""

import signal
import sqlite3
import sys
from collections.abc import Callable
from pathlib import Path

from rich.console import Console
from watchdog.events import DirCreatedEvent, DirDeletedEvent, FileSystemEventHandler
from watchdog.observers import Observer

from drivecatalog.config import load_config
from drivecatalog.drives import get_drive_by_mount_path
from drivecatalog.scanner import scan_drive

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


def auto_scan_on_mount(mount_path: Path, conn: sqlite3.Connection) -> None:
    """Perform automatic scan of a mounted drive if enabled in config.

    This function checks the configuration and database to determine
    if a scan should be performed, then executes the scan.

    Args:
        mount_path: Path to the mounted volume.
        conn: Database connection for lookups and scan operations.
    """
    console = Console()

    # Load config and check if auto-scan is enabled
    config = load_config()
    if not config.auto_scan_enabled:
        return

    # Check if volume name is in the allowed list (if set)
    volume_name = mount_path.name
    if (
        config.auto_scan_drives is not None
        and volume_name not in config.auto_scan_drives
    ):
        return

    # Look up drive by mount path
    drive = get_drive_by_mount_path(conn, mount_path)
    if drive is None:
        # Not a registered drive, skip
        return

    # Perform scan
    console.print(f"[bold blue]Auto-scanning '{drive['name']}'...[/bold blue]")

    try:
        result = scan_drive(
            drive["id"],
            str(mount_path),
            conn,
            progress_callback=None,  # No progress for background scan
        )

        # Update last_scan timestamp
        conn.execute(
            "UPDATE drives SET last_scan = datetime('now') WHERE id = ?",
            (drive["id"],),
        )
        conn.commit()

        console.print(
            f"[green]Auto-scan complete:[/green] {drive['name']} - "
            f"{result.new_files} new, {result.modified_files} modified, "
            f"{result.total_scanned} total files"
        )
    except Exception as e:
        console.print(f"[red]Auto-scan failed:[/red] {drive['name']} - {e}")
