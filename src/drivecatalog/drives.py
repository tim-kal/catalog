"""Drive detection utilities for macOS."""

from __future__ import annotations

import hashlib
import logging
import os
import plistlib
import re
import sqlite3
import subprocess
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class DriveIdentifiers:
    """All available identifiers for a mounted volume."""

    volume_uuid: str | None = None
    disk_uuid: str | None = None
    device_serial: str | None = None
    partition_index: int | None = None
    fs_fingerprint: str | None = None


@dataclass
class RecognitionResult:
    """Result of recognizing a mounted volume against registered drives."""

    drive: dict | None = None
    confidence: str = "none"  # certain|probable|ambiguous|weak|none
    candidates: list[dict] | None = None


def _get_diskutil_plist(path: str) -> dict | None:
    """Run diskutil info -plist on a path and return the parsed plist dict."""
    try:
        result = subprocess.run(
            ["diskutil", "info", "-plist", path],
            capture_output=True,
            check=False,
            timeout=10,
        )
        if result.returncode != 0:
            return None
        return plistlib.loads(result.stdout)
    except (plistlib.InvalidFileException, OSError, subprocess.TimeoutExpired):
        return None


def collect_drive_identifiers(path: Path) -> DriveIdentifiers:
    """Collect all available identifiers for a mounted volume.

    Calls diskutil info -plist once and extracts every identifier signal.
    For device_serial, makes a second call on the parent whole disk.
    """
    ids = DriveIdentifiers()
    plist = _get_diskutil_plist(str(path))
    if plist is None:
        return ids

    ids.volume_uuid = plist.get("VolumeUUID")
    ids.disk_uuid = plist.get("DiskUUID")

    # Extract partition index from DeviceIdentifier (e.g. "disk2s1" → 1)
    dev_id = plist.get("DeviceIdentifier", "")
    m = re.search(r"s(\d+)$", dev_id)
    if m:
        ids.partition_index = int(m.group(1))

    # FS fingerprint: hash of (TotalSize + FilesystemType + AllocationBlockSize)
    total_size = plist.get("TotalSize")
    fs_type = plist.get("FilesystemType")
    block_size = plist.get("VolumeAllocationBlockSize")
    if total_size is not None and fs_type is not None and block_size is not None:
        raw = f"{total_size}:{fs_type}:{block_size}"
        ids.fs_fingerprint = hashlib.sha256(raw.encode()).hexdigest()[:16]

    # Device serial: get the REAL hardware serial number via ioreg.
    # diskutil only gives the product name (e.g. "SanDisk Extreme Pro Media")
    # which is identical for all drives of the same model.
    # The actual per-device serial is in IOKit: Device Characteristics → Serial Number.
    parent_disk = plist.get("ParentWholeDisk")
    if parent_disk:
        ids.device_serial = _get_device_serial_from_ioreg(parent_disk)

    return ids


