"""Status endpoint for DriveCatalog API."""

from fastapi import APIRouter, HTTPException, Query

from drivecatalog.database import get_connection, get_db_path

router = APIRouter(tags=["status"])


@router.get("/status")
async def get_status() -> dict:
    """Get database status and statistics.

    Returns database path, drive count, file count, and hash coverage.
    """
    db_path = get_db_path()

    if not db_path.exists():
        return {
            "db_path": str(db_path),
            "initialized": False,
            "drives_count": 0,
            "files_count": 0,
            "hashed_count": 0,
            "hash_coverage_percent": 0.0,
        }

    conn = get_connection()
    try:
        drives_count = conn.execute("SELECT COUNT(*) FROM drives").fetchone()[0]
        files_count = conn.execute("SELECT COUNT(*) FROM files").fetchone()[0]
        hashed_count = conn.execute(
            "SELECT COUNT(*) FROM files WHERE partial_hash IS NOT NULL"
        ).fetchone()[0]

        hash_coverage_percent = (
            (hashed_count / files_count) * 100 if files_count > 0 else 0.0
        )

        return {
            "db_path": str(db_path),
            "initialized": True,
            "drives_count": drives_count,
            "files_count": files_count,
            "hashed_count": hashed_count,
            "hash_coverage_percent": round(hash_coverage_percent, 2),
        }
    finally:
        conn.close()


@router.post("/reset-all")
async def reset_all_data(
    confirm: bool = Query(False, description="Must be true to confirm reset"),
) -> dict:
    """Delete ALL data: drives, files, hashes, operations, everything.

    Cancels all running operations, then signals that the app should restart.
    The frontend handles the actual restart — on next launch, init_db() will
    recreate a fresh database.

    This is irreversible.
    """
    if not confirm:
        raise HTTPException(400, "Reset requires confirmation. Add ?confirm=true.")

    import os

    from drivecatalog.api.operations import OperationStatus, _operations, cancel_operation

    # 1. Cancel all running operations
    for op_id, op in list(_operations.items()):
        if op.status in (OperationStatus.PENDING, OperationStatus.RUNNING):
            cancel_operation(op_id)

    # 2. Checkpoint WAL to flush all data into main DB file
    conn = get_connection()
    try:
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finally:
        conn.close()

    # 3. Delete database files
    db_path = get_db_path()
    for suffix in ("", "-wal", "-shm"):
        p = str(db_path) + suffix
        if os.path.exists(p):
            os.remove(p)

    # 4. Return — frontend will restart the app, init_db() recreates fresh DB
    return {"status": "reset_complete", "restart_required": True}
