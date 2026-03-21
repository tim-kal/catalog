"""Migration planner and executor for DriveCatalog.

Generates, validates, queries, and executes migration plans that assign every
file on a source drive to either a copy_and_delete action (unique files that
need to be moved to a target drive) or a delete_only action (duplicated files
that already exist on other drives).

Five core functions:

- generate_migration_plan: create a plan from consolidation strategy
- validate_plan: check free space on all target drives
- get_plan_details: full plan metadata with per-status file counts
- get_plan_files: paginated file list with optional status filtering
- execute_migration_plan: run a validated plan (copy, verify, delete per file)
"""

from __future__ import annotations

import json
import shutil
from datetime import datetime
from pathlib import Path
from sqlite3 import Connection

from drivecatalog.api.operations import (
    OperationStatus,
    is_cancelled,
    update_operation,
    update_progress,
)
from drivecatalog.consolidation import get_consolidation_strategy
from drivecatalog.database import get_connection
from drivecatalog.hasher import compute_partial_hash


def generate_migration_plan(conn: Connection, source_drive_name: str) -> dict:
    """Generate a migration plan for consolidating a source drive.

    Calls get_consolidation_strategy to get optimal file assignments, then
    creates a persistent plan in SQLite with entries for every file on the
    source drive.

    Unique files get action='copy_and_delete' with a target drive assignment.
    Duplicated files (already backed up elsewhere) get action='delete_only'.

    Args:
        conn: SQLite connection with Row factory.
        source_drive_name: Name of the drive to migrate away from.

    Returns:
        Dict with plan_id, source_drive, status, file counts, byte totals,
        and is_feasible flag.

    Raises:
        ValueError: If source_drive_name is not found in the database.
    """
    # 1. Get the consolidation strategy (re-raises ValueError if drive not found)
    strategy = get_consolidation_strategy(conn, source_drive_name)

    # 2. Look up the source drive id
    drive_row = conn.execute(
        "SELECT id FROM drives WHERE name = ?", (source_drive_name,)
    ).fetchone()
    source_drive_id = drive_row["id"]

    # 3. Get ALL files on the source drive
    all_files = conn.execute(
        "SELECT id, path, size_bytes, partial_hash FROM files WHERE drive_id = ?",
        (source_drive_id,),
    ).fetchall()

    # 4. Build a set of unique file paths from the strategy's assignments
    #    These are files that need copy_and_delete
    unique_paths: dict[str, dict] = {}
    for assignment in strategy["assignments"]:
        target_drive = assignment["target_drive"]
        for file_info in assignment["files"]:
            unique_paths[file_info["path"]] = {
                "target_drive_name": target_drive,
                "target_path": file_info["path"],  # same relative path
            }

    # Also include unplaceable files -- they are unique but have no target
    unplaceable_paths = {f["path"] for f in strategy.get("unplaceable", [])}

    # 5. Insert the plan row
    cursor = conn.execute(
        """INSERT INTO migration_plans
           (source_drive_id, source_drive_name, status)
           VALUES (?, ?, 'draft')""",
        (source_drive_id, source_drive_name),
    )
    plan_id = cursor.lastrowid

    # 6. Insert migration_files for every file on the source drive
    files_to_copy = 0
    files_to_delete = 0
    total_bytes_to_transfer = 0
    total_files = 0

    for file_row in all_files:
        total_files += 1
        file_path = file_row["path"]

        if file_path in unique_paths:
            # Unique file: needs to be copied to target
            target_info = unique_paths[file_path]
            target_drive_name = target_info["target_drive_name"]
            target_path = target_info["target_path"]

            # Look up target_drive_id
            target_row = conn.execute(
                "SELECT id FROM drives WHERE name = ?", (target_drive_name,)
            ).fetchone()
            target_drive_id = target_row["id"] if target_row else None

            conn.execute(
                """INSERT INTO migration_files
                   (plan_id, source_file_id, source_path, source_size_bytes,
                    source_partial_hash, target_drive_id, target_drive_name,
                    target_path, action)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'copy_and_delete')""",
                (
                    plan_id,
                    file_row["id"],
                    file_path,
                    file_row["size_bytes"],
                    file_row["partial_hash"],
                    target_drive_id,
                    target_drive_name,
                    target_path,
                ),
            )
            files_to_copy += 1
            total_bytes_to_transfer += file_row["size_bytes"]

        elif file_path in unplaceable_paths:
            # Unique but unplaceable -- still copy_and_delete but no target
            conn.execute(
                """INSERT INTO migration_files
                   (plan_id, source_file_id, source_path, source_size_bytes,
                    source_partial_hash, target_drive_id, target_drive_name,
                    target_path, action)
                   VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, 'copy_and_delete')""",
                (
                    plan_id,
                    file_row["id"],
                    file_path,
                    file_row["size_bytes"],
                    file_row["partial_hash"],
                ),
            )
            files_to_copy += 1
            total_bytes_to_transfer += file_row["size_bytes"]

        else:
            # Duplicated file: already exists on other drives, just delete
            conn.execute(
                """INSERT INTO migration_files
                   (plan_id, source_file_id, source_path, source_size_bytes,
                    source_partial_hash, target_drive_id, target_drive_name,
                    target_path, action)
                   VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, 'delete_only')""",
                (
                    plan_id,
                    file_row["id"],
                    file_path,
                    file_row["size_bytes"],
                    file_row["partial_hash"],
                ),
            )
            files_to_delete += 1

    # 7. Update the plan row with final counts
    conn.execute(
        """UPDATE migration_plans
           SET total_files = ?, files_to_copy = ?, files_to_delete = ?,
               total_bytes_to_transfer = ?
           WHERE id = ?""",
        (total_files, files_to_copy, files_to_delete, total_bytes_to_transfer, plan_id),
    )

    # 8. Commit
    conn.commit()

    # 9. Return summary
    return {
        "plan_id": plan_id,
        "source_drive": source_drive_name,
        "status": "draft",
        "total_files": total_files,
        "files_to_copy": files_to_copy,
        "files_to_delete": files_to_delete,
        "total_bytes_to_transfer": total_bytes_to_transfer,
        "is_feasible": strategy["is_feasible"],
    }


