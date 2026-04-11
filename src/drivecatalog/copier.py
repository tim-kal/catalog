"""File copy with SHA256 integrity verification for DriveCatalog."""

import ctypes
import ctypes.util
import hashlib
import logging
import os
import shutil
import sqlite3
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

logger = logging.getLogger(__name__)

# Chunk size for streaming reads (1MB — reduces syscall overhead for large media files)
CHUNK_SIZE = 1 * 1024 * 1024


@dataclass
class CopyResult:
    """Result of a file copy operation."""

    source_hash: str
    dest_hash: str
    verified: bool
    bytes_copied: int
    error: str | None = None
    metadata_preserved: bool = False


def _copy_xattrs_macos(source: Path, dest: Path) -> bool:
    """Copy extended attributes using macOS native xattr API via ctypes."""
    try:
        libc_path = ctypes.util.find_library("c")
        if not libc_path:
            logger.warning("Could not find libc for xattr copy")
            return False
        libc = ctypes.CDLL(libc_path, use_errno=True)
        libc.listxattr.restype = ctypes.c_ssize_t
        libc.getxattr.restype = ctypes.c_ssize_t
        libc.setxattr.restype = ctypes.c_int
    except OSError as e:
        logger.warning("Could not load libc for xattr copy: %s", e)
        return False

    src_b = str(source).encode()
    dst_b = str(dest).encode()

    # listxattr(path, namebuf, size, options)
    buf_size = libc.listxattr(src_b, None, ctypes.c_size_t(0), ctypes.c_int(0))
    if buf_size <= 0:
        return True  # No xattrs to copy

    name_buf = ctypes.create_string_buffer(buf_size)
    if libc.listxattr(src_b, name_buf, ctypes.c_size_t(buf_size), ctypes.c_int(0)) <= 0:
        return True

    names = [n for n in name_buf.raw[:buf_size].split(b"\x00") if n]
    all_ok = True

    for name in names:
        # getxattr(path, name, value, size, position, options)
        val_size = libc.getxattr(
            src_b, name, None,
            ctypes.c_size_t(0), ctypes.c_uint32(0), ctypes.c_int(0),
        )
        if val_size < 0:
            logger.warning("xattr read failed: %s on %s", name, source)
            all_ok = False
            continue

        val_buf = ctypes.create_string_buffer(max(val_size, 1))
        if val_size > 0:
            got = libc.getxattr(
                src_b, name, val_buf,
                ctypes.c_size_t(val_size), ctypes.c_uint32(0), ctypes.c_int(0),
            )
            if got < 0:
                logger.warning("xattr read failed: %s on %s", name, source)
                all_ok = False
                continue

        # setxattr(path, name, value, size, position, options)
        if libc.setxattr(
            dst_b, name, val_buf,
            ctypes.c_size_t(val_size), ctypes.c_uint32(0), ctypes.c_int(0),
        ) != 0:
            logger.warning("xattr write failed: %s on %s", name, dest)
            all_ok = False

    return all_ok


def _preserve_metadata(source: Path, dest: Path) -> bool:
    """Preserve file metadata from source to dest.

    Copies mtime/atime/mode, creation date (birthtime), and extended
    attributes (Finder tags, color labels).

    Returns True if all metadata was preserved without errors.
    """
    all_ok = True

    # mtime, atime, mode
    try:
        shutil.copystat(source, dest)
    except OSError as e:
        logger.warning("copystat failed %s → %s: %s", source, dest, e)
        all_ok = False

    # Creation date (birthtime) — macOS only
    try:
        birthtime = os.stat(source).st_birthtime
        birth_dt = datetime.fromtimestamp(birthtime)
        formatted = birth_dt.strftime("%m/%d/%Y %H:%M:%S")
        result = subprocess.run(
            ["SetFile", "-d", formatted, str(dest)],
            capture_output=True,
            timeout=10,
        )
        if result.returncode != 0:
            logger.warning(
                "SetFile -d failed for %s: %s", dest, result.stderr.decode()
            )
            all_ok = False
    except (AttributeError, FileNotFoundError, subprocess.TimeoutExpired, OSError) as e:
        logger.warning("Could not preserve birthtime for %s: %s", dest, e)
        all_ok = False

    # Extended attributes (Finder tags, color labels)
    if hasattr(os, "listxattr"):
        try:
            for attr_name in os.listxattr(source):
                try:
                    value = os.getxattr(source, attr_name)
                    os.setxattr(dest, attr_name, value)
                except OSError as e:
                    logger.warning(
                        "xattr %s copy failed %s: %s", attr_name, source, e
                    )
                    all_ok = False
        except OSError as e:
            logger.warning("listxattr failed %s: %s", source, e)
            all_ok = False
    else:
        if not _copy_xattrs_macos(source, dest):
            all_ok = False

    return all_ok


