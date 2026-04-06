"""Tests for DC-002: Catalog file bundle recognition."""

import sqlite3

import pytest

from drivecatalog.duplicates import get_file_groups
from drivecatalog.scanner import (
    CATALOG_BUNDLE_EXTENSIONS,
    get_catalog_bundle_root,
    scan_drive,
)

# ---- Unit tests for get_catalog_bundle_root ----


def test_bundle_extensions_constant():
    """CATALOG_BUNDLE_EXTENSIONS contains expected extensions."""
    assert ".cocatalog" in CATALOG_BUNDLE_EXTENSIONS
    assert ".photoslibrary" in CATALOG_BUNDLE_EXTENSIONS
    assert ".RDC" in CATALOG_BUNDLE_EXTENSIONS
    assert ".fcpbundle" in CATALOG_BUNDLE_EXTENSIONS
    assert ".lrcat" in CATALOG_BUNDLE_EXTENSIONS
    assert ".dvr" in CATALOG_BUNDLE_EXTENSIONS


@pytest.mark.parametrize(
    "path,expected_root",
    [
        (
            "Photos Library.photoslibrary/resources/derivatives/1234.jpg",
            "Photos Library.photoslibrary",
        ),
        ("My Catalog.cocatalog/data/index.db", "My Catalog.cocatalog"),
        ("Backup.RDC/contents/file.dat", "Backup.RDC"),
        ("Project.fcpbundle/media/clip.mov", "Project.fcpbundle"),
        ("Lightroom.lrcat/previews/img.jpg", "Lightroom.lrcat"),
        ("Recording.dvr/segments/seg01.ts", "Recording.dvr"),
    ],
)
def test_bundle_member_detected(path, expected_root):
    """Files inside bundle directories return the bundle root name."""
    assert get_catalog_bundle_root(path) == expected_root


@pytest.mark.parametrize(
    "path",
    [
        "photos/beach.jpg",
        "docs/report.pdf",
        "movies/vacation.mp4",
        "top_level_file.txt",
    ],
)
def test_regular_file_not_flagged(path):
    """Regular files return None."""
    assert get_catalog_bundle_root(path) is None


def test_case_insensitive_extension():
    """Extension check is case-insensitive."""
    assert get_catalog_bundle_root("Lib.PHOTOSLIBRARY/data/f.jpg") == "Lib.PHOTOSLIBRARY"
    assert get_catalog_bundle_root("Cat.Cocatalog/idx.db") == "Cat.Cocatalog"
    assert get_catalog_bundle_root("Bak.rdc/f.dat") == "Bak.rdc"


def test_nested_bundle():
    """Files nested deeper inside a bundle are still detected."""
    result = get_catalog_bundle_root(
        "Photos Library.photoslibrary/resources/deep/nested/file.jpg"
    )
    assert result == "Photos Library.photoslibrary"


# ---- DB migration and column tests ----


def test_catalog_bundle_column_exists(tmp_db):
    """Migration adds catalog_bundle column to files table."""
    cols = {
        r[1] for r in tmp_db.execute("PRAGMA table_info(files)").fetchall()
    }
    assert "catalog_bundle" in cols


def test_catalog_bundle_default_null(tmp_db, sample_drive):
    """New files default to catalog_bundle=NULL."""
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) "
        "VALUES (?, ?, ?, ?, ?)",
        (sample_drive["id"], "normal/file.txt", "file.txt", 100, "2025-01-01"),
    )
    tmp_db.commit()
    row = tmp_db.execute(
        "SELECT catalog_bundle FROM files WHERE path = 'normal/file.txt'"
    ).fetchone()
    assert row[0] is None


def test_catalog_bundle_explicit_set(tmp_db, sample_drive):
    """Files can be inserted with catalog_bundle set to a bundle root path."""
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, catalog_bundle) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (
            sample_drive["id"],
            "Lib.photoslibrary/f.jpg",
            "f.jpg",
            100,
            "2025-01-01",
            "Lib.photoslibrary",
        ),
    )
    tmp_db.commit()
    row = tmp_db.execute(
        "SELECT catalog_bundle FROM files WHERE path = 'Lib.photoslibrary/f.jpg'"
    ).fetchone()
    assert row[0] == "Lib.photoslibrary"


# ---- Data migration test ----