def validate_plan(conn: Connection, plan_id: int) -> dict:
    """Validate a migration plan by checking free space on all target drives.

    Only draft plans can be validated. Checks that each target drive has
    sufficient free space for the bytes assigned to it.

    Args:
        conn: SQLite connection with Row factory.
        plan_id: ID of the plan to validate.

    Returns:
        Dict with plan_id, status, valid flag, and per-target space breakdown.

    Raises:
        ValueError: If plan not found or status is not 'draft'.
    """
    # 1. Load the plan
    plan_row = conn.execute(
        "SELECT id, status FROM migration_plans WHERE id = ?", (plan_id,)
    ).fetchone()
    if not plan_row:
        raise ValueError(f"Migration plan not found: {plan_id}")
    if plan_row["status"] != "draft":
        raise ValueError(
            f"Plan {plan_id} has status '{plan_row['status']}', must be 'draft' to validate"
        )

    # 2. Check space per target drive
    target_usage = conn.execute(
        """SELECT target_drive_id, target_drive_name,
                  SUM(source_size_bytes) as bytes_needed
           FROM migration_files
           WHERE plan_id = ? AND action = 'copy_and_delete' AND target_drive_id IS NOT NULL
           GROUP BY target_drive_id""",
        (plan_id,),
    ).fetchall()

    target_space = []
    all_sufficient = True

    for row in target_usage:
        drive_info = conn.execute(
            "SELECT total_bytes, used_bytes FROM drives WHERE id = ?",
            (row["target_drive_id"],),
        ).fetchone()

        if drive_info and drive_info["total_bytes"] is not None and drive_info["used_bytes"] is not None:
            free_bytes = drive_info["total_bytes"] - drive_info["used_bytes"]
        else:
            free_bytes = 0

        sufficient = row["bytes_needed"] <= free_bytes
        if not sufficient:
            all_sufficient = False

        target_space.append({
            "drive_name": row["target_drive_name"],
            "bytes_needed": row["bytes_needed"],
            "bytes_available": free_bytes,
            "sufficient": sufficient,
        })

    # 3. Update status if valid
    if all_sufficient:
        conn.execute(
            "UPDATE migration_plans SET status = 'validated' WHERE id = ?",
            (plan_id,),
        )
        conn.commit()
        status = "validated"
    else:
        status = "draft"

    # 4. Return result
    return {
        "plan_id": plan_id,
        "status": status,
        "valid": all_sufficient,
        "target_space": target_space,
    }


