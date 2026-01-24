"""Drive management endpoints for DriveCatalog API."""

from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, HTTPException, Query

from drivecatalog.database import get_connection
from drivecatalog.drives import get_drive_info, validate_mount_path
from drivecatalog.scanner import scan_drive as scanner_scan_drive

from ..models.drive import (
    DriveCreateRequest,
    DriveListResponse,
    DriveResponse,
    DriveStatusResponse,
)
from ..operations import OperationStatus, create_operation, update_operation

router = APIRouter(prefix="/drives", tags=["drives"])


@router.get("", response_model=DriveListResponse)
async def list_drives() -> DriveListResponse:
    """List all registered drives with file counts."""
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT d.*, (SELECT COUNT(*) FROM files WHERE drive_id = d.id) as file_count
            FROM drives d ORDER BY d.name
            """
        ).fetchall()

        drives = [
            DriveResponse(
                id=row["id"],
                name=row["name"],
                uuid=row["uuid"],
                mount_path=row["mount_path"] or "",
                total_bytes=row["total_bytes"] or 0,
                last_scan=row["last_scan"],
                file_count=row["file_count"],
            )
            for row in rows
        ]

        return DriveListResponse(drives=drives, total=len(drives))
    finally:
        conn.close()


@router.post("", response_model=DriveResponse, status_code=201)
async def create_drive(request: DriveCreateRequest) -> DriveResponse:
    """Register a new drive for cataloging.

    The path must be a valid mount point under /Volumes/.
    """
    path_obj = Path(request.path)

    # Check if path exists first
    if not path_obj.exists():
        raise HTTPException(status_code=404, detail=f"Path '{request.path}' does not exist")

    # Validate mount path
    if not validate_mount_path(path_obj):
        raise HTTPException(
            status_code=400,
            detail=f"'{request.path}' is not a valid mount point. Must be under /Volumes/.",
        )

    # Get drive information
    drive_info = get_drive_info(path_obj)
    drive_name = request.name if request.name else drive_info["name"]

    conn = get_connection()
    try:
        # Check if already registered by UUID or mount_path
        existing = conn.execute(
            "SELECT name FROM drives WHERE uuid = ? OR mount_path = ?",
            (drive_info["uuid"], drive_info["mount_path"]),
        ).fetchone()

        if existing:
            raise HTTPException(
                status_code=400,
                detail=f"Drive already registered as '{existing['name']}'",
            )

        # Insert new drive
        cursor = conn.execute(
            """
            INSERT INTO drives (name, uuid, mount_path, total_bytes)
            VALUES (?, ?, ?, ?)
            """,
            (drive_name, drive_info["uuid"], drive_info["mount_path"], drive_info["total_bytes"]),
        )
        conn.commit()

        # Return the created drive
        drive_id = cursor.lastrowid
        return DriveResponse(
            id=drive_id,
            name=drive_name,
            uuid=drive_info["uuid"],
            mount_path=drive_info["mount_path"],
            total_bytes=drive_info["total_bytes"],
            last_scan=None,
            file_count=0,
        )
    finally:
        conn.close()


@router.delete("/{name}")
async def delete_drive(
    name: str,
    confirm: bool = Query(False, description="Must be true to confirm deletion"),
) -> dict:
    """Delete a drive registration and all associated file records.

    This is a destructive operation. Set confirm=true to proceed.
    """
    if not confirm:
        raise HTTPException(
            status_code=400,
            detail="Deletion requires confirmation. Add ?confirm=true to proceed.",
        )

    conn = get_connection()
    try:
        # Look up drive by name
        drive = conn.execute(
            "SELECT id, name FROM drives WHERE name = ?", (name,)
        ).fetchone()

        if not drive:
            raise HTTPException(status_code=404, detail=f"Drive '{name}' not found")

        drive_id = drive["id"]

        # Count files to be deleted (for response)
        file_count = conn.execute(
            "SELECT COUNT(*) FROM files WHERE drive_id = ?", (drive_id,)
        ).fetchone()[0]

        # Delete files first (foreign key), then drive
        # Note: CASCADE would handle this, but being explicit for clarity
        conn.execute("DELETE FROM files WHERE drive_id = ?", (drive_id,))
        conn.execute("DELETE FROM drives WHERE id = ?", (drive_id,))
        conn.commit()

        return {
            "status": "deleted",
            "name": name,
            "files_removed": file_count,
        }
    finally:
        conn.close()


@router.get("/{name}", response_model=DriveResponse)
async def get_drive(name: str) -> DriveResponse:
    """Get details for a single drive by name."""
    conn = get_connection()
    try:
        row = conn.execute(
            """
            SELECT d.*, (SELECT COUNT(*) FROM files WHERE drive_id = d.id) as file_count
            FROM drives d WHERE d.name = ?
            """,
            (name,),
        ).fetchone()

        if not row:
            raise HTTPException(status_code=404, detail=f"Drive '{name}' not found")

        return DriveResponse(
            id=row["id"],
            name=row["name"],
            uuid=row["uuid"],
            mount_path=row["mount_path"] or "",
            total_bytes=row["total_bytes"] or 0,
            last_scan=row["last_scan"],
            file_count=row["file_count"],
        )
    finally:
        conn.close()


@router.get("/{name}/status", response_model=DriveStatusResponse)
async def get_drive_status(name: str) -> DriveStatusResponse:
    """Get status and hash coverage for a drive.

    Returns mounted status, file counts, and hash coverage percentage.
    """
    conn = get_connection()
    try:
        # Get drive info
        drive = conn.execute(
            "SELECT id, name, mount_path, last_scan FROM drives WHERE name = ?", (name,)
        ).fetchone()

        if not drive:
            raise HTTPException(status_code=404, detail=f"Drive '{name}' not found")

        drive_id = drive["id"]
        mount_path = drive["mount_path"]

        # Check if drive is mounted (mount_path exists)
        mounted = Path(mount_path).exists() if mount_path else False

        # Get file statistics
        stats = conn.execute(
            """
            SELECT
                COUNT(*) as file_count,
                SUM(CASE WHEN partial_hash IS NOT NULL THEN 1 ELSE 0 END) as hashed_count,
                SUM(CASE WHEN is_media = 1 THEN 1 ELSE 0 END) as media_count
            FROM files WHERE drive_id = ?
            """,
            (drive_id,),
        ).fetchone()

        file_count = stats["file_count"] or 0
        hashed_count = stats["hashed_count"] or 0
        media_count = stats["media_count"] or 0

        # Calculate hash coverage percentage
        if file_count > 0:
            hash_coverage_percent = round((hashed_count / file_count) * 100, 2)
        else:
            hash_coverage_percent = 0.0

        return DriveStatusResponse(
            id=drive_id,
            name=drive["name"],
            mounted=mounted,
            file_count=file_count,
            hashed_count=hashed_count,
            hash_coverage_percent=hash_coverage_percent,
            last_scan=drive["last_scan"],
            media_count=media_count,
        )
    finally:
        conn.close()


def _run_scan(operation_id: str, drive_id: int, mount_path: str) -> None:
    """Run scan in background thread.

    Args:
        operation_id: ID of the operation to track progress.
        drive_id: Database ID of the drive.
        mount_path: Path to the mounted drive.
    """
    update_operation(operation_id, status=OperationStatus.RUNNING)

    try:
        conn = get_connection()
        try:
            result = scanner_scan_drive(drive_id, mount_path, conn)

            # Update last_scan timestamp
            conn.execute(
                "UPDATE drives SET last_scan = datetime('now') WHERE id = ?",
                (drive_id,),
            )
            conn.commit()

            update_operation(
                operation_id,
                status=OperationStatus.COMPLETED,
                result={
                    "new_files": result.new_files,
                    "modified_files": result.modified_files,
                    "unchanged_files": result.unchanged_files,
                    "errors": result.errors,
                    "total_scanned": result.total_scanned,
                },
                completed_at=datetime.now(),
            )
        finally:
            conn.close()
    except Exception as e:
        update_operation(
            operation_id,
            status=OperationStatus.FAILED,
            error=str(e),
            completed_at=datetime.now(),
        )


@router.post("/{name}/scan")
async def trigger_scan(name: str, background_tasks: BackgroundTasks) -> dict:
    """Trigger a scan of the drive as a background task.

    Returns immediately with an operation_id that can be used to poll for status.
    """
    conn = get_connection()
    try:
        # Look up drive by name
        drive = conn.execute(
            "SELECT id, name, mount_path FROM drives WHERE name = ?", (name,)
        ).fetchone()

        if not drive:
            raise HTTPException(status_code=404, detail=f"Drive '{name}' not found")

        mount_path = drive["mount_path"]
        if not mount_path or not Path(mount_path).exists():
            raise HTTPException(
                status_code=400, detail=f"Drive '{name}' is not currently mounted"
            )

        # Create operation and start background task
        op = create_operation("scan", name)
        background_tasks.add_task(_run_scan, op.id, drive["id"], mount_path)

        return {
            "operation_id": op.id,
            "status": "started",
            "poll_url": f"/operations/{op.id}",
        }
    finally:
        conn.close()
