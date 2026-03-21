"""Migration plan and execution endpoints for DriveCatalog API."""

from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, BackgroundTasks, HTTPException, Query

from drivecatalog.database import get_connection
from drivecatalog.migration import (
    execute_migration_plan,
    generate_migration_plan,
    get_plan_details,
    get_plan_files,
    validate_plan,
)

from ..models.migration import (
    ExecuteResponse,
    FileStatusCount,
    GeneratePlanRequest,
    MigrationFileResponse,
    MigrationFilesResponse,
    MigrationPlanResponse,
    MigrationPlanSummary,
    TargetSpaceInfo,
    ValidatePlanResponse,
)
from ..operations import (
    OperationStatus,
    cancel_operation,
    create_operation,
    update_operation,
)

router = APIRouter(prefix="/migrations", tags=["migrations"])


def _run_migration(plan_id: int, operation_id: str) -> None:
    """Run migration execution in background thread.

    Args:
        plan_id: ID of the migration plan to execute.
        operation_id: ID linking to the in-memory operation tracker.
    """
    try:
        execute_migration_plan(plan_id, operation_id)
    except Exception as e:
        update_operation(
            operation_id,
            status=OperationStatus.FAILED,
            error=str(e),
            completed_at=datetime.now(),
        )


@router.post("/generate", response_model=MigrationPlanSummary)
async def generate_plan(request: GeneratePlanRequest) -> MigrationPlanSummary:
    """Generate a migration plan for a source drive.

    Creates a new plan that assigns every file on the source drive to either
    a copy_and_delete or delete_only action based on consolidation strategy.
    """
    conn = get_connection()
    try:
        raw = generate_migration_plan(conn, request.source_drive)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    finally:
        conn.close()

    return MigrationPlanSummary(
        plan_id=raw["plan_id"],
        source_drive=raw["source_drive"],
        status=raw["status"],
        total_files=raw["total_files"],
        files_to_copy=raw["files_to_copy"],
        files_to_delete=raw["files_to_delete"],
        total_bytes_to_transfer=raw["total_bytes_to_transfer"],
        is_feasible=raw["is_feasible"],
    )


@router.get("/{plan_id}", response_model=MigrationPlanResponse)
async def get_plan(plan_id: int) -> MigrationPlanResponse:
    """Get full details of a migration plan including per-status file counts."""
    conn = get_connection()
    try:
        raw = get_plan_details(conn, plan_id)
    finally:
        conn.close()

    if raw is None:
        raise HTTPException(status_code=404, detail="Migration plan not found")

    return MigrationPlanResponse(
        plan_id=raw["plan_id"],
        source_drive_name=raw["source_drive_name"],
        status=raw["status"],
        total_files=raw["total_files"],
        files_to_copy=raw["files_to_copy"],
        files_to_delete=raw["files_to_delete"],
        total_bytes_to_transfer=raw["total_bytes_to_transfer"],
        files_completed=raw["files_completed"],
        bytes_transferred=raw["bytes_transferred"],
        files_failed=raw["files_failed"],
        errors=raw["errors"],
        operation_id=raw["operation_id"],
        created_at=raw["created_at"],
        started_at=raw["started_at"],
        completed_at=raw["completed_at"],
        file_status_counts={
            status: FileStatusCount(
                count=counts["count"],
                bytes=counts["bytes"],
            )
            for status, counts in raw["file_status_counts"].items()
        },
    )


@router.post("/{plan_id}/validate", response_model=ValidatePlanResponse)
async def validate(plan_id: int) -> ValidatePlanResponse:
    """Validate a migration plan by checking free space on target drives.

    Only draft plans can be validated. If all target drives have sufficient
    space, the plan status transitions from 'draft' to 'validated'.
    """
    conn = get_connection()
    try:
        raw = validate_plan(conn, plan_id)
    except ValueError as e:
        msg = str(e)
        if "not found" in msg:
            raise HTTPException(status_code=404, detail=msg)
        raise HTTPException(status_code=400, detail=msg)
    finally:
        conn.close()

    return ValidatePlanResponse(
        plan_id=raw["plan_id"],
        status=raw["status"],
        valid=raw["valid"],
        target_space=[
            TargetSpaceInfo(
                drive_name=t["drive_name"],
                bytes_needed=t["bytes_needed"],
                bytes_available=t["bytes_available"],
                sufficient=t["sufficient"],
            )
            for t in raw["target_space"]
        ],
    )


@router.post("/{plan_id}/execute", response_model=ExecuteResponse)
async def execute(
    plan_id: int, background_tasks: BackgroundTasks
) -> ExecuteResponse:
    """Start execution of a validated migration plan.

    Returns immediately with an operation_id that can be polled via
    GET /operations/{operation_id} for progress updates.
    """
    conn = get_connection()
    try:
        plan_row = conn.execute(
            "SELECT id, status, source_drive_name FROM migration_plans WHERE id = ?",
            (plan_id,),
        ).fetchone()

        if not plan_row:
            raise HTTPException(
                status_code=404, detail="Migration plan not found"
            )
        if plan_row["status"] != "validated":
            raise HTTPException(
                status_code=400,
                detail=f"Plan has status '{plan_row['status']}', must be 'validated' to execute",
            )

        source_drive_name = plan_row["source_drive_name"]
    finally:
        conn.close()

    op = create_operation("migration", source_drive_name)
    background_tasks.add_task(_run_migration, plan_id, op.id)

    return ExecuteResponse(
        plan_id=plan_id,
        operation_id=op.id,
        status="started",
        poll_url=f"/operations/{op.id}",
    )


@router.get("/{plan_id}/files", response_model=MigrationFilesResponse)
async def list_files(
    plan_id: int,
    status: str | None = Query(default=None, description="Filter by file status"),
    limit: int = Query(default=100, ge=1, le=1000, description="Max files to return"),
    offset: int = Query(default=0, ge=0, description="Number of files to skip"),
) -> MigrationFilesResponse:
    """Get paginated list of files in a migration plan.

    Optionally filter by status (pending, copying, verifying, verified,
    deleted, failed, skipped).
    """
    conn = get_connection()
    try:
        raw = get_plan_files(
            conn, plan_id, status_filter=status, limit=limit, offset=offset
        )
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    finally:
        conn.close()

    return MigrationFilesResponse(
        plan_id=raw["plan_id"],
        files=[
            MigrationFileResponse(
                id=f["id"],
                source_path=f["source_path"],
                source_size_bytes=f["source_size_bytes"],
                target_drive_name=f["target_drive_name"],
                target_path=f["target_path"],
                action=f["action"],
                status=f["status"],
                error=f["error"],
            )
            for f in raw["files"]
        ],
        total=raw["total"],
    )


@router.delete("/{plan_id}")
async def cancel_migration(plan_id: int) -> dict:
    """Cancel a running migration.

    Only plans with status 'executing' can be cancelled. Cancellation is
    asynchronous -- the background task checks for cancellation between files.
    """
    conn = get_connection()
    try:
        plan_row = conn.execute(
            "SELECT id, status, operation_id FROM migration_plans WHERE id = ?",
            (plan_id,),
        ).fetchone()

        if not plan_row:
            raise HTTPException(
                status_code=404, detail="Migration plan not found"
            )
        if plan_row["status"] != "executing":
            raise HTTPException(
                status_code=400, detail="Plan is not currently executing"
            )

        operation_id = plan_row["operation_id"]
        if not operation_id:
            raise HTTPException(
                status_code=400, detail="No operation to cancel"
            )
    finally:
        conn.close()

    cancel_operation(operation_id)

    return {"status": "cancelling", "plan_id": plan_id}
