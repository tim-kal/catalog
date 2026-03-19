"""File scanner with directory traversal and change detection for DriveCatalog."""

import os
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

# System directories to skip during scanning
SKIP_DIRECTORIES = {
    ".Spotlight-V100",
    ".fseventsd",
    ".Trashes",
    ".TemporaryItems",
    ".DocumentRevisions-V100",
}


@dataclass
class ScanResult:
    """Result of a drive scan operation."""

    new_files: int = 0
    modified_files: int = 0
    unchanged_files: int = 0
    removed_files: int = 0
    errors: int = 0
    total_scanned: int = 0


def scan_drive(
    drive_id: int,
    mount_path: str,
    conn: sqlite3.Connection,
    progress_callback: Callable[[str, dict[str, Any] | None], None] | None = None,
) -> ScanResult:
    """Scan a drive and update the files table.

    Traverses all directories under mount_path, collects file metadata,
    and performs INSERT/UPDATE operations based on change detection.

    Args:
        drive_id: ID of the drive in the database.
        mount_path: Path to the mounted drive.
        conn: Database connection (caller manages transaction).
        progress_callback: Optional callback called with current directory path.

    Returns:
        ScanResult with counts of new, modified, unchanged files and errors.
    """
    result = ScanResult()
    mount_path_obj = Path(mount_path)

    for dirpath, dirnames, filenames in os.walk(mount_path):
        current_path = Path(dirpath)

        # Skip hidden directories and system directories
        # Modify dirnames in-place to prevent os.walk from descending into them
        dirnames[:] = [
            d
            for d in dirnames
            if not d.startswith(".") and d not in SKIP_DIRECTORIES
        ]

        # Call progress callback with current directory and stats
        if progress_callback:
            try:
                rel_dir = current_path.relative_to(mount_path_obj)
                dir_str = str(rel_dir) if str(rel_dir) != "." else "/"
            except ValueError:
                dir_str = str(current_path)
            stats = {"total": result.total_scanned, "new": result.new_files}
            progress_callback(dir_str, stats)

        for filename in filenames:
            # Skip hidden files
            if filename.startswith("."):
                continue

            file_path = current_path / filename

            try:
                stat_info = file_path.stat()
                size_bytes = stat_info.st_size
                mtime = datetime.fromtimestamp(stat_info.st_mtime).isoformat()

                # Calculate path relative to mount point
                rel_path = str(file_path.relative_to(mount_path_obj))

                # Check if file exists in database
                existing = conn.execute(
                    "SELECT id, size_bytes, mtime FROM files WHERE drive_id = ? AND path = ?",
                    (drive_id, rel_path),
                ).fetchone()

                if existing is None:
                    # Insert new file
                    conn.execute(
                        """
                        INSERT INTO files (drive_id, path, filename, size_bytes, mtime)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        (drive_id, rel_path, filename, size_bytes, mtime),
                    )
                    result.new_files += 1
                elif existing["size_bytes"] != size_bytes or existing["mtime"] != mtime:
                    # Update modified file
                    conn.execute(
                        """
                        UPDATE files SET size_bytes = ?, mtime = ?, last_verified = datetime('now')
                        WHERE id = ?
                        """,
                        (size_bytes, mtime, existing["id"]),
                    )
                    result.modified_files += 1
                else:
                    # File unchanged
                    result.unchanged_files += 1

                result.total_scanned += 1

            except PermissionError:
                result.errors += 1
            except OSError:
                result.errors += 1

    # Remove files that no longer exist on disk (deleted since last scan)
    existing_paths = conn.execute(
        "SELECT id, path FROM files WHERE drive_id = ?",
        (drive_id,),
    ).fetchall()

    for row in existing_paths:
        full_path = mount_path_obj / row["path"]
        if not full_path.exists():
            conn.execute("DELETE FROM files WHERE id = ?", (row["id"],))
            # Also clean up associated media metadata
            conn.execute("DELETE FROM media_metadata WHERE file_id = ?", (row["id"],))
            result.removed_files += 1

    conn.commit()
    return result
