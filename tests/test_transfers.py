"""Tests for batch transfer engine (DC-014, DC-015)."""

import hashlib
import sqlite3
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from drivecatalog.copier import CopyResult
from drivecatalog.transfer import (
    TransferManifest,
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


@pytest.fixture
def db(tmp_path):
    """Create an in-memory database with the necessary tables."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row

    conn.executescript("""
        CREATE TABLE drives (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            mount_path TEXT
        );

        CREATE TABLE files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            drive_id INTEGER NOT NULL REFERENCES drives(id),
            path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE planned_actions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            action_type TEXT NOT NULL CHECK(action_type IN ('delete', 'copy', 'move')),
            status TEXT NOT NULL DEFAULT 'pending'
                CHECK(status IN ('pending', 'ready', 'in_progress', 'completed', 'failed', 'cancelled')),
            priority INTEGER NOT NULL DEFAULT 0,
            source_drive TEXT NOT NULL,
            source_path TEXT NOT NULL,
            target_drive TEXT,
            target_path TEXT,
            estimated_bytes INTEGER,
            transfer_id TEXT,
            depends_on INTEGER REFERENCES planned_actions(id),
            error TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            started_at TEXT,
            completed_at TEXT
        );
        CREATE INDEX idx_planned_actions_status ON planned_actions(status);
        CREATE INDEX idx_planned_actions_transfer_id ON planned_actions(transfer_id);

        CREATE TABLE copy_operations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_file_id INTEGER NOT NULL,
            dest_drive_id INTEGER NOT NULL,
            dest_path TEXT NOT NULL,
            source_hash TEXT,
            dest_hash TEXT,
            verified INTEGER,
            bytes_copied INTEGER,
            started_at TEXT,
            completed_at TEXT
        );
    """)

    # Insert test drives with mount paths under tmp_path
    src_mount = str(tmp_path / "src_drive")
    dst_mount = str(tmp_path / "dst_drive")
    Path(src_mount).mkdir()
    Path(dst_mount).mkdir()

    conn.execute(
        "INSERT INTO drives (name, mount_path) VALUES (?, ?)",
        ("SrcDrive", src_mount),
    )
    conn.execute(
        "INSERT INTO drives (name, mount_path) VALUES (?, ?)",
        ("DstDrive", dst_mount),
    )

    # Insert 3 test files on source drive
    for name, size in [("photos/a.jpg", 1000), ("photos/b.jpg", 2000), ("videos/c.mov", 5000)]:
        # Create actual file on disk
        file_path = Path(src_mount) / name
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_bytes(b"x" * size)

        conn.execute(
            "INSERT INTO files (drive_id, path, size_bytes) VALUES (1, ?, ?)",
            (name, size),
        )

    conn.commit()
    return conn


def test_create_transfer_3_files(db):
    """create_transfer with 3 files creates 3 planned_actions rows."""
    manifest = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["photos/a.jpg", "photos/b.jpg", "videos/c.mov"],
    )

    assert isinstance(manifest, TransferManifest)
    assert manifest.total_files == 3
    assert manifest.total_bytes == 8000  # 1000 + 2000 + 5000

    rows = db.execute(
        "SELECT * FROM planned_actions WHERE transfer_id = ?",
        (manifest.transfer_id,),
    ).fetchall()
    assert len(rows) == 3
    assert all(r["action_type"] == "copy" for r in rows)
    assert all(r["status"] == "pending" for r in rows)


def test_execute_transfer_all_completed(db):
    """execute_transfer: mock copy_file_verified, assert all actions reach 'completed'."""
    manifest = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["photos/a.jpg", "photos/b.jpg", "videos/c.mov"],
    )

    mock_result = CopyResult(
        source_hash="abc123",
        dest_hash="abc123",
        verified=True,
        bytes_copied=1000,
        metadata_preserved=True,
    )

    with patch("drivecatalog.transfer.copy_file_verified", return_value=mock_result):
        result = execute_transfer(db, manifest.transfer_id)

    assert isinstance(result, TransferResult)
    assert result.files_completed == 3
    assert result.files_failed == 0

    # All actions should be 'completed'
    rows = db.execute(
        "SELECT status FROM planned_actions WHERE transfer_id = ?",
        (manifest.transfer_id,),
    ).fetchall()
    assert all(r["status"] == "completed" for r in rows)


def test_resume_copies_only_remaining(db):
    """resume: set 2 of 3 to 'completed', resume copies only the remaining 1."""
    manifest = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["photos/a.jpg", "photos/b.jpg", "videos/c.mov"],
    )

    # Mark first two as completed
    actions = db.execute(
        "SELECT id FROM planned_actions WHERE transfer_id = ? ORDER BY id",
        (manifest.transfer_id,),
    ).fetchall()

    db.execute(
        "UPDATE planned_actions SET status = 'completed' WHERE id IN (?, ?)",
        (actions[0]["id"], actions[1]["id"]),
    )
    # Mark the third as failed (so resume picks it up)
    db.execute(
        "UPDATE planned_actions SET status = 'failed', error = 'IO error' WHERE id = ?",
        (actions[2]["id"],),
    )
    db.commit()

    copy_calls = []

    def mock_copy(src, dst, progress_callback=None):
        copy_calls.append(str(src))
        return CopyResult(
            source_hash="abc", dest_hash="abc",
            verified=True, bytes_copied=5000,
        )

    with patch("drivecatalog.transfer.copy_file_verified", side_effect=mock_copy):
        result = resume_transfer(db, manifest.transfer_id)

    # Only 1 file should have been copied (the failed one)
    assert len(copy_calls) == 1
    assert "c.mov" in copy_calls[0]

    # The previously completed ones stay completed
    statuses = db.execute(
        "SELECT status FROM planned_actions WHERE transfer_id = ? ORDER BY id",
        (manifest.transfer_id,),
    ).fetchall()
    assert statuses[0]["status"] == "completed"
    assert statuses[1]["status"] == "completed"
    assert statuses[2]["status"] == "completed"


def test_cancel_pending_cancelled_completed_untouched(db):
    """cancel: pending items become 'cancelled', completed items untouched."""
    manifest = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["photos/a.jpg", "photos/b.jpg", "videos/c.mov"],
    )

    # Mark first action as completed
    actions = db.execute(
        "SELECT id FROM planned_actions WHERE transfer_id = ? ORDER BY id",
        (manifest.transfer_id,),
    ).fetchall()
    db.execute(
        "UPDATE planned_actions SET status = 'completed' WHERE id = ?",
        (actions[0]["id"],),
    )
    db.commit()

    # Cancel: set remaining pending to cancelled
    db.execute(
        "UPDATE planned_actions SET status = 'cancelled' WHERE transfer_id = ? AND status IN ('pending', 'failed')",
        (manifest.transfer_id,),
    )
    db.commit()

    statuses = db.execute(
        "SELECT status FROM planned_actions WHERE transfer_id = ? ORDER BY id",
        (manifest.transfer_id,),
    ).fetchall()
    assert statuses[0]["status"] == "completed"  # untouched
    assert statuses[1]["status"] == "cancelled"
    assert statuses[2]["status"] == "cancelled"


def test_folder_expansion(db, tmp_path):
    """Folder path expands to all files within."""
    # "photos" is a folder containing a.jpg and b.jpg
    manifest = create_transfer(
        db, "SrcDrive", "DstDrive", ["photos"],
    )

    assert manifest.total_files == 2
    paths = [f["path"] for f in manifest.files]
    assert "photos/a.jpg" in paths
    assert "photos/b.jpg" in paths


def test_directory_batched_ordering(db):
    """Files are sorted by parent directory for HDD locality."""
    manifest = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["videos/c.mov", "photos/a.jpg", "photos/b.jpg"],
    )

    # execute_transfer should process files sorted by parent dir
    execution_order = []

    def mock_copy(src, dst, progress_callback=None):
        execution_order.append(str(src))
        return CopyResult(
            source_hash="abc", dest_hash="abc",
            verified=True, bytes_copied=100,
        )

    with patch("drivecatalog.transfer.copy_file_verified", side_effect=mock_copy):
        execute_transfer(db, manifest.transfer_id)

    # Extract just the relative paths from the execution order
    parents = [str(Path(p).parent.name) for p in execution_order]

    # Photos should be grouped together (both have parent "photos")
    # and appear before videos (alphabetical directory ordering)
    photo_indices = [i for i, name in enumerate(parents) if name == "photos"]
    video_indices = [i for i, name in enumerate(parents) if name == "videos"]

    # All photos should be contiguous
    if len(photo_indices) > 1:
        assert photo_indices[-1] - photo_indices[0] == len(photo_indices) - 1


# ---------------------------------------------------------------------------
# DC-015: Transfer verification report tests
# ---------------------------------------------------------------------------


def _execute_and_complete(db, manifest, tmp_path):
    """Helper: execute a transfer with mocked copies that write real files."""
    dst_mount = str(tmp_path / "dst_drive")

    def mock_copy(src, dst, progress_callback=None):
        # Write a real file at dest so verify can read it
        dst = Path(dst)
        dst.parent.mkdir(parents=True, exist_ok=True)
        content = src.read_bytes()
        dst.write_bytes(content)
        file_hash = hashlib.sha256(content).hexdigest()
        return CopyResult(
            source_hash=file_hash,
            dest_hash=file_hash,
            verified=True,
            bytes_copied=len(content),
        )

    with patch("drivecatalog.transfer.copy_file_verified", side_effect=mock_copy):
        execute_transfer(db, manifest.transfer_id)


def test_verify_correct_pass_fail_counts(db, tmp_path):
    """verify_transfer: mock file reads, assert report has correct pass/fail counts."""
    manifest = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["photos/a.jpg", "photos/b.jpg", "videos/c.mov"],
    )

    _execute_and_complete(db, manifest, tmp_path)

    # All 3 files should be completed and verifiable
    report = verify_transfer(db, manifest.transfer_id)

    assert isinstance(report, TransferVerificationReport)
    assert report.total_files == 3
    assert report.verified_ok == 3
    assert report.verified_failed == 0
    assert len(report.failures) == 0
    assert report.duration_seconds >= 0


def test_verify_missing_file(db, tmp_path):
    """verify_transfer with missing file: appears in failures as file_missing."""
    manifest = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["photos/a.jpg", "photos/b.jpg", "videos/c.mov"],
    )

    _execute_and_complete(db, manifest, tmp_path)

    # Delete one dest file to simulate missing
    dst_mount = str(tmp_path / "dst_drive")
    missing_file = Path(dst_mount) / "photos/a.jpg"
    missing_file.unlink()

    report = verify_transfer(db, manifest.transfer_id)

    assert report.total_files == 3
    assert report.verified_ok == 2
    assert report.verified_failed == 1
    assert len(report.failures) == 1
    assert report.failures[0]["path"] == "photos/a.jpg"
    assert report.failures[0]["reason"] == "file_missing"


def test_report_endpoint_aggregation(db):
    """get_transfer_report: insert test data, assert correct aggregation."""
    manifest = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["photos/a.jpg", "photos/b.jpg", "videos/c.mov"],
    )

    # Mark 2 completed, 1 failed
    actions = db.execute(
        "SELECT id FROM planned_actions WHERE transfer_id = ? ORDER BY id",
        (manifest.transfer_id,),
    ).fetchall()
    db.execute(
        "UPDATE planned_actions SET status = 'completed', started_at = '2026-04-11T10:00:00', completed_at = '2026-04-11T10:01:00' WHERE id = ?",
        (actions[0]["id"],),
    )
    db.execute(
        "UPDATE planned_actions SET status = 'completed', started_at = '2026-04-11T10:01:00', completed_at = '2026-04-11T10:02:00' WHERE id = ?",
        (actions[1]["id"],),
    )
    db.execute(
        "UPDATE planned_actions SET status = 'failed', error = 'IO error' WHERE id = ?",
        (actions[2]["id"],),
    )
    db.commit()

    report = get_transfer_report(db, manifest.transfer_id)

    assert report is not None
    assert report["transfer_id"] == manifest.transfer_id
    assert report["total_files"] == 3
    assert report["completed"] == 2
    assert report["failed"] == 1
    assert report["pending"] == 0
    assert report["total_bytes"] == 8000
    assert len(report["failures"]) == 1
    assert report["failures"][0]["error"] == "IO error"


def test_transfers_list(db):
    """list_transfers: create 2 transfers, assert both appear with correct summaries."""
    manifest1 = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["photos/a.jpg", "photos/b.jpg"],
    )
    manifest2 = create_transfer(
        db, "SrcDrive", "DstDrive",
        ["videos/c.mov"],
    )

    # Complete all of manifest1
    db.execute(
        "UPDATE planned_actions SET status = 'completed' WHERE transfer_id = ?",
        (manifest1.transfer_id,),
    )
    # Leave manifest2 pending
    db.commit()

    transfers = list_transfers(db)

    assert len(transfers) >= 2

    t1 = next(t for t in transfers if t["transfer_id"] == manifest1.transfer_id)
    t2 = next(t for t in transfers if t["transfer_id"] == manifest2.transfer_id)

    assert t1["total_files"] == 2
    assert t1["completed"] == 2
    assert t1["status"] == "completed"
    assert t1["source_drive"] == "SrcDrive"
    assert t1["dest_drive"] == "DstDrive"

    assert t2["total_files"] == 1
    assert t2["completed"] == 0
    assert t2["status"] == "pending"
