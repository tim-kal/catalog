"""In-memory operation tracking for background tasks.

Provides a simple store to track long-running operations (scan, hash, etc.)
so the frontend can poll for status updates.
"""

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class OperationStatus(str, Enum):
    """Status of a background operation."""

    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


@dataclass
class Operation:
    """Represents a background operation."""

    id: str
    type: str  # scan, hash, copy, media, verify
    drive_name: str
    status: OperationStatus = OperationStatus.PENDING
    progress_percent: float | None = None
    result: dict | None = None
    error: str | None = None
    created_at: datetime = field(default_factory=datetime.now)
    completed_at: datetime | None = None


# Simple in-memory store (sufficient for single-user desktop app)
_operations: dict[str, Operation] = {}


def create_operation(op_type: str, drive_name: str) -> Operation:
    """Create and store a new operation.

    Args:
        op_type: Type of operation (scan, hash, etc.)
        drive_name: Name of the drive being operated on.

    Returns:
        The created Operation object.
    """
    op = Operation(id=str(uuid.uuid4())[:8], type=op_type, drive_name=drive_name)
    _operations[op.id] = op
    return op


def get_operation(op_id: str) -> Operation | None:
    """Get an operation by ID.

    Args:
        op_id: The operation ID.

    Returns:
        The Operation if found, None otherwise.
    """
    return _operations.get(op_id)


def update_operation(op_id: str, **kwargs) -> None:
    """Update an operation's fields.

    Args:
        op_id: The operation ID.
        **kwargs: Fields to update (status, progress_percent, result, error, etc.)
    """
    if op := _operations.get(op_id):
        for k, v in kwargs.items():
            setattr(op, k, v)


def list_operations(limit: int = 20) -> list[Operation]:
    """List recent operations, most recent first.

    Args:
        limit: Maximum number of operations to return.

    Returns:
        List of Operation objects sorted by created_at descending.
    """
    return sorted(_operations.values(), key=lambda o: o.created_at, reverse=True)[
        :limit
    ]
