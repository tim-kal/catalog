"""Integration tests for concurrent drive scanning (DC-005).

Tests that multiple drives can be scanned simultaneously without DB corruption,
and that the per-drive lock prevents double-scanning the same drive.
"""

import sqlite3
import threading
from pathlib import Path

import pytest

from drivecatalog.api.operations import (
    OperationStatus,
    _active_scans,
    _operations,
    acquire_scan_lock,
    create_operation,
    get_active_scan,
    release_scan_lock,
    update_operation,
)
from drivecatalog.database import get_connection
from drivecatalog.scanner import ScanResult, scan_drive


@pytest.fixture()
def two_drives(tmp_db, tmp_path):
    """Create two drives with files on disk and in the DB."""
    drives = []
    for i, name in enumerate(["DriveA", "DriveB"]):
        drive_dir = tmp_path / name
        drive_dir.mkdir()
        # Create 20 files per drive
        for j in range(20):
            f = drive_dir / f"file_{j}.txt"
            f.write_text(f"content {name} {j}")

        tmp_db.execute(
            "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
            (name, f"UUID-{i}", str(drive_dir), 1_000_000),
        )
        tmp_db.commit()
        row = tmp_db.execute("SELECT * FROM drives WHERE name = ?", (name,)).fetchone()
        drives.append(dict(row))

    return drives


def test_concurrent_scans_no_corruption(two_drives, tmp_path, monkeypatch):
    """Start two scans concurrently, verify both complete without DB corruption."""
    drive_a, drive_b = two_drives
    results = {}
    errors = []

    def scan_one(drive):
        try:
            conn = get_connection()
            try:
                r = scan_drive(
                    drive["id"],
                    drive["mount_path"],
                    conn,
                )
                results[drive["name"]] = r
            finally:
                conn.close()
        except Exception as e:
            errors.append((drive["name"], e))

    t1 = threading.Thread(target=scan_one, args=(drive_a,))
    t2 = threading.Thread(target=scan_one, args=(drive_b,))
    t1.start()
    t2.start()
    t1.join(timeout=30)
    t2.join(timeout=30)

    assert not errors, f"Scan errors: {errors}"
    assert "DriveA" in results
    assert "DriveB" in results
    assert results["DriveA"].new_files == 20
    assert results["DriveB"].new_files == 20
    assert not results["DriveA"].cancelled
    assert not results["DriveB"].cancelled

    # Verify DB integrity — both drives have their files
    conn = get_connection()
    try:
        a_count = conn.execute(
            "SELECT COUNT(*) FROM files WHERE drive_id = ?", (drive_a["id"],)
        ).fetchone()[0]
        b_count = conn.execute(
            "SELECT COUNT(*) FROM files WHERE drive_id = ?", (drive_b["id"],)
        ).fetchone()[0]
        assert a_count == 20
        assert b_count == 20

        # No cross-contamination
        a_files = conn.execute(
            "SELECT path FROM files WHERE drive_id = ?", (drive_a["id"],)
        ).fetchall()
        b_files = conn.execute(
            "SELECT path FROM files WHERE drive_id = ?", (drive_b["id"],)
        ).fetchall()
        a_paths = {r["path"] for r in a_files}
        b_paths = {r["path"] for r in b_files}
        assert a_paths == b_paths  # Same filenames, different drives
    finally:
        conn.close()


def test_per_drive_lock_prevents_double_scan():
    """acquire_scan_lock returns False when drive already has an active scan."""
    _operations.clear()
    _active_scans.clear()

    op1 = create_operation("scan", "DriveX")
    update_operation(op1.id, status=OperationStatus.RUNNING)

    assert acquire_scan_lock("DriveX", op1.id) is True
    assert get_active_scan("DriveX") == op1.id

    op2 = create_operation("scan", "DriveX")
    assert acquire_scan_lock("DriveX", op2.id) is False

    # Different drive is fine
    op3 = create_operation("scan", "DriveY")
    assert acquire_scan_lock("DriveY", op3.id) is True

    _operations.clear()
    _active_scans.clear()


