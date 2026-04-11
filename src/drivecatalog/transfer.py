"""Batch transfer engine for DriveCatalog.

Enables transferring many files between drives in one operation,
with per-file tracking, resume on interrupt, and overall progress.
"""

import logging
import sqlite3
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from drivecatalog.copier import copy_file_verified

logger = logging.getLogger(__name__)


@dataclass
class TransferManifest:
    """Describes a batch transfer operation."""

    transfer_id: str  # UUID
    source_drive: str  # drive name
    dest_drive: str  # drive name
    files: list[dict] = field(default_factory=list)  # [{path, size_bytes, source_file_id}, ...]
    total_bytes: int = 0
    total_files: int = 0


@dataclass
class TransferResult:
    """Result of executing a batch transfer."""

    transfer_id: str
    files_completed: int = 0
    files_failed: int = 0
    files_skipped: int = 0
    bytes_copied: int = 0
    failures: list[dict] = field(default_factory=list)  # [{path, error}, ...]


def create_transfer(
    conn: sqlite3.Connection,
    source_drive: str,
    dest_drive: str,
    paths: list[str],
    dest_folder: str | None = None,
) -> TransferManifest:
    """Create a batch transfer manifest and planned_actions rows.

    Args:
        conn: Database connection.
        source_drive: Name of the source drive.
        dest_drive: Name of the destination drive.
        paths: List of relative paths (files or folders to expand).
        dest_folder: Optional destination folder prefix.

    Returns:
        TransferManifest with all files to transfer.
    """
    transfer_id = str(uuid.uuid4())

    # Look up source drive info
    src_drive_row = conn.execute(
        "SELECT id, mount_path FROM drives WHERE name = ?", (source_drive,)
    ).fetchone()
    if not src_drive_row:
        raise ValueError(f"Source drive '{source_drive}' not found")

    src_drive_id = src_drive_row["id"]
    src_mount_path = src_drive_row["mount_path"]

    # Expand paths: if a path is a directory, recursively list all files
    expanded_paths: list[str] = []
    for p in paths:
        full_path = Path(src_mount_path) / p if src_mount_path else None
        if full_path and full_path.is_dir():
            # Expand directory to all files within
            for child in sorted(full_path.rglob("*")):
                if child.is_file():
                    rel = str(child.relative_to(src_mount_path))
                    expanded_paths.append(rel)
        else:
            expanded_paths.append(p)

    # Query files table for matching entries
    manifest_files: list[dict] = []
    for rel_path in expanded_paths:
        row = conn.execute(
            "SELECT id, path, size_bytes FROM files WHERE drive_id = ? AND path = ?",
            (src_drive_id, rel_path),
        ).fetchone()
        if row:
            manifest_files.append({
                "path": row["path"],
                "size_bytes": row["size_bytes"],
                "source_file_id": row["id"],
            })

    total_bytes = sum(f["size_bytes"] for f in manifest_files)
    manifest = TransferManifest(
        transfer_id=transfer_id,
        source_drive=source_drive,
        dest_drive=dest_drive,
        files=manifest_files,
        total_bytes=total_bytes,
        total_files=len(manifest_files),
    )

    # Insert one planned_actions row per file
    for f in manifest_files:
        target_path = f["path"]
        if dest_folder:
            target_path = f"{dest_folder}/{f['path']}"

        conn.execute(
            """
            INSERT INTO planned_actions
                (action_type, source_drive, source_path, target_drive,
                 target_path, status, estimated_bytes, transfer_id)
            VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)
            """,
            (
                "copy",
                source_drive,
                f["path"],
                dest_drive,
                target_path,
                f["size_bytes"],
                transfer_id,
            ),
        )
    conn.commit()

    return manifest


