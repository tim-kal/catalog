"""Copy operation endpoint for DriveCatalog API."""

from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, HTTPException

from drivecatalog.copier import copy_file_verified, log_copy_operation
from drivecatalog.database import get_connection

from ..models.scan import CopyRequest
from ..operations import OperationStatus, create_operation, update_operation

router = APIRouter(tags=["copy"])


def _run_copy(
    operation_id: str,
    src_path: Path,
    dst_path: Path,
    src_file_id: int,
    dst_drive_id: int,
    dst_mount_path: str,
) -> None:
    """Run verified copy in background thread.

    Args:
        operation_id: ID of the operation to track progress.
        src_path: Full path to source file.
        dst_path: Full path to destination file.
        src_file_id: Database ID of the source file.
        dst_drive_id: Database ID of the destination drive.
        dst_mount_path: Mount path of destination drive for relative path calculation.
    """
    update_operation(operation_id, status=OperationStatus.RUNNING)

    started_at = datetime.now()
    try:
        result = copy_file_verified(src_path, dst_path)

        if result.error:
            update_operation(
                operation_id,
                status=OperationStatus.FAILED,
                error=result.error,
                completed_at=datetime.now(),
            )
            return

        # Log operation to database
        conn = get_connection()
        try:
            # Calculate relative path for destination
            dst_relative = str(dst_path.relative_to(dst_mount_path))
            log_copy_operation(
                conn,
                src_file_id,
                dst_drive_id,
                dst_relative,
                result,
                started_at,
                datetime.now(),
            )
        finally:
            conn.close()

        update_operation(
            operation_id,
            status=OperationStatus.COMPLETED,
            result={
                "bytes_copied": result.bytes_copied,
                "source_hash": result.source_hash,
                "dest_hash": result.dest_hash,
                "verified": result.verified,
            },
            completed_at=datetime.now(),
        )
    except Exception as e:
        update_operation(
            operation_id,
            status=OperationStatus.FAILED,
            error=str(e),
            completed_at=datetime.now(),
        )


@router.post("/copy")
async def trigger_copy(
    request: CopyRequest,
    background_tasks: BackgroundTasks,
) -> dict:
    """Trigger a verified file copy as a background task.

    Copies a file from source drive to destination drive with SHA256 verification.
    Returns immediately with an operation_id that can be used to poll for status.
    """
    conn = get_connection()
    try:
        # Look up source drive
        src_drive = conn.execute(
            "SELECT id, name, mount_path FROM drives WHERE name = ?",
            (request.source_drive,),
        ).fetchone()

        if not src_drive:
            raise HTTPException(
                status_code=404, detail=f"Source drive '{request.source_drive}' not found"
            )

        src_mount_path = src_drive["mount_path"]
        if not src_mount_path or not Path(src_mount_path).exists():
            raise HTTPException(
                status_code=400,
                detail=f"Source drive '{request.source_drive}' is not currently mounted",
            )

        # Look up destination drive
        dst_drive = conn.execute(
            "SELECT id, name, mount_path FROM drives WHERE name = ?",
            (request.dest_drive,),
        ).fetchone()

        if not dst_drive:
            raise HTTPException(
                status_code=404,
                detail=f"Destination drive '{request.dest_drive}' not found",
            )

        dst_mount_path = dst_drive["mount_path"]
        if not dst_mount_path or not Path(dst_mount_path).exists():
            raise HTTPException(
                status_code=400,
                detail=f"Destination drive '{request.dest_drive}' is not currently mounted",
            )

        # Validate source file exists in catalog
        src_file = conn.execute(
            "SELECT id, path FROM files WHERE drive_id = ? AND path = ?",
            (src_drive["id"], request.source_path),
        ).fetchone()

        if not src_file:
            raise HTTPException(
                status_code=404,
                detail=f"Source file '{request.source_path}' not found in catalog for drive '{request.source_drive}'",
            )

        # Build full paths
        src_full_path = Path(src_mount_path) / request.source_path
        if not src_full_path.exists():
            raise HTTPException(
                status_code=404,
                detail=f"Source file '{request.source_path}' exists in catalog but not on disk",
            )

        # Determine destination path
        dest_relative = request.dest_path if request.dest_path else request.source_path
        dst_full_path = Path(dst_mount_path) / dest_relative

        # Check destination doesn't already exist (no overwrite)
        if dst_full_path.exists():
            raise HTTPException(
                status_code=400,
                detail=f"Destination file '{dest_relative}' already exists on drive '{request.dest_drive}'",
            )

        # Create operation and start background task
        op = create_operation("copy", f"{request.source_drive}->{request.dest_drive}")
        background_tasks.add_task(
            _run_copy,
            op.id,
            src_full_path,
            dst_full_path,
            src_file["id"],
            dst_drive["id"],
            dst_mount_path,
        )

        return {
            "operation_id": op.id,
            "status": "started",
            "poll_url": f"/operations/{op.id}",
        }
    finally:
        conn.close()
