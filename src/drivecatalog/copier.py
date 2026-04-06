"""File copy with SHA256 integrity verification for DriveCatalog."""

import hashlib
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

# Chunk size for streaming reads (64KB)
CHUNK_SIZE = 64 * 1024


@dataclass
class CopyResult:
    """Result of a file copy operation."""

    source_hash: str
    dest_hash: str
    verified: bool
    bytes_copied: int
    error: str | None = None


def copy_file_verified(
    source: Path,
    dest: Path,
    progress_callback: Callable[[int], None] | None = None,
) -> CopyResult:
    """Copy a file with streaming SHA256 verification.

    Computes SHA256 of source while writing to destination, then re-reads
    destination to compute its hash and verify integrity.

    Args:
        source: Path to source file.
        dest: Path to destination file.
        progress_callback: Optional callback called with bytes_written after each chunk.

    Returns:
        CopyResult with hashes, verification status, and any error message.
    """
    try:
        # Create parent directories if needed
        dest.parent.mkdir(parents=True, exist_ok=True)

        source_hasher = hashlib.sha256()
        bytes_copied = 0

        # Stream-read source, hash, and write to destination
        with open(source, "rb") as src_file, open(dest, "wb") as dest_file:
            while chunk := src_file.read(CHUNK_SIZE):
                source_hasher.update(chunk)
                dest_file.write(chunk)
                bytes_copied += len(chunk)
                if progress_callback:
                    progress_callback(bytes_copied)

        source_hash = source_hasher.hexdigest()

        # Re-read destination to compute its hash
        dest_hasher = hashlib.sha256()
        with open(dest, "rb") as dest_file:
            while chunk := dest_file.read(CHUNK_SIZE):
                dest_hasher.update(chunk)

        dest_hash = dest_hasher.hexdigest()

        # Compare hashes
        verified = source_hash == dest_hash

        if not verified:
            from drivecatalog.errors import log_error
            log_error("DC-E007", {"source": str(source), "dest": str(dest)})

        return CopyResult(
            source_hash=source_hash,
            dest_hash=dest_hash,
            verified=verified,
            bytes_copied=bytes_copied,
        )

    except (OSError, PermissionError) as e:
        from drivecatalog.errors import log_error
        log_error("DC-E005", {"source": str(source), "dest": str(dest), "error": str(e)})
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
