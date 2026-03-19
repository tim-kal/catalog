"""Tests for API operations endpoints."""

from drivecatalog.api.operations import (
    OperationStatus,
    _operations,
    create_operation,
    get_operation,
    list_operations,
    update_operation,
)


def test_create_operation():
    """create_operation stores and returns an operation."""
    _operations.clear()
    op = create_operation("scan", "TestDrive")
    assert op.type == "scan"
    assert op.drive_name == "TestDrive"
    assert op.status == OperationStatus.PENDING
    assert op.id in _operations


def test_get_operation():
    """get_operation retrieves by ID."""
    _operations.clear()
    op = create_operation("hash", "DriveX")
    result = get_operation(op.id)
    assert result is op


def test_get_operation_not_found():
    """get_operation returns None for unknown ID."""
    _operations.clear()
    assert get_operation("nonexistent") is None


def test_update_operation():
    """update_operation modifies fields."""
    _operations.clear()
    op = create_operation("scan", "Drive1")
    update_operation(op.id, status=OperationStatus.RUNNING, progress_percent=50.0)
    assert op.status == OperationStatus.RUNNING
    assert op.progress_percent == 50.0


def test_list_operations_ordering():
    """list_operations returns most recent first."""
    _operations.clear()
    create_operation("scan", "D1")
    op2 = create_operation("hash", "D2")
    ops = list_operations()
    assert ops[0].id == op2.id  # Most recent first


def test_api_list_operations_empty(test_client):
    """GET /operations returns empty list."""
    _operations.clear()
    resp = test_client.get("/operations")
    assert resp.status_code == 200
    data = resp.json()
    assert data["operations"] == []


def test_api_get_operation_not_found(test_client):
    """GET /operations/{id} returns 404."""
    _operations.clear()
    resp = test_client.get("/operations/nonexistent")
    assert resp.status_code == 404


def test_api_get_operation_found(test_client):
    """GET /operations/{id} returns operation details."""
    _operations.clear()
    op = create_operation("scan", "TestDrive")
    resp = test_client.get(f"/operations/{op.id}")
    assert resp.status_code == 200
    data = resp.json()
    assert data["type"] == "scan"
    assert data["status"] == "pending"


def test_operation_lifecycle():
    """Full operation lifecycle: create -> update -> complete."""
    _operations.clear()
    op = create_operation("scan", "Drive1")
    assert op.status == OperationStatus.PENDING

    update_operation(op.id, status=OperationStatus.RUNNING, progress_percent=0.0)
    assert op.status == OperationStatus.RUNNING

    update_operation(
        op.id,
        status=OperationStatus.COMPLETED,
        progress_percent=100.0,
        result={"new_files": 10},
    )
    assert op.status == OperationStatus.COMPLETED
    assert op.result == {"new_files": 10}