def execute_transfer(
    conn: sqlite3.Connection,
    transfer_id: str,
    progress_callback=None,
    cancel_check=None,
) -> TransferResult:
    """Execute all pending/failed actions for a transfer.

    Files are processed in directory-batched order (sorted by parent dir
    then filename) for HDD locality.

    Args:
        conn: Database connection.
        transfer_id: UUID of the transfer to execute.
        progress_callback: Optional callback(files_done, files_total,
            bytes_done, bytes_total, current_file).
        cancel_check: Optional callable returning True if cancelled.

    Returns:
        TransferResult with counts and any failures.
    """
    # Get source and dest mount paths
    rows = conn.execute(
        """
        SELECT DISTINCT source_drive, target_drive
        FROM planned_actions WHERE transfer_id = ?
        """,
        (transfer_id,),
    ).fetchall()
    if not rows:
        return TransferResult(transfer_id=transfer_id)

    source_drive_name = rows[0]["source_drive"]
    dest_drive_name = rows[0]["target_drive"]

    src_drive = conn.execute(
        "SELECT id, mount_path FROM drives WHERE name = ?", (source_drive_name,)
    ).fetchone()
    dst_drive = conn.execute(
        "SELECT id, mount_path FROM drives WHERE name = ?", (dest_drive_name,)
    ).fetchone()

    if not src_drive or not dst_drive:
        return TransferResult(transfer_id=transfer_id)

    src_mount = src_drive["mount_path"]
    dst_mount = dst_drive["mount_path"]
    dst_drive_id = dst_drive["id"]

    # Query pending/failed actions, directory-batched ordering
    actions = conn.execute(
        """
        SELECT id, source_path, target_path, estimated_bytes
        FROM planned_actions
        WHERE transfer_id = ? AND status IN ('pending', 'failed')
        ORDER BY
            substr(source_path, 1, length(source_path) - length(replace(source_path, '/', ''))
                   - length(substr(source_path, length(source_path) - instr(replace(source_path, '/', char(0)), char(0)) + 2))),
            source_path
        """,
        (transfer_id,),
    ).fetchall()

    # Get total counts for progress
    total_row = conn.execute(
        "SELECT COUNT(*) as total FROM planned_actions WHERE transfer_id = ?",
        (transfer_id,),
    ).fetchone()
    files_total = total_row["total"]

    completed_row = conn.execute(
        """SELECT COUNT(*) as done, COALESCE(SUM(estimated_bytes), 0) as bytes_done
           FROM planned_actions
           WHERE transfer_id = ? AND status = 'completed'""",
        (transfer_id,),
    ).fetchone()
    files_done = completed_row["done"]
    bytes_done = completed_row["bytes_done"]

    total_bytes_row = conn.execute(
        "SELECT COALESCE(SUM(estimated_bytes), 0) as total FROM planned_actions WHERE transfer_id = ?",
        (transfer_id,),
    ).fetchone()
    bytes_total = total_bytes_row["total"]

    result = TransferResult(
        transfer_id=transfer_id,
        files_completed=files_done,
        bytes_copied=bytes_done,
    )

    # Create dest directories upfront
    dest_dirs: set[str] = set()
    for action in actions:
        target = Path(dst_mount) / action["target_path"]
        dest_dirs.add(str(target.parent))
    for d in sorted(dest_dirs):
        Path(d).mkdir(parents=True, exist_ok=True)

    for action in actions:
        # Check cancellation
        if cancel_check and cancel_check():
            break

        action_id = action["id"]
        src_path = Path(src_mount) / action["source_path"]
        dst_path = Path(dst_mount) / action["target_path"]

        # Update status to in_progress
        conn.execute(
            "UPDATE planned_actions SET status = 'in_progress', started_at = datetime('now') WHERE id = ?",
            (action_id,),
        )
        conn.commit()

        # Copy with verification
        started_at = datetime.now()
        copy_result = copy_file_verified(src_path, dst_path)

        if copy_result.verified and not copy_result.error:
            # Success
            conn.execute(
                "UPDATE planned_actions SET status = 'completed', completed_at = datetime('now') WHERE id = ?",
                (action_id,),
            )

            # Log to copy_operations
            try:
                from drivecatalog.copier import log_copy_operation

                # Find source_file_id
                src_file = conn.execute(
                    "SELECT id FROM files WHERE drive_id = ? AND path = ?",
                    (src_drive["id"], action["source_path"]),
                ).fetchone()
                if src_file:
                    log_copy_operation(
                        conn,
                        src_file["id"],
                        dst_drive_id,
                        action["target_path"],
                        copy_result,
                        started_at,
                        datetime.now(),
                    )
            except Exception as e:
                logger.warning("Failed to log copy operation: %s", e)

            conn.commit()
            result.files_completed += 1
            result.bytes_copied += copy_result.bytes_copied
            files_done += 1
            bytes_done += action["estimated_bytes"]
        else:
            # Failure
            error_msg = copy_result.error or "Hash verification failed"
            conn.execute(
                "UPDATE planned_actions SET status = 'failed', error = ? WHERE id = ?",
                (error_msg, action_id),
            )
            conn.commit()
            result.files_failed += 1
            result.failures.append({
                "path": action["source_path"],
                "error": error_msg,
            })
            files_done += 1

        if progress_callback:
            progress_callback(
                files_done, files_total, bytes_done, bytes_total, action["source_path"]
            )

    return result