def copy_file_verified(
    source: Path,
    dest: Path,
    progress_callback: Callable[[int], None] | None = None,
) -> CopyResult:
    """Copy a file with streaming SHA256 verification.

    Uses atomic temp-file write (.dctmp) with fsync for crash safety.
    Preserves file metadata after successful verification.

    Args:
        source: Path to source file.
        dest: Path to destination file.
        progress_callback: Optional callback called with bytes_written
            (throttled to at most every 250ms, always called on final chunk).

    Returns:
        CopyResult with hashes, verification status, and any error message.
    """
    tmp_path = dest.with_suffix(dest.suffix + ".dctmp")

    try:
        # Create parent directories if needed
        dest.parent.mkdir(parents=True, exist_ok=True)

        source_hasher = hashlib.sha256()
        bytes_copied = 0
        file_size = source.stat().st_size
        last_progress_time = -1.0

        # Stream-read source, hash, and write to temp file
        with open(source, "rb") as src_file, open(tmp_path, "wb") as dest_file:
            while chunk := src_file.read(CHUNK_SIZE):
                source_hasher.update(chunk)
                dest_file.write(chunk)
                bytes_copied += len(chunk)
                if progress_callback:
                    now = time.monotonic()
                    is_final = bytes_copied >= file_size
                    if is_final or now - last_progress_time >= 0.250:
                        progress_callback(bytes_copied)
                        last_progress_time = now

            # fsync before close — ensures data is on physical medium
            dest_file.flush()
            os.fsync(dest_file.fileno())

        source_hash = source_hasher.hexdigest()

        # Re-read temp file to compute its hash
        dest_hasher = hashlib.sha256()
        with open(tmp_path, "rb") as f:
            while chunk := f.read(CHUNK_SIZE):
                dest_hasher.update(chunk)

        dest_hash = dest_hasher.hexdigest()

        # Compare hashes
        verified = source_hash == dest_hash

        if not verified:
            from drivecatalog.errors import log_error

            log_error("DC-E007", {"source": str(source), "dest": str(dest)})
            # Hash mismatch — delete temp file, do not create final path
            try:
                tmp_path.unlink()
            except OSError:
                pass
            return CopyResult(
                source_hash=source_hash,
                dest_hash=dest_hash,
                verified=False,
                bytes_copied=bytes_copied,
            )

        # Verification passed — atomic rename temp to final path
        os.rename(tmp_path, dest)

        # Preserve metadata
        metadata_ok = _preserve_metadata(source, dest)

        return CopyResult(
            source_hash=source_hash,
            dest_hash=dest_hash,
            verified=True,
            bytes_copied=bytes_copied,
            metadata_preserved=metadata_ok,
        )

    except (OSError, PermissionError) as e:
        from drivecatalog.errors import log_error

        log_error(
            "DC-E005",
            {"source": str(source), "dest": str(dest), "error": str(e)},
        )
        # Clean up temp file on error
        try:
            tmp_path.unlink()
        except OSError:
            pass
        return CopyResult(
            source_hash="",
            dest_hash="",
            verified=False,
            bytes_copied=0,
            error=str(e),
        )


def log_copy_operation(
    conn: sqlite3.Connection,
    source_file_id: int,
    dest_drive_id: int,
    dest_path: str,
    result: CopyResult,
    started_at: datetime,
    completed_at: datetime,
) -> int:
    """Log a copy operation to the database.

    Args:
        conn: Database connection.
        source_file_id: ID of the source file in files table.
        dest_drive_id: ID of the destination drive.
        dest_path: Relative path on destination drive.
        result: CopyResult from copy_file_verified.
        started_at: When the copy started.
        completed_at: When the copy finished.

    Returns:
        The inserted row ID.
    """
    cursor = conn.execute(
        """
        INSERT INTO copy_operations (
            source_file_id, dest_drive_id, dest_path,
            source_hash, dest_hash, verified,
            bytes_copied, started_at, completed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            source_file_id,
            dest_drive_id,
            dest_path,
            result.source_hash,
            result.dest_hash,
            1 if result.verified else 0,
            result.bytes_copied,
            started_at.isoformat(),
            completed_at.isoformat(),
        ),
    )
    conn.commit()
    return cursor.lastrowid