def get_plan_details(conn: Connection, plan_id: int) -> dict | None:
    """Get full details of a migration plan including per-status file counts.

    Args:
        conn: SQLite connection with Row factory.
        plan_id: ID of the plan to query.

    Returns:
        Dict with all plan metadata and file_status_counts breakdown,
        or None if plan not found.
    """
    # 1. Load the plan
    plan_row = conn.execute(
        "SELECT * FROM migration_plans WHERE id = ?", (plan_id,)
    ).fetchone()
    if not plan_row:
        return None

    # 2. Get per-status file counts
    status_rows = conn.execute(
        """SELECT status, COUNT(*) as count, SUM(source_size_bytes) as bytes
           FROM migration_files WHERE plan_id = ?
           GROUP BY status""",
        (plan_id,),
    ).fetchall()

    file_status_counts = {}
    for row in status_rows:
        file_status_counts[row["status"]] = {
            "count": row["count"],
            "bytes": row["bytes"] or 0,
        }

    # 3. Parse errors JSON
    errors_raw = plan_row["errors"]
    if errors_raw:
        try:
            errors = json.loads(errors_raw)
        except (json.JSONDecodeError, TypeError):
            errors = []
    else:
        errors = []

    # 4. Return full details
    return {
        "plan_id": plan_row["id"],
        "source_drive_name": plan_row["source_drive_name"],
        "status": plan_row["status"],
        "total_files": plan_row["total_files"],
        "files_to_copy": plan_row["files_to_copy"],
        "files_to_delete": plan_row["files_to_delete"],
        "total_bytes_to_transfer": plan_row["total_bytes_to_transfer"],
        "files_completed": plan_row["files_completed"],
        "bytes_transferred": plan_row["bytes_transferred"],
        "files_failed": plan_row["files_failed"],
        "errors": errors,
        "operation_id": plan_row["operation_id"],
        "created_at": plan_row["created_at"],
        "started_at": plan_row["started_at"],
        "completed_at": plan_row["completed_at"],
        "file_status_counts": file_status_counts,
    }


def get_plan_files(
    conn: Connection,
    plan_id: int,
    status_filter: str | None = None,
    limit: int = 100,
    offset: int = 0,
) -> dict:
    """Get paginated list of files in a migration plan.

    Args:
        conn: SQLite connection with Row factory.
        plan_id: ID of the plan to query.
        status_filter: Optional status to filter by (e.g., 'pending', 'failed').
        limit: Maximum number of files to return.
        offset: Number of files to skip.

    Returns:
        Dict with plan_id, files list, and total count.

    Raises:
        ValueError: If plan not found.
    """
    # 1. Verify plan exists
    plan_row = conn.execute(
        "SELECT id FROM migration_plans WHERE id = ?", (plan_id,)
    ).fetchone()
    if not plan_row:
        raise ValueError(f"Migration plan not found: {plan_id}")

    # 2. Build query with optional status filter
    if status_filter:
        count_row = conn.execute(
            "SELECT COUNT(*) as total FROM migration_files WHERE plan_id = ? AND status = ?",
            (plan_id, status_filter),
        ).fetchone()
        total = count_row["total"]

        file_rows = conn.execute(
            """SELECT id, source_path, source_size_bytes, target_drive_name,
                      target_path, action, status, error
               FROM migration_files
               WHERE plan_id = ? AND status = ?
               ORDER BY id
               LIMIT ? OFFSET ?""",
            (plan_id, status_filter, limit, offset),
        ).fetchall()
    else:
        count_row = conn.execute(
            "SELECT COUNT(*) as total FROM migration_files WHERE plan_id = ?",
            (plan_id,),
        ).fetchone()
        total = count_row["total"]

        file_rows = conn.execute(
            """SELECT id, source_path, source_size_bytes, target_drive_name,
                      target_path, action, status, error
               FROM migration_files
               WHERE plan_id = ?
               ORDER BY id
               LIMIT ? OFFSET ?""",
            (plan_id, limit, offset),
        ).fetchall()

    # 3. Build file list
    files = [
        {
            "id": row["id"],
            "source_path": row["source_path"],
            "source_size_bytes": row["source_size_bytes"],
            "target_drive_name": row["target_drive_name"],
            "target_path": row["target_path"],
            "action": row["action"],
            "status": row["status"],
            "error": row["error"],
        }
        for row in file_rows
    ]

    return {
        "plan_id": plan_id,
        "files": files,
        "total": total,
    }


