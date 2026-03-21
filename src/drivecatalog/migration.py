"""Migration planner for DriveCatalog.

Generates, validates, and queries migration plans that assign every file on a
source drive to either a copy_and_delete action (unique files that need to be
moved to a target drive) or a delete_only action (duplicated files that already
exist on other drives).

Four core functions:

- generate_migration_plan: create a plan from consolidation strategy
- validate_plan: check free space on all target drives
- get_plan_details: full plan metadata with per-status file counts
- get_plan_files: paginated file list with optional status filtering
"""

from __future__ import annotations

import json
from sqlite3 import Connection

from drivecatalog.consolidation import get_consolidation_strategy


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
