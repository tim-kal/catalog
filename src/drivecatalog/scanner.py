"""File scanner with directory traversal and change detection for DriveCatalog."""

from __future__ import annotations

import logging
import os
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# System directories to skip during scanning
SKIP_DIRECTORIES = {
    ".Spotlight-V100",
    ".fseventsd",
    ".Trashes",
    ".TemporaryItems",
    ".DocumentRevisions-V100",
}

# macOS bundle extensions whose internal files are catalog-protected.
# Files inside these bundles should not be treated as regular duplicates
# because deleting them would corrupt the containing library/catalog.
CATALOG_BUNDLE_EXTENSIONS = {".cocatalog", ".photoslibrary", ".RDC", ".fcpbundle", ".lrcat", ".dvr"}


def get_catalog_bundle_root(rel_path: str) -> str | None:
    """Return the bundle root directory name if a file is inside a catalog bundle, else None.

    Examines each parent path component to see if it ends with a known bundle
    extension (case-insensitive).  Returns the matching component name
    (e.g. ``"Photos.photoslibrary"``) so callers can store it as a path string.
    """
    parts = rel_path.split("/")
    # Check all parent components (not the file itself)
    for part in parts[:-1]:
        dot = part.rfind(".")
        if dot >= 0:
            ext = part[dot:].lower()
            if ext in {e.lower() for e in CATALOG_BUNDLE_EXTENSIONS}:
                return part
    return None


@dataclass
class ScanResult:
    """Result of a drive scan operation."""

    new_files: int = 0
    modified_files: int = 0
    unchanged_files: int = 0
    removed_files: int = 0
    errors: int = 0
    total_scanned: int = 0
    cancelled: bool = False
    dirs_scanned: int = 0
    dirs_skipped: int = 0


def _should_skip_dir(name: str) -> bool:
    return name.startswith(".") or name in SKIP_DIRECTORIES


def count_files(mount_path: str) -> int:
    """Quick pre-count of files on a drive (no stat calls, just directory listing)."""
    count = 0
    for _dirpath, dirnames, filenames in os.walk(mount_path):
        dirnames[:] = [d for d in dirnames if not _should_skip_dir(d)]
        count += sum(1 for f in filenames if not f.startswith("."))
    return count


def _process_directory_files(
    drive_id: int,
    mount_path_obj: Path,
    dir_path: Path,
    filenames: list[str],
    conn: sqlite3.Connection,
    result: ScanResult,
    cancel_check: Callable[[], bool] | None = None,
) -> tuple[int, int]:
    """Process files in a single directory, updating the DB.

    Returns (file_count, total_size_bytes) for folder_stats.
    """
    dir_file_count = 0
    dir_total_size = 0

    for filename in filenames:
        if filename.startswith("."):
            continue

        if cancel_check and cancel_check():
            result.cancelled = True
            return dir_file_count, dir_total_size

        file_path = dir_path / filename

        try:
            stat_info = file_path.stat()
            size_bytes = stat_info.st_size
            mtime = datetime.fromtimestamp(stat_info.st_mtime).isoformat()
            rel_path = str(file_path.relative_to(mount_path_obj))

            bundle_root = get_catalog_bundle_root(rel_path)

            existing = conn.execute(
                "SELECT id, size_bytes, mtime FROM files WHERE drive_id = ? AND path = ?",
                (drive_id, rel_path),
            ).fetchone()

            if existing is None:
                conn.execute(
                    "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, catalog_bundle) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    (drive_id, rel_path, filename, size_bytes, mtime, bundle_root),
                )
                result.new_files += 1
            elif existing["size_bytes"] != size_bytes or existing["mtime"] != mtime:
                conn.execute(
                    "UPDATE files SET size_bytes = ?, mtime = ?, last_verified = datetime('now') "
                    "WHERE id = ?",
                    (size_bytes, mtime, existing["id"]),
                )
                result.modified_files += 1
            else:
                result.unchanged_files += 1

            result.total_scanned += 1
            dir_file_count += 1
            dir_total_size += size_bytes

        except PermissionError:
            from drivecatalog.errors import log_error
            log_error("DC-E004", {"drive_id": drive_id, "file": str(file_path)})
            result.errors += 1
        except OSError as e:
            logger.warning("Scan error in %s: %s", dirpath, e)
            result.errors += 1

    return dir_file_count, dir_total_size