def execute_migration_plan(plan_id: int, operation_id: str) -> dict:
    """Execute a validated migration plan as a background-compatible operation.

    Processes each file in the plan: copy to target, verify hash, delete source.
    Supports cancellation via the in-memory operation tracker, retries failed
    copies once, and persists all progress to SQLite after each file.

    Designed to run synchronously in a background thread (same pattern as
    _run_hash and _run_scan in drives.py). Opens its own database connection.

    Args:
        plan_id: ID of the migration plan to execute (must have status='validated').
        operation_id: ID linking to the in-memory operation tracker for
            progress updates and cancellation checks.

    Returns:
        Summary dict with plan_id, status, files_moved, bytes_transferred,
        files_failed, and errors list.

    Raises:
        ValueError: If plan not found or status is not 'validated'.
    """
    conn = get_connection()
    try:
        return _execute_migration(conn, plan_id, operation_id)
    except Exception as e:
        # Unexpected error: mark plan failed and update operation
        try:
            conn.execute(
                """UPDATE migration_plans
                   SET status = 'failed', errors = ?, completed_at = datetime('now')
                   WHERE id = ?""",
                (json.dumps([str(e)]), plan_id),
            )
            conn.commit()
        except Exception:
            pass  # Best effort DB update
        update_operation(
            operation_id,
            status=OperationStatus.FAILED,
            error=str(e),
            completed_at=datetime.now(),
        )
        raise
    finally:
        conn.close()