def test_data_migration_marks_existing_bundle_files(tmp_path, monkeypatch):
    """Data migration correctly sets bundle root paths for existing files."""
    db_file = tmp_path / "migrate_test.db"
    conn = sqlite3.connect(str(db_file))
    conn.row_factory = sqlite3.Row

    # Create schema up to v3 manually
    conn.executescript("""
        CREATE TABLE drives (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            uuid TEXT UNIQUE,
            mount_path TEXT,
            total_bytes INTEGER,
            used_bytes INTEGER,
            first_seen TEXT NOT NULL DEFAULT (datetime('now')),
            last_scan TEXT,
            notes TEXT
        );
        CREATE TABLE files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            drive_id INTEGER NOT NULL REFERENCES drives(id),
            path TEXT NOT NULL,
            filename TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            mtime TEXT NOT NULL,
            partial_hash TEXT,
            full_hash TEXT,
            is_media INTEGER DEFAULT 0,
            first_seen TEXT NOT NULL DEFAULT (datetime('now')),
            last_verified TEXT,
            UNIQUE(drive_id, path)
        );
        CREATE TABLE schema_version (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        INSERT INTO schema_version (version) VALUES (1);
        INSERT INTO schema_version (version) VALUES (2);
        INSERT INTO schema_version (version) VALUES (3);
        INSERT INTO drives (name, uuid, mount_path) VALUES ('D1', 'uuid1', '/Volumes/D1');
    """)

    # Insert files — some inside bundles, some not
    conn.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) "
        "VALUES (1, 'Photos.photoslibrary/db/index.db', 'index.db', 500, '2025-01-01')"
    )
    conn.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) "
        "VALUES (1, 'normal/photo.jpg', 'photo.jpg', 200, '2025-01-01')"
    )
    conn.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) "
        "VALUES (1, 'Cat.cocatalog/data/f.bin', 'f.bin', 300, '2025-01-01')"
    )
    conn.commit()

    # Run migration
    from drivecatalog.migrations import apply_migrations

    apply_migrations(conn)

    # Check results — should be bundle root paths, not integers
    bundle_rows = conn.execute(
        "SELECT path, catalog_bundle FROM files ORDER BY id"
    ).fetchall()
    assert bundle_rows[0]["catalog_bundle"] == "Photos.photoslibrary"
    assert bundle_rows[1]["catalog_bundle"] is None  # normal file
    assert bundle_rows[2]["catalog_bundle"] == "Cat.cocatalog"

    conn.close()


# ---- Duplicate API: per-location catalog_bundle test ----


def test_file_groups_include_per_location_catalog_bundle(tmp_db, sample_drive):
    """File locations expose per-file catalog_bundle (path string or None)."""
    did = sample_drive["id"]

    # Add a second drive
    tmp_db.execute(
        "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
        ("Backup", "ZZZZ", "/Volumes/Backup", 1_000_000_000),
    )
    tmp_db.commit()
    bid = tmp_db.execute("SELECT id FROM drives WHERE name='Backup'").fetchone()[0]

    # File inside a bundle on drive 1 with a hash
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash, catalog_bundle) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (
            did,
            "Photos.photoslibrary/res/img.jpg",
            "img.jpg",
            1000,
            "2025-01-01",
            "hash_bundle",
            "Photos.photoslibrary",
        ),
    )
    # Same hash on backup drive (normal file)
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash, catalog_bundle) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (bid, "photos/img.jpg", "img.jpg", 1000, "2025-01-01", "hash_bundle", None),
    )
    # A normal duplicate pair (no bundles)
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash, catalog_bundle) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (did, "docs/report.pdf", "report.pdf", 500, "2025-01-01", "hash_normal", None),
    )
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash, catalog_bundle) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (bid, "docs/report.pdf", "report.pdf", 500, "2025-01-01", "hash_normal", None),
    )
    tmp_db.commit()

    groups = get_file_groups(tmp_db)
    bundle_group = next(g for g in groups if g["partial_hash"] == "hash_bundle")
    normal_group = next(g for g in groups if g["partial_hash"] == "hash_normal")

    # Bundle group: one location has catalog_bundle set, the other is None
    bundle_locs = {loc["path"]: loc["catalog_bundle"] for loc in bundle_group["locations"]}
    assert bundle_locs["Photos.photoslibrary/res/img.jpg"] == "Photos.photoslibrary"
    assert bundle_locs["photos/img.jpg"] is None

    # Normal group: no catalog_bundle on any location
    for loc in normal_group["locations"]:
        assert loc["catalog_bundle"] is None


# ---- Integration test: scan_drive with a .photoslibrary subfolder ----


def test_scan_drive_sets_catalog_bundle_path(tmp_path, monkeypatch):
    """scan_drive() populates catalog_bundle with the bundle root path for files inside bundles."""
    # Build a temp directory simulating a mounted drive with a .photoslibrary bundle
    drive_dir = tmp_path / "FakeDrive"
    bundle_dir = drive_dir / "Photos.photoslibrary" / "resources"
    bundle_dir.mkdir(parents=True)
    (bundle_dir / "thumb.jpg").write_bytes(b"fake thumbnail")
    (bundle_dir / "preview.heic").write_bytes(b"fake heic data")

    # Also create a normal (non-bundle) file
    normal_dir = drive_dir / "Documents"
    normal_dir.mkdir()
    (normal_dir / "notes.txt").write_bytes(b"some notes")

    # Set up database
    db_file = tmp_path / "integration_test.db"
    monkeypatch.setenv("DRIVECATALOG_DB", str(db_file))

    from drivecatalog.database import init_db

    init_db()

    conn = sqlite3.connect(str(db_file))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")

    # Insert drive record
    conn.execute(
        "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
        ("FakeDrive", "INT-TEST-UUID", str(drive_dir), 1_000_000_000),
    )
    conn.commit()
    drive_id = conn.execute("SELECT id FROM drives WHERE name='FakeDrive'").fetchone()[0]

    # Run scan
    result = scan_drive(drive_id, str(drive_dir), conn)

    assert result.new_files == 3
    assert result.errors == 0

    # Verify catalog_bundle values
    rows = conn.execute(
        "SELECT path, catalog_bundle FROM files WHERE drive_id = ? ORDER BY path",
        (drive_id,),
    ).fetchall()

    by_path = {r["path"]: r["catalog_bundle"] for r in rows}

    assert by_path["Documents/notes.txt"] is None
    assert by_path["Photos.photoslibrary/resources/preview.heic"] == "Photos.photoslibrary"
    assert by_path["Photos.photoslibrary/resources/thumb.jpg"] == "Photos.photoslibrary"

    conn.close()
