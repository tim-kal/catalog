"""Tests for DC-002: Catalog file bundle recognition."""

import sqlite3

import pytest

from drivecatalog.duplicates import get_file_groups
from drivecatalog.scanner import (
    CATALOG_BUNDLE_EXTENSIONS,
    is_catalog_bundle_member,
)

# ---- Unit tests for is_catalog_bundle_member ----


def test_bundle_extensions_constant():
    """CATALOG_BUNDLE_EXTENSIONS contains expected extensions."""
    assert ".cocatalog" in CATALOG_BUNDLE_EXTENSIONS
    assert ".photoslibrary" in CATALOG_BUNDLE_EXTENSIONS
    assert ".RDC" in CATALOG_BUNDLE_EXTENSIONS


@pytest.mark.parametrize(
    "path",
    [
        "Photos Library.photoslibrary/resources/derivatives/1234.jpg",
        "My Catalog.cocatalog/data/index.db",
        "Backup.RDC/contents/file.dat",
    ],
)
def test_bundle_member_detected(path):
    """Files inside bundle directories are detected."""
    assert is_catalog_bundle_member(path) is True


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
    """Regular files are not flagged as bundle members."""
    assert is_catalog_bundle_member(path) is False


def test_case_insensitive_extension():
    """Extension check is case-insensitive."""
    assert is_catalog_bundle_member("Lib.PHOTOSLIBRARY/data/f.jpg") is True
    assert is_catalog_bundle_member("Cat.Cocatalog/idx.db") is True
    assert is_catalog_bundle_member("Bak.rdc/f.dat") is True


def test_nested_bundle():
    """Files nested deeper inside a bundle are still detected."""
    assert is_catalog_bundle_member(
        "Photos Library.photoslibrary/resources/deep/nested/file.jpg"
    ) is True


# ---- DB migration and column tests ----


def test_catalog_bundle_column_exists(tmp_db):
    """Migration v4 adds catalog_bundle column to files table."""
    cols = {
        r[1] for r in tmp_db.execute("PRAGMA table_info(files)").fetchall()
    }
    assert "catalog_bundle" in cols


def test_catalog_bundle_default_zero(tmp_db, sample_drive):
    """New files default to catalog_bundle=0."""
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) "
        "VALUES (?, ?, ?, ?, ?)",
        (sample_drive["id"], "normal/file.txt", "file.txt", 100, "2025-01-01"),
    )
    tmp_db.commit()
    row = tmp_db.execute(
        "SELECT catalog_bundle FROM files WHERE path = 'normal/file.txt'"
    ).fetchone()
    assert row[0] == 0


def test_catalog_bundle_explicit_set(tmp_db, sample_drive):
    """Files can be inserted with catalog_bundle=1."""
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, catalog_bundle) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (sample_drive["id"], "Lib.photoslibrary/f.jpg", "f.jpg", 100, "2025-01-01", 1),
    )
    tmp_db.commit()
    row = tmp_db.execute(
        "SELECT catalog_bundle FROM files WHERE path = 'Lib.photoslibrary/f.jpg'"
    ).fetchone()
    assert row[0] == 1


# ---- Data migration test ----


def test_data_migration_marks_existing_bundle_files(tmp_path, monkeypatch):
    """Data migration correctly flags existing files inside bundles."""
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
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (1, 'Photos.photoslibrary/db/index.db', 'index.db', 500, '2025-01-01')"
    )
    conn.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (1, 'normal/photo.jpg', 'photo.jpg', 200, '2025-01-01')"
    )
    conn.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (1, 'Cat.cocatalog/data/f.bin', 'f.bin', 300, '2025-01-01')"
    )
    conn.commit()

    # Run migration
    from drivecatalog.migrations import apply_migrations

    apply_migrations(conn)

    # Check results
    bundle_rows = conn.execute(
        "SELECT path, catalog_bundle FROM files ORDER BY id"
    ).fetchall()
    assert bundle_rows[0]["catalog_bundle"] == 1  # inside .photoslibrary
    assert bundle_rows[1]["catalog_bundle"] == 0  # normal file
    assert bundle_rows[2]["catalog_bundle"] == 1  # inside .cocatalog

    conn.close()


# ---- Duplicate API warning test ----


def test_file_groups_include_catalog_bundle_warning(tmp_db, sample_drive):
    """File groups with bundle members include catalog_bundle_warning=True."""
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
        (did, "Photos.photoslibrary/res/img.jpg", "img.jpg", 1000, "2025-01-01", "hash_bundle", 1),
    )
    # Same hash on backup drive (normal file)
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash, catalog_bundle) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (bid, "photos/img.jpg", "img.jpg", 1000, "2025-01-01", "hash_bundle", 0),
    )
    # A normal duplicate pair (no bundles)
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash, catalog_bundle) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (did, "docs/report.pdf", "report.pdf", 500, "2025-01-01", "hash_normal", 0),
    )
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash, catalog_bundle) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (bid, "docs/report.pdf", "report.pdf", 500, "2025-01-01", "hash_normal", 0),
    )
    tmp_db.commit()

    groups = get_file_groups(tmp_db)
    bundle_group = next(g for g in groups if g["partial_hash"] == "hash_bundle")
    normal_group = next(g for g in groups if g["partial_hash"] == "hash_normal")

    assert bundle_group["catalog_bundle_warning"] is True
    assert normal_group["catalog_bundle_warning"] is False