def _get_device_serial_from_ioreg(disk_name: str) -> str | None:
    """Extract the hardware serial number for a disk from IOKit via ioreg.

    Parses ioreg output to find a Serial Number near the BSD Name matching
    our disk. Each physical device has a unique serial — this is the only
    reliable way to distinguish two identical USB drives.

    Args:
        disk_name: e.g. "disk4" (the parent whole disk, not a partition)

    Returns:
        Per-device serial string, or None if not available.
    """
    try:
        result = subprocess.run(
            ["ioreg", "-r", "-c", "IOBlockStorageDevice", "-l"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            return None

        lines = result.stdout.splitlines()
        for i, line in enumerate(lines):
            serial_m = re.search(r'"Serial Number"\s*=\s*"([^"]+)"', line)
            if not serial_m:
                continue
            # Check nearby lines (within context window) for our BSD Name
            context = lines[max(0, i - 10): i + 50]
            for cl in context:
                bsd_m = re.search(r'"BSD Name"\s*=\s*"' + re.escape(disk_name) + r'"', cl)
                if bsd_m:
                    return serial_m.group(1).strip()

    except (OSError, subprocess.TimeoutExpired):
        pass

    return None


def is_real_mount(path: str | Path) -> bool:
    """Check if a path is a real mounted volume, not a phantom leftover directory.

    After unmount, macOS can briefly leave an empty directory at the mount point.
    statvfs on such a phantom directory returns the ROOT filesystem values (boot disk),
    which would corrupt our stored drive data. This check uses st_dev to verify
    the path is on a different device than /Volumes itself.
    """
    path_str = str(path)
    if not os.path.exists(path_str):
        return False
    try:
        stat_path = os.stat(path_str)
        stat_volumes = os.stat("/Volumes")
        return stat_path.st_dev != stat_volumes.st_dev
    except OSError:
        return False


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


def _update_drive_identifiers(
    conn: sqlite3.Connection,
    drive_id: int,
    mount_path: Path,
    ids: DriveIdentifiers,
) -> None:
    """Update a drive's identifiers and mount info to latest values.

    NEVER overwrites the user-assigned drive name — only updates mount_path,
    total_bytes, used_bytes, and identifier columns.
    """
    # Only read live disk stats if the mount is real (not a phantom directory)
    if is_real_mount(mount_path):
        total_bytes = get_drive_size(mount_path)
        try:
            stat = os.statvfs(mount_path)
            free = stat.f_frsize * stat.f_bavail
            used_bytes = total_bytes - free
        except OSError:
            used_bytes = None
    else:
        total_bytes = None
        used_bytes = None

    conn.execute(
        """UPDATE drives SET
            mount_path = ?, total_bytes = COALESCE(?, total_bytes), used_bytes = COALESCE(?, used_bytes),
            uuid = COALESCE(?, uuid),
            disk_uuid = COALESCE(?, disk_uuid),
            device_serial = COALESCE(?, device_serial),
            partition_index = COALESCE(?, partition_index),
            fs_fingerprint = COALESCE(?, fs_fingerprint)
        WHERE id = ?""",
        (
            str(mount_path),
            total_bytes,
            used_bytes,
            ids.volume_uuid,
            ids.disk_uuid,
            ids.device_serial,
            ids.partition_index,
            ids.fs_fingerprint,
            drive_id,
        ),
    )
    conn.commit()


def _drive_select_columns() -> str:
    """Column list for drive queries including new identifier columns."""
    return (
        "id, name, mount_path, uuid, total_bytes, last_scan, "
        "disk_uuid, device_serial, partition_index, fs_fingerprint"
    )


def recognize_drive(conn: sqlite3.Connection, mount_path: Path) -> RecognitionResult:
    """Recognize a mounted volume using multi-signal identifier cascade.

    Priority:
      1. VolumeUUID match → certain
      2. DiskUUID match → certain
      3. Device Serial + Partition Index → certain
      4. FS Fingerprint, single candidate → probable
      5. FS Fingerprint, multiple candidates → ambiguous
      6. mount_path only match → weak
      7. No match → none

    On successful recognition the stored identifiers are updated.
    """
    ids = collect_drive_identifiers(mount_path)
    cols = _drive_select_columns()

    # 1. VolumeUUID match
    if ids.volume_uuid:
        row = conn.execute(
            f"SELECT {cols} FROM drives WHERE uuid = ?", (ids.volume_uuid,)
        ).fetchone()
        if row:
            drive = dict(row)
            _update_drive_identifiers(conn, drive["id"], mount_path, ids)
            drive["mount_path"] = str(mount_path)
            # Keep user-assigned name — don't overwrite with Finder volume name
            return RecognitionResult(drive=drive, confidence="certain")

    # 2. DiskUUID match
    if ids.disk_uuid:
        row = conn.execute(
            f"SELECT {cols} FROM drives WHERE disk_uuid = ?", (ids.disk_uuid,)
        ).fetchone()
        if row:
            drive = dict(row)
            _update_drive_identifiers(conn, drive["id"], mount_path, ids)
            drive["mount_path"] = str(mount_path)
            # Keep user-assigned name — don't overwrite with Finder volume name
            return RecognitionResult(drive=drive, confidence="certain")

    # 3. Device Serial + Partition Index
    if ids.device_serial and ids.partition_index is not None:
        rows = conn.execute(
            f"SELECT {cols} FROM drives WHERE device_serial = ? AND partition_index = ?",
            (ids.device_serial, ids.partition_index),
        ).fetchall()
        # Filter out candidates that are currently mounted elsewhere
        candidates = [
            r for r in rows
            if not r["mount_path"] or not Path(r["mount_path"]).exists()
            or str(mount_path) == r["mount_path"]
        ]
        if len(candidates) == 1:
            drive = dict(candidates[0])
            _update_drive_identifiers(conn, drive["id"], mount_path, ids)
            drive["mount_path"] = str(mount_path)
            # Keep user-assigned name — don't overwrite with Finder volume name
            return RecognitionResult(drive=drive, confidence="certain")

    # 4/5. FS Fingerprint match
    if ids.fs_fingerprint:
        rows = conn.execute(
            f"SELECT {cols} FROM drives WHERE fs_fingerprint = ?",
            (ids.fs_fingerprint,),
        ).fetchall()

        # Filter out candidates whose mount_path is currently mounted (= different physical drive)
        candidates_not_mounted = [
            r for r in rows
            if not r["mount_path"] or not Path(r["mount_path"]).exists()
            or str(mount_path) == r["mount_path"]
        ]

        if len(candidates_not_mounted) == 1:
            drive = dict(candidates_not_mounted[0])
            _update_drive_identifiers(conn, drive["id"], mount_path, ids)
            drive["mount_path"] = str(mount_path)
            logger.warning(
                "Drive '%s' recognized by FS fingerprint only (probable match)",
                mount_path.name,
            )
            return RecognitionResult(drive=drive, confidence="probable")

        # Multiple candidates or all currently mounted → ambiguous, ask user
        if rows:
            from drivecatalog.errors import log_error
            log_error("DC-E010", {"mount_path": str(mount_path), "candidate_count": len(rows)})
            candidates = [dict(r) for r in rows]
            return RecognitionResult(
                drive=None, confidence="ambiguous", candidates=candidates
            )

    # 6. mount_path fallback — DO NOT auto-update identifiers on weak match.
    # This match is unreliable (two drives with the same Finder name share a mount_path).
    # Return the candidate but let the frontend ask the user to confirm.
    row = conn.execute(
        f"SELECT {cols} FROM drives WHERE mount_path = ?", (str(mount_path),)
    ).fetchone()
    if row:
        drive = dict(row)
        # Don't call _update_drive_identifiers — this might be the wrong drive
        return RecognitionResult(drive=drive, confidence="weak")

    # 7. No match
    return RecognitionResult()
