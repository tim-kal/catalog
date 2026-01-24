"""Operation status endpoints for DriveCatalog API."""

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from ..operations import get_operation, list_operations, OperationStatus


router = APIRouter(prefix="/operations", tags=["operations"])


class OperationResponse(BaseModel):
    """Response model for operation status."""

    id: str
    type: str
    drive_name: str
    status: OperationStatus
    progress_percent: float | None = None
    result: dict | None = None
    error: str | None = None
    created_at: str
    completed_at: str | None = None


class OperationListResponse(BaseModel):
    """Response model for operation list."""

    operations: list[OperationResponse]
    total: int


def _operation_to_response(op) -> OperationResponse:
    """Convert Operation dataclass to response model."""
    return OperationResponse(
        id=op.id,
        type=op.type,
        drive_name=op.drive_name,
        status=op.status,
        progress_percent=op.progress_percent,
        result=op.result,
        error=op.error,
        created_at=op.created_at.isoformat(),
        completed_at=op.completed_at.isoformat() if op.completed_at else None,
    )


@router.get("", response_model=OperationListResponse)
async def list_all_operations(limit: int = 20) -> OperationListResponse:
    """List recent operations.

    Returns operations sorted by creation time, most recent first.
    """
    ops = list_operations(limit=limit)
    return OperationListResponse(
        operations=[_operation_to_response(op) for op in ops],
        total=len(ops),
    )


@router.get("/{operation_id}", response_model=OperationResponse)
async def get_operation_status(operation_id: str) -> OperationResponse:
    """Get status of a specific operation.

    Use this endpoint to poll for progress updates on long-running operations.
    """
    op = get_operation(operation_id)
    if not op:
        raise HTTPException(status_code=404, detail=f"Operation '{operation_id}' not found")

    return _operation_to_response(op)