def _update_folder_stats(
    conn: sqlite3.Connection,
    drive_id: int,
    rel_dir: str,
    file_count: int,
    total_size: int,
    child_dir_count: int,
    dir_mtime: str,
) -> None:
    """Insert or update folder_stats for a directory."""
    conn.execute(
        "INSERT OR REPLACE INTO folder_stats "
        "(drive_id, path, file_count, total_size_bytes, child_dir_count, dir_mtime, last_updated) "
        "VALUES (?, ?, ?, ?, ?, ?, datetime('now'))",
        (drive_id, rel_dir, file_count, total_size, child_dir_count, dir_mtime),
    )


def _delete_files_in_dir(
    conn: sqlite3.Connection, drive_id: int, rel_dir: str, seen_paths: set[str]
) -> int:
    """Delete DB file records for a directory that are no longer on disk.

    Only checks immediate children of the directory (not recursive).
    Returns number of files removed.
    """
    removed = 0
    if rel_dir:
        # Files directly in this directory: path starts with rel_dir/ but has no further /
        db_files = conn.execute(
            "SELECT id, path FROM files WHERE drive_id = ? AND path LIKE ? AND path NOT LIKE ?",
            (drive_id, rel_dir + "/%", rel_dir + "/%/%"),
        ).fetchall()
    else:
        # Root directory: files with no / in path
        db_files = conn.execute(
            "SELECT id, path FROM files WHERE drive_id = ? AND path NOT LIKE '%/%'",
            (drive_id,),
        ).fetchall()

    for row in db_files:
        if row["path"] not in seen_paths:
            conn.execute("DELETE FROM files WHERE id = ?", (row["id"],))
            conn.execute("DELETE FROM media_metadata WHERE file_id = ?", (row["id"],))
            removed += 1

    return removed


def scan_drive(
    drive_id: int,
    mount_path: str,
    conn: sqlite3.Connection,
    progress_callback: Callable[[str, dict[str, Any] | None], None] | None = None,
    cancel_check: Callable[[], bool] | None = None,
    total_estimate: int = 0,
) -> ScanResult:
    """Full scan of a drive — updates files table and populates folder_stats.

    Args:
        drive_id: ID of the drive in the database.
        mount_path: Path to the mounted drive.
        conn: Database connection (caller manages transaction).
        progress_callback: Optional callback called with current directory path.
        cancel_check: Optional callable that returns True if scan should stop.
        total_estimate: Estimated total file count for progress calculation.

    Returns:
        ScanResult with counts of new, modified, unchanged files and errors.
    """
    result = ScanResult()
    mount_path_obj = Path(mount_path)

    for dirpath, dirnames, filenames in os.walk(mount_path):
        if cancel_check and cancel_check():
            result.cancelled = True
            conn.commit()
            return result

        current_path = Path(dirpath)
        dirnames[:] = [d for d in dirnames if not _should_skip_dir(d)]

        # Compute relative directory path
        try:
            rel_dir_path = current_path.relative_to(mount_path_obj)
            rel_dir = str(rel_dir_path) if str(rel_dir_path) != "." else ""
            dir_str = str(rel_dir_path) if str(rel_dir_path) != "." else "/"
        except ValueError:
            rel_dir = str(current_path)
            dir_str = str(current_path)

        if progress_callback:
            stats = {
                "total": result.total_scanned,
                "new": result.new_files,
                "total_estimate": total_estimate,
            }
            progress_callback(dir_str, stats)

        # Process files
        dir_file_count, dir_total_size = _process_directory_files(
            drive_id, mount_path_obj, current_path, filenames, conn, result, cancel_check
        )
        if result.cancelled:
            conn.commit()
            return result

        result.dirs_scanned += 1

        # Record folder stats
        try:
            dir_mtime = datetime.fromtimestamp(current_path.stat().st_mtime).isoformat()
        except OSError:
            dir_mtime = datetime.now().isoformat()

        _update_folder_stats(
            conn, drive_id, rel_dir, dir_file_count, dir_total_size, len(dirnames), dir_mtime
        )

    # Remove files that no longer exist on disk
    existing_paths = conn.execute(
        "SELECT id, path FROM files WHERE drive_id = ?",
        (drive_id,),
    ).fetchall()

    for row in existing_paths:
        if cancel_check and cancel_check():
            result.cancelled = True
            conn.commit()
            return result

        full_path = mount_path_obj / row["path"]
        if not full_path.exists():
            conn.execute("DELETE FROM files WHERE id = ?", (row["id"],))
            conn.execute("DELETE FROM media_metadata WHERE file_id = ?", (row["id"],))
            result.removed_files += 1

    # Clean up folder_stats for directories that no longer exist
    stored_dirs = conn.execute(
        "SELECT path FROM folder_stats WHERE drive_id = ?", (drive_id,)
    ).fetchall()
    for row in stored_dirs:
        dir_full = mount_path_obj / row["path"] if row["path"] else mount_path_obj
        if not dir_full.exists():
            conn.execute(
                "DELETE FROM folder_stats WHERE drive_id = ? AND path = ?",
                (drive_id, row["path"]),
            )

    conn.commit()
    return result


