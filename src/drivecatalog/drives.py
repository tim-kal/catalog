"""Drive detection utilities for macOS."""

from __future__ import annotations

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


def get_smart_status(path: Path) -> dict:
    """Get SMART health and media type for a drive via diskutil.

    Returns:
        Dict with keys: smart_status, media_type, device_protocol
        smart_status: "Verified", "Failing", "Not Supported", or "Unknown"
        media_type: "SSD", "HDD", or None
    """
    try:
        result = subprocess.run(
            ["diskutil", "info", "-plist", str(path)],
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            return {"smart_status": "Unknown", "media_type": None, "device_protocol": None}

        plist_data = plistlib.loads(result.stdout)
        smart = plist_data.get("SMARTStatus", "Not Supported")
        is_solid_state = plist_data.get("SolidState")
        protocol = plist_data.get("DeviceProtocol")

        if is_solid_state is True:
            media_type = "SSD"
        elif is_solid_state is False:
            media_type = "HDD"
        else:
            media_type = None

        return {
            "smart_status": smart,
            "media_type": media_type,
            "device_protocol": protocol,
        }
    except (plistlib.InvalidFileException, OSError):
        return {"smart_status": "Unknown", "media_type": None, "device_protocol": None}


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


def get_drive_by_uuid(conn: sqlite3.Connection, uuid: str) -> dict | None:
    """Look up a registered drive by its volume UUID.

    Args:
        conn: Database connection.
        uuid: macOS VolumeUUID string.

    Returns:
        Dict with drive info or None if not found.
    """
    row = conn.execute(
        "SELECT id, name, mount_path, uuid, total_bytes, last_scan "
        "FROM drives WHERE uuid = ?",
        (uuid,),
    ).fetchone()

    if row is None:
        return None

    return dict(row)


def recognize_drive(conn: sqlite3.Connection, mount_path: Path) -> dict | None:
    """Recognize a mounted volume against registered drives using UUID.

    If the UUID matches a registered drive whose mount_path or name differs
    (e.g. drive was renamed in Finder), automatically update the registration.

    Args:
        conn: Database connection.
        mount_path: Current mount path of the volume.

    Returns:
        Dict with drive info (potentially updated) or None if not registered.
    """
    uuid = get_drive_uuid(mount_path)

    # Try UUID match first (survives renames)
    drive = None
    if uuid:
        drive = get_drive_by_uuid(conn, uuid)

    # Fall back to mount_path match
    if drive is None:
        drive = get_drive_by_mount_path(conn, mount_path)

    if drive is None:
        return None

    # Auto-update if mount_path or name changed
    current_mount = str(mount_path)
    current_name = mount_path.name
    needs_update = False

    if drive["mount_path"] != current_mount:
        needs_update = True
    if drive["name"] != current_name:
        needs_update = True

    if needs_update:
        total_bytes = get_drive_size(mount_path)
        conn.execute(
            "UPDATE drives SET name = ?, mount_path = ?, total_bytes = ? WHERE id = ?",
            (current_name, current_mount, total_bytes, drive["id"]),
        )
        conn.commit()
        drive["name"] = current_name
        drive["mount_path"] = current_mount
        drive["total_bytes"] = total_bytes

    return drive