def test_lock_released_after_completion():
    """Lock is released after scan completes."""
    _operations.clear()
    _active_scans.clear()

    op = create_operation("scan", "DriveZ")
    update_operation(op.id, status=OperationStatus.RUNNING)
    acquire_scan_lock("DriveZ", op.id)

    assert get_active_scan("DriveZ") == op.id

    # Simulate completion
    update_operation(op.id, status=OperationStatus.COMPLETED)
    release_scan_lock("DriveZ")

    assert get_active_scan("DriveZ") is None

    # Can now acquire again
    op2 = create_operation("scan", "DriveZ")
    assert acquire_scan_lock("DriveZ", op2.id) is True

    _operations.clear()
    _active_scans.clear()


def test_stale_lock_auto_cleans():
    """Stale lock (completed operation) is automatically cleaned on acquire."""
    _operations.clear()
    _active_scans.clear()

    op = create_operation("scan", "DriveW")
    acquire_scan_lock("DriveW", op.id)
    # Mark completed but forget to release
    update_operation(op.id, status=OperationStatus.COMPLETED)

    # New acquire should succeed (stale lock cleaned)
    op2 = create_operation("scan", "DriveW")
    assert acquire_scan_lock("DriveW", op2.id) is True

    _operations.clear()
    _active_scans.clear()


def test_cancellation_isolation(two_drives, monkeypatch):
    """Cancelling one scan doesn't affect the other."""
    _operations.clear()
    _active_scans.clear()

    drive_a, drive_b = two_drives
    op_a = create_operation("scan", "DriveA")
    op_b = create_operation("scan", "DriveB")
    update_operation(op_a.id, status=OperationStatus.RUNNING)
    update_operation(op_b.id, status=OperationStatus.RUNNING)
    acquire_scan_lock("DriveA", op_a.id)
    acquire_scan_lock("DriveB", op_b.id)

    from drivecatalog.api.operations import cancel_operation, is_cancelled

    # Cancel only DriveA's scan
    cancel_operation(op_a.id)

    assert is_cancelled(op_a.id) is True
    assert is_cancelled(op_b.id) is False

    _operations.clear()
    _active_scans.clear()


def test_api_409_on_duplicate_scan(test_client, tmp_path, monkeypatch):
    """POST /drives/{name}/scan returns 409 when drive is already scanning."""
    _operations.clear()
    _active_scans.clear()

    drive_dir = tmp_path / "ScanDrive"
    drive_dir.mkdir()
    (drive_dir / "file.txt").write_text("hello")

    # Patch validate_mount_path to accept our tmp_path
    monkeypatch.setattr("drivecatalog.api.routes.drives.validate_mount_path", lambda p: True)
    monkeypatch.setattr(
        "drivecatalog.api.routes.drives.get_drive_info",
        lambda p: {
            "name": "ScanDrive",
            "uuid": "SCAN-UUID",
            "mount_path": str(drive_dir),
            "total_bytes": 1_000_000,
        },
    )

    # Register drive
    resp = test_client.post("/drives", json={"path": str(drive_dir)})
    assert resp.status_code == 201

    # Simulate an active scan by acquiring the lock directly
    fake_op = create_operation("scan", "ScanDrive")
    update_operation(fake_op.id, status=OperationStatus.RUNNING)
    acquire_scan_lock("ScanDrive", fake_op.id)

    # Request should return 409 since the lock is held
    resp = test_client.post("/drives/ScanDrive/scan")
    assert resp.status_code == 409
    assert "already being scanned" in resp.json()["detail"]

    # Auto-scan should also return 409
    resp = test_client.post("/drives/ScanDrive/auto-scan")
    assert resp.status_code == 409

    _operations.clear()
    _active_scans.clear()