def _execute_migration(conn: Connection, plan_id: int, operation_id: str) -> dict:
    """Internal migration executor. Separated for clean error handling.

    Args:
        conn: Fresh SQLite connection (owned by caller).
        plan_id: ID of the migration plan.
        operation_id: In-memory operation tracker ID.

    Returns:
        Summary dict.
    """
    # 1. Load and validate plan
    plan_row = conn.execute(
        "SELECT * FROM migration_plans WHERE id = ?", (plan_id,)
    ).fetchone()
    if not plan_row:
        raise ValueError(f"Migration plan not found: {plan_id}")
    if plan_row["status"] != "validated":
        raise ValueError(
            f"Plan {plan_id} has status '{plan_row['status']}', must be 'validated' to execute"
        )

    # Mark plan as executing
    conn.execute(
        """UPDATE migration_plans
           SET status = 'executing', started_at = datetime('now'), operation_id = ?
           WHERE id = ?""",
        (operation_id, plan_id),
    )
    conn.commit()
    update_operation(
        operation_id, status=OperationStatus.RUNNING, started_at=datetime.now()
    )

    # 2. Load source and target drive mount paths
    source_drive_row = conn.execute(
        "SELECT mount_path FROM drives WHERE id = ?",
        (plan_row["source_drive_id"],),
    ).fetchone()
    if not source_drive_row or not source_drive_row["mount_path"]:
        raise ValueError("Source drive is not mounted (mount_path is NULL)")
    source_mount = Path(source_drive_row["mount_path"])
    if not source_mount.exists():
        raise ValueError(f"Source drive mount path does not exist: {source_mount}")

    # Build target drive mount path lookup
    target_drive_rows = conn.execute(
        """SELECT DISTINCT target_drive_id FROM migration_files
           WHERE plan_id = ? AND target_drive_id IS NOT NULL""",
        (plan_id,),
    ).fetchall()

    target_mounts: dict[int, Path] = {}
    for row in target_drive_rows:
        drive_row = conn.execute(
            "SELECT mount_path FROM drives WHERE id = ?",
            (row["target_drive_id"],),
        ).fetchone()
        if not drive_row or not drive_row["mount_path"]:
            raise ValueError(
                f"Target drive {row['target_drive_id']} is not mounted (mount_path is NULL)"
            )
        mount = Path(drive_row["mount_path"])
        if not mount.exists():
            raise ValueError(
                f"Target drive mount path does not exist: {mount}"
            )
        target_mounts[row["target_drive_id"]] = mount

    # 3. Load all pending files
    pending_files = conn.execute(
        "SELECT * FROM migration_files WHERE plan_id = ? AND status = 'pending' ORDER BY id",
        (plan_id,),
    ).fetchall()
    total_files = len(pending_files)

    # 4. Process files in a loop
    files_completed = 0
    bytes_transferred = 0
    errors: list[str] = []

    for file_row in pending_files:
        # 4a. Check cancellation
        if is_cancelled(operation_id):
            conn.execute(
                """UPDATE migration_plans
                   SET status = 'cancelled', completed_at = datetime('now')
                   WHERE id = ?""",
                (plan_id,),
            )
            conn.commit()
            update_operation(
                operation_id,
                status=OperationStatus.CANCELLED,
                completed_at=datetime.now(),
            )
            return {
                "plan_id": plan_id,
                "status": "cancelled",
                "files_moved": files_completed,
                "bytes_transferred": bytes_transferred,
                "files_failed": len(errors),
                "errors": errors,
            }

        source_full_path = source_mount / file_row["source_path"]

        if file_row["action"] == "delete_only":
            # 4b. Delete-only: file is duplicated elsewhere, just delete source
            conn.execute(
                "UPDATE migration_files SET status = 'verified' WHERE id = ?",
                (file_row["id"],),
            )
            conn.commit()
            try:
                source_full_path.unlink()
                conn.execute(
                    """UPDATE migration_files
                       SET status = 'deleted', completed_at = datetime('now')
                       WHERE id = ?""",
                    (file_row["id"],),
                )
                conn.commit()
            except OSError as e:
                conn.execute(
                    "UPDATE migration_files SET status = 'failed', error = ? WHERE id = ?",
                    (str(e), file_row["id"]),
                )
                conn.commit()
                errors.append(f"{file_row['source_path']}: {e}")
            files_completed += 1

        elif file_row["action"] == "copy_and_delete":
            # 4c. Copy and delete: copy to target, verify hash, delete source
            target_drive_id = file_row["target_drive_id"]
            if target_drive_id is None or target_drive_id not in target_mounts:
                # Unplaceable file -- no target assigned
                conn.execute(
                    "UPDATE migration_files SET status = 'failed', error = ? WHERE id = ?",
                    ("No target drive assigned", file_row["id"]),
                )
                conn.commit()
                errors.append(f"{file_row['source_path']}: no target drive assigned")
                files_completed += 1
                _update_plan_progress(
                    conn, plan_id, operation_id, files_completed, total_files,
                    bytes_transferred, errors,
                )
                continue

            target_mount = target_mounts[target_drive_id]
            target_full_path = target_mount / file_row["target_path"]

            # Mark as copying
            conn.execute(
                """UPDATE migration_files
                   SET status = 'copying', started_at = datetime('now')
                   WHERE id = ?""",
                (file_row["id"],),
            )
            conn.commit()

            # Copy with retry (max 2 attempts)
            copy_succeeded = False
            last_error: Exception | None = None

            for attempt in range(2):
                try:
                    target_full_path.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(str(source_full_path), str(target_full_path))
                    copy_succeeded = True
                    break
                except OSError as e:
                    last_error = e
                    if attempt == 0:
                        continue  # Retry once

            if copy_succeeded:
                # Verify hash
                conn.execute(
                    "UPDATE migration_files SET status = 'verifying' WHERE id = ?",
                    (file_row["id"],),
                )
                conn.commit()

                dest_hash = compute_partial_hash(
                    target_full_path, file_row["source_size_bytes"]
                )
                source_hash = file_row["source_partial_hash"]

                # If source has no stored hash, compute it fresh
                if source_hash is None:
                    source_hash = compute_partial_hash(
                        source_full_path, file_row["source_size_bytes"]
                    )

                if dest_hash is not None and source_hash is not None and dest_hash == source_hash:
                    # Hash match: mark verified, delete source
                    conn.execute(
                        "UPDATE migration_files SET status = 'verified' WHERE id = ?",
                        (file_row["id"],),
                    )
                    conn.commit()

                    try:
                        source_full_path.unlink()
                        conn.execute(
                            """UPDATE migration_files
                               SET status = 'deleted', completed_at = datetime('now')
                               WHERE id = ?""",
                            (file_row["id"],),
                        )
                        conn.commit()
                        bytes_transferred += file_row["source_size_bytes"]
                    except OSError as e:
                        # Source delete failed after verified copy -- mark failed
                        conn.execute(
                            "UPDATE migration_files SET status = 'failed', error = ? WHERE id = ?",
                            (f"Source delete failed: {e}", file_row["id"]),
                        )
                        conn.commit()
                        errors.append(f"{file_row['source_path']}: source delete failed: {e}")
                else:
                    # Hash mismatch: remove bad copy, mark failed
                    target_full_path.unlink(missing_ok=True)
                    conn.execute(
                        "UPDATE migration_files SET status = 'failed', error = ? WHERE id = ?",
                        ("Hash mismatch after copy", file_row["id"]),
                    )
                    conn.commit()
                    errors.append(f"{file_row['source_path']}: hash mismatch")
            else:
                # Copy failed after retries
                error_msg = str(last_error) if last_error else "Unknown copy error"
                conn.execute(
                    "UPDATE migration_files SET status = 'failed', error = ? WHERE id = ?",
                    (error_msg, file_row["id"]),
                )
                conn.commit()
                errors.append(f"{file_row['source_path']}: {error_msg}")

            files_completed += 1

        # 4d. Update progress after every file
        _update_plan_progress(
            conn, plan_id, operation_id, files_completed, total_files,
            bytes_transferred, errors,
        )

    # 5. Finalize
    status_counts = conn.execute(
        "SELECT status, COUNT(*) as cnt FROM migration_files WHERE plan_id = ? GROUP BY status",
        (plan_id,),
    ).fetchall()

    # Determine final status: 'completed' if no pending/copying/verifying remain
    active_statuses = {"pending", "copying", "verifying"}
    has_active = any(row["status"] in active_statuses for row in status_counts)
    final_status = "executing" if has_active else "completed"

    failed_count = sum(
        row["cnt"] for row in status_counts if row["status"] == "failed"
    )

    summary = {
        "plan_id": plan_id,
        "status": final_status,
        "files_moved": files_completed,
        "bytes_transferred": bytes_transferred,
        "files_failed": failed_count,
        "errors": errors,
    }

    conn.execute(
        """UPDATE migration_plans
           SET status = ?, completed_at = datetime('now'), errors = ?,
               files_completed = ?, bytes_transferred = ?, files_failed = ?
           WHERE id = ?""",
        (
            final_status,
            json.dumps(errors),
            files_completed,
            bytes_transferred,
            failed_count,
            plan_id,
        ),
    )
    conn.commit()

    update_operation(
        operation_id,
        status=OperationStatus.COMPLETED,
        progress_percent=100.0,
        completed_at=datetime.now(),
        result=summary,
    )

    return summary


def _update_plan_progress(
    conn: Connection,
    plan_id: int,
    operation_id: str,
    files_completed: int,
    total_files: int,
    bytes_transferred: int,
    errors: list[str],
) -> None:
    """Update progress in both SQLite and the in-memory operation tracker."""
    failed_count = conn.execute(
        "SELECT COUNT(*) as cnt FROM migration_files WHERE plan_id = ? AND status = 'failed'",
        (plan_id,),
    ).fetchone()["cnt"]

    conn.execute(
        """UPDATE migration_plans
           SET files_completed = ?, bytes_transferred = ?, files_failed = ?
           WHERE id = ?""",
        (files_completed, bytes_transferred, failed_count, plan_id),
    )
    conn.commit()
    update_progress(operation_id, files_completed, total_files)
