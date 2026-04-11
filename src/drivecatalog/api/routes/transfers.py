"""Batch transfer API endpoints for DriveCatalog."""

from __future__ import annotations

import logging
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, HTTPException
from pydantic import BaseModel

from drivecatalog.database import get_connection
from drivecatalog.transfer import (
    TransferResult,
    TransferVerificationReport,
    create_transfer,
    execute_transfer,
    get_transfer_report,
    get_transfer_status,
    list_transfers,
    resume_transfer,
    verify_transfer,
)
from drivecatalog.watcher import get_mounted_volumes

from ..operations import (
    OperationStatus,
    create_operation,
    is_cancelled,
    update_operation,
    update_progress,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/transfers", tags=["transfers"])


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class CreateTransferRequest(BaseModel):
    source_drive: str
    dest_drive: str
    paths: list[str]
    dest_folder: str | None = None


class CreateTransferResponse(BaseModel):
    transfer_id: str
    operation_id: str
    total_files: int
    total_bytes: int


class TransferStatusResponse(BaseModel):
    transfer_id: str
    total: int
    completed: int
    failed: int
    pending: int
    in_progress: int
    cancelled: int
    total_bytes: int
    bytes_copied: int
    failed_files: list[dict]


class TransferReportResponse(BaseModel):
    transfer_id: str
    total_files: int
    completed: int
    failed: int
    pending: int
    cancelled: int
    total_bytes: int
    duration_seconds: float | None
    failures: list[dict]


class TransferListItem(BaseModel):
    transfer_id: str
    source_drive: str
    dest_drive: str
    total_files: int
    completed: int
    failed: int
    created_at: str
    status: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_mounted_drive_names(conn) -> set[str]:
    """Return set of drive names that are currently mounted."""
    mounted_paths = {str(v) for v in get_mounted_volumes()}
    rows = conn.execute("SELECT name, mount_path FROM drives").fetchall()
    return {r["name"] for r in rows if r["mount_path"] in mounted_paths}


def _run_transfer(operation_id: str, transfer_id: str) -> None:
    """Execute transfer in background thread."""
    from datetime import datetime

    conn = get_connection()
    try:
        update_operation(
            operation_id,
            status=OperationStatus.RUNNING,
            started_at=datetime.now(),
        )

        def progress_cb(files_done, files_total, bytes_done, bytes_total, current_file):
            update_progress(operation_id, files_done, files_total)

        def cancel_check():
            return is_cancelled(operation_id)

        result = execute_transfer(conn, transfer_id, progress_cb, cancel_check)

        if result.files_failed > 0:
            update_operation(
                operation_id,
                status=OperationStatus.COMPLETED,
                result={
                    "files_completed": result.files_completed,
                    "files_failed": result.files_failed,
                    "bytes_copied": result.bytes_copied,
                    "failures": result.failures,
                },
                completed_at=datetime.now(),
            )
        else:
            update_operation(
                operation_id,
                status=OperationStatus.COMPLETED,
                result={
                    "files_completed": result.files_completed,
                    "bytes_copied": result.bytes_copied,
                },
                completed_at=datetime.now(),
            )
    except Exception as e:
        logger.exception("Transfer %s failed", transfer_id)
        update_operation(
            operation_id,
            status=OperationStatus.FAILED,
            error=str(e),
            completed_at=datetime.now(),
        )
    finally:
        conn.close()


def _run_resume(operation_id: str, transfer_id: str) -> None:
    """Resume transfer in background thread."""
    from datetime import datetime

    conn = get_connection()
    try:
        update_operation(
            operation_id,
            status=OperationStatus.RUNNING,
            started_at=datetime.now(),
        )

        def progress_cb(files_done, files_total, bytes_done, bytes_total, current_file):
            update_progress(operation_id, files_done, files_total)

        def cancel_check():
            return is_cancelled(operation_id)

        result = resume_transfer(conn, transfer_id, progress_cb, cancel_check)

        update_operation(
            operation_id,
            status=OperationStatus.COMPLETED,
            result={
                "files_completed": result.files_completed,
                "files_failed": result.files_failed,
                "bytes_copied": result.bytes_copied,
            },
            completed_at=datetime.now(),
        )
    except Exception as e:
        logger.exception("Resume transfer %s failed", transfer_id)
        update_operation(
            operation_id,
            status=OperationStatus.FAILED,
            error=str(e),
            completed_at=datetime.now(),
        )
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("", response_model=CreateTransferResponse, status_code=201)
async def create_and_start_transfer(
    req: CreateTransferRequest,
    background_tasks: BackgroundTasks,
) -> CreateTransferResponse:
    """Create and start a batch transfer.

    If paths contains a folder, it will be expanded to all files recursively.
    Validates both drives are mounted before starting.
    """
    conn = get_connection()
    try:
        # Validate both drives exist and are mounted
        mounted = _get_mounted_drive_names(conn)
        if req.source_drive not in mounted:
            raise HTTPException(
                400, f"Source drive '{req.source_drive}' is not mounted"
            )
        if req.dest_drive not in mounted:
            raise HTTPException(
                400, f"Destination drive '{req.dest_drive}' is not mounted"
            )

        manifest = create_transfer(
            conn, req.source_drive, req.dest_drive, req.paths, req.dest_folder
        )

        if manifest.total_files == 0:
            raise HTTPException(
                400, "No matching files found for the given paths"
            )

        # Create operation for progress tracking
        op = create_operation(
            "transfer", f"{req.source_drive}->{req.dest_drive}"
        )
        update_operation(op.id, files_total=manifest.total_files)

        # Start transfer in background
        background_tasks.add_task(_run_transfer, op.id, manifest.transfer_id)

        return CreateTransferResponse(
            transfer_id=manifest.transfer_id,
            operation_id=op.id,
            total_files=manifest.total_files,
            total_bytes=manifest.total_bytes,
        )
    finally:
        conn.close()


@router.get("/{transfer_id}", response_model=TransferStatusResponse)
async def get_transfer(transfer_id: str) -> TransferStatusResponse:
    """Get transfer status including per-file progress."""
    conn = get_connection()
    try:
        status = get_transfer_status(conn, transfer_id)
        if status["total"] == 0:
            raise HTTPException(404, f"Transfer '{transfer_id}' not found")
        return TransferStatusResponse(**status)
    finally:
        conn.close()


@router.post("/{transfer_id}/resume")
async def resume_transfer_endpoint(
    transfer_id: str,
    background_tasks: BackgroundTasks,
) -> dict:
    """Resume a failed or interrupted transfer."""
    conn = get_connection()
    try:
        status = get_transfer_status(conn, transfer_id)
        if status["total"] == 0:
            raise HTTPException(404, f"Transfer '{transfer_id}' not found")

        if status["pending"] == 0 and status["failed"] == 0 and status["in_progress"] == 0:
            raise HTTPException(
                400, "Nothing to resume — all actions are completed or cancelled"
            )

        # Validate drives are mounted
        mounted = _get_mounted_drive_names(conn)
        row = conn.execute(
            "SELECT DISTINCT source_drive, target_drive FROM planned_actions WHERE transfer_id = ?",
            (transfer_id,),
        ).fetchone()
        if row["source_drive"] not in mounted:
            raise HTTPException(400, f"Source drive '{row['source_drive']}' is not mounted")
        if row["target_drive"] not in mounted:
            raise HTTPException(400, f"Destination drive '{row['target_drive']}' is not mounted")

        op = create_operation(
            "transfer_resume",
            f"{row['source_drive']}->{row['target_drive']}",
        )
        background_tasks.add_task(_run_resume, op.id, transfer_id)

        return {
            "transfer_id": transfer_id,
            "operation_id": op.id,
            "status": "resuming",
        }
    finally:
        conn.close()


@router.get("", response_model=list[TransferListItem])
async def list_all_transfers() -> list[TransferListItem]:
    """List all transfers with summary stats."""
    conn = get_connection()
    try:
        transfers = list_transfers(conn)
        return [TransferListItem(**t) for t in transfers]
    finally:
        conn.close()


@router.post("/{transfer_id}/cancel")
async def cancel_transfer(transfer_id: str) -> dict:
    """Cancel a running transfer.

    Sets all pending actions to 'cancelled'. Does NOT delete already-copied files.
    """
    conn = get_connection()
    try:
        status = get_transfer_status(conn, transfer_id)
        if status["total"] == 0:
            raise HTTPException(404, f"Transfer '{transfer_id}' not found")

        cancelled_count = conn.execute(
            """
            UPDATE planned_actions
            SET status = 'cancelled'
            WHERE transfer_id = ? AND status IN ('pending', 'failed')
            """,
            (transfer_id,),
        ).rowcount
        conn.commit()

        return {
            "transfer_id": transfer_id,
            "cancelled_actions": cancelled_count,
            "completed_actions": status["completed"],
        }
    finally:
        conn.close()


def _run_verify(operation_id: str, transfer_id: str) -> None:
    """Run verification in background thread."""
    from datetime import datetime

    conn = get_connection()
    try:
        update_operation(
            operation_id,
            status=OperationStatus.RUNNING,
            started_at=datetime.now(),
        )

        def progress_cb(files_done, files_total, bytes_done, bytes_total, current_file):
            update_progress(operation_id, files_done, files_total)

        def cancel_check():
            return is_cancelled(operation_id)

        report = verify_transfer(conn, transfer_id, progress_cb, cancel_check)

        update_operation(
            operation_id,
            status=OperationStatus.COMPLETED,
            result={
                "transfer_id": report.transfer_id,
                "verified_at": report.verified_at,
                "total_files": report.total_files,
                "verified_ok": report.verified_ok,
                "verified_failed": report.verified_failed,
                "skipped": report.skipped,
                "failures": report.failures,
                "total_bytes_verified": report.total_bytes_verified,
                "duration_seconds": report.duration_seconds,
            },
            completed_at=datetime.now(),
        )
    except Exception as e:
        logger.exception("Verify transfer %s failed", transfer_id)
        update_operation(
            operation_id,
            status=OperationStatus.FAILED,
            error=str(e),
            completed_at=datetime.now(),
        )
    finally:
        conn.close()


@router.post("/{transfer_id}/verify")
async def verify_transfer_endpoint(
    transfer_id: str,
    background_tasks: BackgroundTasks,
) -> dict:
    """Re-verify all completed files for a transfer by reading from disk.

    Runs as a background operation. Returns operation_id and poll_url immediately.
    """
    conn = get_connection()
    try:
        status = get_transfer_status(conn, transfer_id)
        if status["total"] == 0:
            raise HTTPException(404, f"Transfer '{transfer_id}' not found")

        if status["completed"] == 0:
            raise HTTPException(400, "No completed files to verify")

        op = create_operation("verify", f"verify-{transfer_id[:8]}")
        update_operation(op.id, files_total=status["completed"])

        background_tasks.add_task(_run_verify, op.id, transfer_id)

        return {
            "operation_id": op.id,
            "poll_url": f"/operations/{op.id}",
        }
    finally:
        conn.close()


@router.get("/{transfer_id}/report", response_model=TransferReportResponse)
async def get_report(transfer_id: str) -> TransferReportResponse:
    """Get a transfer summary report without re-verifying (DB query only)."""
    conn = get_connection()
    try:
        report = get_transfer_report(conn, transfer_id)
        if report is None:
            raise HTTPException(404, f"Transfer '{transfer_id}' not found")
        return TransferReportResponse(**report)
    finally:
        conn.close()