def smart_scan_drive(
    drive_id: int,
    mount_path: str,
    conn: sqlite3.Connection,
    progress_callback: Callable[[str, dict[str, Any] | None], None] | None = None,
    cancel_check: Callable[[], bool] | None = None,
) -> ScanResult:
    """Incremental scan that only processes directories whose mtime changed.

    Uses folder_stats to detect which directories have been modified since
    the last scan. Unchanged directories are skipped entirely (no per-file
    stat calls), which is dramatically faster on large HDDs.

    Falls back to a full scan if no folder_stats exist yet.

    Args:
        drive_id: ID of the drive in the database.
        mount_path: Path to the mounted drive.
        conn: Database connection.
        progress_callback: Optional callback for progress updates.
        cancel_check: Optional cancellation check.

    Returns:
        ScanResult with counts including dirs_scanned and dirs_skipped.
    """
    mount_path_obj = Path(mount_path)
    result = ScanResult()

    # Load existing folder stats
    existing_stats: dict[str, dict] = {}
    for row in conn.execute(
        "SELECT path, file_count, total_size_bytes, child_dir_count, dir_mtime "
        "FROM folder_stats WHERE drive_id = ?",
        (drive_id,),
    ).fetchall():
        existing_stats[row["path"]] = dict(row)

    # If no folder stats exist, fall back to full scan
    if not existing_stats:
        total_estimate = conn.execute(
            "SELECT COUNT(*) FROM files WHERE drive_id = ?", (drive_id,)
        ).fetchone()[0]
        return scan_drive(
            drive_id, mount_path, conn, progress_callback, cancel_check, total_estimate
        )

    # Estimate total for progress (use DB file count)
    total_estimate = conn.execute(
        "SELECT COUNT(*) FROM files WHERE drive_id = ?", (drive_id,)
    ).fetchone()[0]

    visited_dirs: set[str] = set()

    def process_directory(dir_path: Path, rel_dir: str) -> None:
        if cancel_check and cancel_check():
            result.cancelled = True
            return

        visited_dirs.add(rel_dir)

        # Stat this directory to get its mtime
        try:
            dir_stat = dir_path.stat()
            dir_mtime = datetime.fromtimestamp(dir_stat.st_mtime).isoformat()
        except OSError:
            result.errors += 1
            return

        stored = existing_stats.get(rel_dir)
        dir_changed = stored is None or stored["dir_mtime"] != dir_mtime

        # List directory contents (cheap — just reads directory, minimal I/O)
        subdirs: list[os.DirEntry] = []
        file_entries: list[os.DirEntry] = []
        try:
            for entry in os.scandir(dir_path):
                name = entry.name
                if entry.is_dir(follow_symlinks=False):
                    if not _should_skip_dir(name):
                        subdirs.append(entry)
                elif entry.is_file(follow_symlinks=False):
                    if not name.startswith("."):
                        file_entries.append(entry)
        except PermissionError:
            result.errors += 1
            return

        if progress_callback:
            dir_str = rel_dir if rel_dir else "/"
            stats = {
                "total": result.total_scanned,
                "new": result.new_files,
                "total_estimate": total_estimate,
            }
            progress_callback(dir_str, stats)

        if dir_changed:
            # Directory modified — process its files
            dir_file_count = 0
            dir_total_size = 0
            seen_paths: set[str] = set()

            for entry in file_entries:
                if cancel_check and cancel_check():
                    result.cancelled = True
                    return

                try:
                    stat_info = entry.stat()
                    size_bytes = stat_info.st_size
                    mtime = datetime.fromtimestamp(stat_info.st_mtime).isoformat()
                    rel_path = str(Path(entry.path).relative_to(mount_path_obj))
                    seen_paths.add(rel_path)
                    bundle_root = get_catalog_bundle_root(rel_path)

                    existing = conn.execute(
                        "SELECT id, size_bytes, mtime FROM files "
                        "WHERE drive_id = ? AND path = ?",
                        (drive_id, rel_path),
                    ).fetchone()

                    if existing is None:
                        conn.execute(
                            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, catalog_bundle) "
                            "VALUES (?, ?, ?, ?, ?, ?)",
                            (drive_id, rel_path, entry.name, size_bytes, mtime, bundle_root),
                        )
                        result.new_files += 1
                    elif existing["size_bytes"] != size_bytes or existing["mtime"] != mtime:
                        conn.execute(
                            "UPDATE files SET size_bytes = ?, mtime = ?, "
                            "last_verified = datetime('now') WHERE id = ?",
                            (size_bytes, mtime, existing["id"]),
                        )
                        result.modified_files += 1
                    else:
                        result.unchanged_files += 1

                    result.total_scanned += 1
                    dir_file_count += 1
                    dir_total_size += size_bytes
                except PermissionError:
                    from drivecatalog.errors import log_error
                    log_error("DC-E004", {"drive_id": drive_id, "file": entry.name})
                    result.errors += 1
                except OSError as e:
                    logger.warning("Scan error in %s: %s", entry.path, e)
                    result.errors += 1

            # Delete files from DB that are no longer in this directory
            result.removed_files += _delete_files_in_dir(conn, drive_id, rel_dir, seen_paths)

            # Update folder stats
            _update_folder_stats(
                conn, drive_id, rel_dir, dir_file_count, dir_total_size, len(subdirs), dir_mtime
            )
            result.dirs_scanned += 1
        else:
            # Directory unchanged — skip file processing
            result.unchanged_files += stored["file_count"]
            result.total_scanned += stored["file_count"]
            result.dirs_skipped += 1

        # Always recurse into subdirectories (nested dirs may have changed)
        for subdir in sorted(subdirs, key=lambda e: e.name):
            if result.cancelled:
                return
            sub_rel = os.path.join(rel_dir, subdir.name) if rel_dir else subdir.name
            process_directory(Path(subdir.path), sub_rel)

    process_directory(mount_path_obj, "")

    if result.cancelled:
        conn.commit()
        return result

    # Detect deleted directories — remove their files and folder_stats
    for old_dir in list(existing_stats.keys()):
        if old_dir not in visited_dirs:
            if old_dir:
                deleted = conn.execute(
                    "SELECT COUNT(*) FROM files WHERE drive_id = ? AND path LIKE ?",
                    (drive_id, old_dir + "/%"),
                ).fetchone()[0]
                conn.execute(
                    "DELETE FROM files WHERE drive_id = ? AND path LIKE ?",
                    (drive_id, old_dir + "/%"),
                )
            else:
                # Root dir deleted — shouldn't happen for mounted drive
                deleted = 0
            conn.execute(
                "DELETE FROM folder_stats WHERE drive_id = ? AND path = ?",
                (drive_id, old_dir),
            )
            result.removed_files += deleted

    conn.commit()
    return result