def resume_transfer(
    conn: sqlite3.Connection,
    transfer_id: str,
    progress_callback=None,
    cancel_check=None,
) -> TransferResult:
    """Resume a failed/interrupted transfer.

    Cleans up .dctmp files from previously failed/in-progress actions,
    then re-runs execute_transfer (which naturally skips completed actions).
    """
    # Get dest mount path for cleanup
    row = conn.execute(
        "SELECT DISTINCT target_drive FROM planned_actions WHERE transfer_id = ?",
        (transfer_id,),
    ).fetchone()
    if row:
        dst_drive = conn.execute(
            "SELECT mount_path FROM drives WHERE name = ?", (row["target_drive"],)
        ).fetchone()
        if dst_drive:
            dst_mount = dst_drive["mount_path"]
            # Clean up .dctmp files from failed/in-progress actions
            stale = conn.execute(
                """
                SELECT target_path FROM planned_actions
                WHERE transfer_id = ? AND status IN ('failed', 'in_progress')
                """,
                (transfer_id,),
            ).fetchall()
            for s in stale:
                tmp_path = Path(dst_mount) / (s["target_path"] + ".dctmp")
                if tmp_path.exists():
                    try:
                        tmp_path.unlink()
                    except OSError as e:
                        logger.warning("Failed to clean up %s: %s", tmp_path, e)

    # Reset in_progress back to pending so execute_transfer picks them up
    conn.execute(
        "UPDATE planned_actions SET status = 'pending' WHERE transfer_id = ? AND status = 'in_progress'",
        (transfer_id,),
    )
    # Reset failed back to pending for retry
    conn.execute(
        "UPDATE planned_actions SET status = 'pending', error = NULL WHERE transfer_id = ? AND status = 'failed'",
        (transfer_id,),
    )
    conn.commit()

    return execute_transfer(conn, transfer_id, progress_callback, cancel_check)


def get_transfer_status(conn: sqlite3.Connection, transfer_id: str) -> dict:
    """Get transfer progress and status.

    Returns:
        Dict with total/completed/failed/pending counts, total_bytes,
        bytes_copied, and list of failed files.
    """
    counts = conn.execute(
        """
        SELECT
            COUNT(*) as total,
            SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failed,
            SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) as pending,
            SUM(CASE WHEN status = 'in_progress' THEN 1 ELSE 0 END) as in_progress,
            SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END) as cancelled,
            COALESCE(SUM(estimated_bytes), 0) as total_bytes,
            COALESCE(SUM(CASE WHEN status = 'completed' THEN estimated_bytes ELSE 0 END), 0) as bytes_copied
        FROM planned_actions
        WHERE transfer_id = ?
        """,
        (transfer_id,),
    ).fetchone()

    failed_files = conn.execute(
        """
        SELECT source_path, error
        FROM planned_actions
        WHERE transfer_id = ? AND status = 'failed'
        """,
        (transfer_id,),
    ).fetchall()

    return {
        "transfer_id": transfer_id,
        "total": counts["total"],
        "completed": counts["completed"],
        "failed": counts["failed"],
        "pending": counts["pending"],
        "in_progress": counts["in_progress"],
        "cancelled": counts["cancelled"],
        "total_bytes": counts["total_bytes"],
        "bytes_copied": counts["bytes_copied"],
        "failed_files": [
            {"path": r["source_path"], "error": r["error"]} for r in failed_files
        ],
    }
