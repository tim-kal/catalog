"""In-memory operation tracking for background tasks.

Provides a simple store to track long-running operations (scan, hash, etc.)
so the frontend can poll for status updates.
"""

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum


class OperationStatus(StrEnum):
    """Status of a background operation."""

    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


@dataclass
class Operation:
    """Represents a background operation."""

    id: str
    type: str  # scan, hash, copy, media, verify
    drive_name: str
    status: OperationStatus = OperationStatus.PENDING
    progress_percent: float | None = None
    eta_seconds: float | None = None
    files_processed: int = 0
    files_total: int = 0
    result: dict | None = None
    error: str | None = None
    cancel_requested: bool = False
    created_at: datetime = field(default_factory=datetime.now)
    started_at: datetime | None = None
    completed_at: datetime | None = None


# Simple in-memory store (sufficient for single-user desktop app)
_operations: dict[str, Operation] = {}

# Per-drive scan lock: maps drive_name -> operation_id for active scans.
# Prevents the same drive from being scanned twice simultaneously.
_active_scans: dict[str, str] = {}


def create_operation(op_type: str, drive_name: str) -> Operation:
    """Create and store a new operation."""
    op = Operation(id=str(uuid.uuid4())[:8], type=op_type, drive_name=drive_name)
    _operations[op.id] = op
    return op


def get_operation(op_id: str) -> Operation | None:
    """Get an operation by ID."""
    return _operations.get(op_id)


def cancel_operation(op_id: str) -> bool:
    """Request cancellation of an operation. Returns True if operation was found and running."""
    op = _operations.get(op_id)
    if op and op.status in (OperationStatus.PENDING, OperationStatus.RUNNING):
        op.cancel_requested = True
        return True
    return False


def is_cancelled(op_id: str) -> bool:
    """Check if cancellation was requested for an operation."""
    op = _operations.get(op_id)
    return op.cancel_requested if op else False


def update_operation(op_id: str, **kwargs) -> None:
    """Update an operation's fields."""
    if op := _operations.get(op_id):
        for k, v in kwargs.items():
            setattr(op, k, v)


def update_progress(op_id: str, files_processed: int, files_total: int) -> None:
    """Update operation progress with ETA calculation."""
    op = _operations.get(op_id)
    if not op or not op.started_at:
        return

    op.files_processed = files_processed
    op.files_total = files_total
    op.progress_percent = (files_processed / files_total * 100) if files_total > 0 else 0

    elapsed = (datetime.now() - op.started_at).total_seconds()
    if elapsed > 0 and files_processed > 0:
        rate = files_processed / elapsed
        remaining = files_total - files_processed
        op.eta_seconds = round(remaining / rate, 1) if rate > 0 else None
    else:
        op.eta_seconds = None


def acquire_scan_lock(drive_name: str, operation_id: str) -> bool:
    """Try to acquire a per-drive scan lock. Returns False if drive is already being scanned."""
    if drive_name in _active_scans:
        existing_op = _operations.get(_active_scans[drive_name])
        if existing_op and existing_op.status in (OperationStatus.PENDING, OperationStatus.RUNNING):
            return False
        # Stale lock — previous scan finished without cleanup
        del _active_scans[drive_name]
    _active_scans[drive_name] = operation_id
    return True


def release_scan_lock(drive_name: str) -> None:
    """Release the per-drive scan lock."""
    _active_scans.pop(drive_name, None)


def get_active_scan(drive_name: str) -> str | None:
    """Return the operation_id of the active scan for a drive, or None."""
    op_id = _active_scans.get(drive_name)
    if op_id:
        existing_op = _operations.get(op_id)
        if existing_op and existing_op.status in (OperationStatus.PENDING, OperationStatus.RUNNING):
            return op_id
        # Stale — clean up
        _active_scans.pop(drive_name, None)
    return None


def list_operations(limit: int = 20) -> list[Operation]:
    """List recent operations, most recent first."""
    return sorted(_operations.values(), key=lambda o: o.created_at, reverse=True)[
        :limit
    ]
