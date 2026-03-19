"""Shared test fixtures for DriveCatalog tests."""

import sqlite3
from datetime import datetime

import pytest

from drivecatalog.database import init_db

INSERT_FILES_SQL = (
    "INSERT INTO files "
    "(drive_id, path, filename, size_bytes, mtime, partial_hash) "
    "VALUES (?, ?, ?, ?, ?, ?)"
)


@pytest.fixture()
def tmp_db(tmp_path, monkeypatch):
    """Create a temporary SQLite database with schema initialized.

    Sets DRIVECATALOG_DB env var so all code uses the temp DB.
    Yields the connection, then cleans up.
    """
    db_file = tmp_path / "test_catalog.db"
    monkeypatch.setenv("DRIVECATALOG_DB", str(db_file))

    # Initialize schema
    init_db()

    conn = sqlite3.connect(str(db_file))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    yield conn
    conn.close()


@pytest.fixture()
def sample_drive(tmp_db):
    """Insert a test drive record and return its info as a dict."""
    tmp_db.execute(
        "INSERT INTO drives (name, uuid, mount_path, total_bytes) "
        "VALUES (?, ?, ?, ?)",
        ("TestDrive", "AAAA-BBBB-CCCC", "/Volumes/TestDrive", 1_000_000_000),
    )
    tmp_db.commit()
    row = tmp_db.execute(
        "SELECT * FROM drives WHERE name = 'TestDrive'"
    ).fetchone()
    return dict(row)


@pytest.fixture()
def sample_files(tmp_db, sample_drive, tmp_path):
    """Create temp files on disk and insert matching file records.

    Returns a dict with drive info, file records, and the temp directory path.
    """
    drive_id = sample_drive["id"]

    # Create a temp directory simulating a mounted drive
    drive_dir = tmp_path / "drive_mount"
    drive_dir.mkdir()

    # Create test files
    files_info = []
    for name, content in [
        ("video.mp4", b"fake mp4 content here"),
        ("photo.jpg", b"fake jpg content"),
        ("document.pdf", b"fake pdf content bytes"),
        ("subdir/nested.txt", b"nested file content"),
    ]:
        file_path = drive_dir / name
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_bytes(content)

        stat = file_path.stat()
        mtime = datetime.fromtimestamp(stat.st_mtime).isoformat()

        tmp_db.execute(
            "INSERT INTO files "
            "(drive_id, path, filename, size_bytes, mtime) "
            "VALUES (?, ?, ?, ?, ?)",
            (drive_id, name, file_path.name, len(content), mtime),
        )
        files_info.append(
            {"path": name, "filename": file_path.name, "size_bytes": len(content)}
        )

    tmp_db.commit()
    return {
        "drive": sample_drive,
        "files": files_info,
        "drive_dir": drive_dir,
    }


@pytest.fixture()
def populated_db(tmp_db, sample_drive):
    """Drive + files with some having hashes (for duplicate/search tests).

    Creates two drives with files, some sharing the same partial_hash
    to simulate duplicates.
    """
    drive_id = sample_drive["id"]

    # Add a second drive
    tmp_db.execute(
        "INSERT INTO drives (name, uuid, mount_path, total_bytes) "
        "VALUES (?, ?, ?, ?)",
        ("BackupDrive", "DDDD-EEEE-FFFF", "/Volumes/BackupDrive", 2_000_000_000),
    )
    tmp_db.commit()
    backup_drive = dict(
        tmp_db.execute(
            "SELECT * FROM drives WHERE name = 'BackupDrive'"
        ).fetchone()
    )
    bid = backup_drive["id"]

    # Files on TestDrive + BackupDrive (some duplicates)
    files_data = [
        (drive_id, "movies/vacation.mp4", "vacation.mp4",
         500_000, "2025-06-01T12:00:00", "hash_dup1"),
        (drive_id, "photos/beach.jpg", "beach.jpg",
         200_000, "2025-06-02T12:00:00", "hash_unique1"),
        (drive_id, "docs/report.pdf", "report.pdf",
         100_000, "2025-06-03T12:00:00", None),
        (drive_id, "music/song.mp3", "song.mp3",
         300_000, "2025-07-01T12:00:00", "hash_dup2"),
        (bid, "movies/vacation.mp4", "vacation.mp4",
         500_000, "2025-06-01T12:00:00", "hash_dup1"),
        (bid, "music/song.mp3", "song.mp3",
         300_000, "2025-07-01T12:00:00", "hash_dup2"),
        (bid, "photos/sunset.jpg", "sunset.jpg",
         250_000, "2025-08-01T12:00:00", "hash_unique2"),
    ]

    for drive, path, filename, size, mtime, phash in files_data:
        tmp_db.execute(INSERT_FILES_SQL, (drive, path, filename, size, mtime, phash))

    tmp_db.commit()
    return {
        "test_drive": sample_drive,
        "backup_drive": backup_drive,
    }


@pytest.fixture()
def test_client(tmp_path, monkeypatch):
    """FastAPI TestClient with a temporary database."""
    db_file = tmp_path / "api_test.db"
    monkeypatch.setenv("DRIVECATALOG_DB", str(db_file))

    from starlette.testclient import TestClient

    from drivecatalog.api.main import app

    with TestClient(app) as client:
        yield client
