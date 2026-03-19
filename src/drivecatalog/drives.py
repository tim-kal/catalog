"""Drive detection utilities for macOS."""

import os
import plistlib
import sqlite3
import subprocess
from pathlib import Path


def get_drive_uuid(path: Path) -> str | None:
    """Get the VolumeUUID for a mounted volume.

    Uses diskutil to get volume information and extracts the VolumeUUID.

    Args:
        path: Path to the mount point (e.g., /Volumes/MyDrive)

    Returns:
        The VolumeUUID string, or None if not found or command fails.
    """
    try:
        result = subprocess.run(
            ["diskutil", "info", "-plist", str(path)],
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            return None

        plist_data = plistlib.loads(result.stdout)
        return plist_data.get("VolumeUUID")
    except (plistlib.InvalidFileException, OSError):
        return None


def get_drive_size(path: Path) -> int:
    """Get the total size of a mounted volume in bytes.

    Args:
        path: Path to the mount point

    Returns:
        Total bytes of the volume.
    """
    stat = os.statvfs(path)
    return stat.f_frsize * stat.f_blocks


def get_drive_info(path: Path) -> dict:
    """Get comprehensive drive information.

    Args:
        path: Path to the mount point

    Returns:
        Dict with keys: uuid, total_bytes, name, mount_path
    """
    return {
        "uuid": get_drive_uuid(path),
        "total_bytes": get_drive_size(path),
        "name": path.name,
        "mount_path": str(path),
    }


def validate_mount_path(path: Path | str) -> bool:
    """Validate that a path is a valid macOS mount point.

    A valid mount point must:
    - Exist
    - Be a directory
    - Be under /Volumes/

    Args:
        path: Path to validate

    Returns:
        True if valid mount point, False otherwise.
    """
    if isinstance(path, str):
        path = Path(path)

    if not path.exists():
        return False

    if not path.is_dir():
        return False

    # Must be under /Volumes/
    try:
        path.relative_to("/Volumes")
        return True
    except ValueError:
        return False


def get_drive_by_mount_path(conn: sqlite3.Connection, mount_path: Path) -> dict | None:
    """Look up a registered drive by its mount path.

    Args:
        conn: Database connection.
        mount_path: Path to the mount point.

    Returns:
        Dict with drive info (id, name, mount_path, uuid, total_bytes, last_scan)
        or None if not found.
    """
    row = conn.execute(
        "SELECT id, name, mount_path, uuid, total_bytes, last_scan "
        "FROM drives WHERE mount_path = ?",
        (str(mount_path),),
    ).fetchone()

    if row is None:
        return None

    return dict(row)
