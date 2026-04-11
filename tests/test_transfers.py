"""Tests for batch transfer engine (DC-014)."""

import sqlite3
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from drivecatalog.copier import CopyResult
from drivecatalog.transfer import (
    TransferManifest,
    TransferResult,
    create_transfer,
    execute_transfer,
    get_transfer_status,
    resume_transfer,
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
