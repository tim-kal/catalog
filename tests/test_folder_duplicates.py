"""Tests for folder-level duplicate detection (DC-001)."""

import sqlite3

import pytest

from drivecatalog.database import init_db
from drivecatalog.folder_duplicates import get_folder_duplicates

INSERT_FILE = (
    "INSERT INTO files "
    "(drive_id, path, filename, size_bytes, mtime, partial_hash) "
    "VALUES (?, ?, ?, ?, ?, ?)"
)


@pytest.fixture()
def db(tmp_path, monkeypatch):
    db_file = tmp_path / "test.db"
    monkeypatch.setenv("DRIVECATALOG_DB", str(db_file))
    init_db()
    conn = sqlite3.connect(str(db_file))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    yield conn
    conn.close()


def _add_drive(conn, name, drive_id=None):
    conn.execute(
        "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
        (name, f"UUID-{name}", f"/Volumes/{name}", 1_000_000_000),
    )
    conn.commit()
    return conn.execute("SELECT id FROM drives WHERE name = ?", (name,)).fetchone()[0]


def _add_file(conn, drive_id, path, size, phash):
    filename = path.rsplit("/", 1)[-1] if "/" in path else path
    conn.execute(INSERT_FILE, (drive_id, path, filename, size, "2025-01-01T00:00:00", phash))


class TestExactMatch:
    def test_identical_folders_same_drive(self, db):
        did = _add_drive(db, "DriveA")
        _add_file(db, did, "folderA/a.txt", 100, "h1")
        _add_file(db, did, "folderA/b.txt", 200, "h2")
        _add_file(db, did, "folderB/x.txt", 100, "h1")
        _add_file(db, did, "folderB/y.txt", 200, "h2")
        db.commit()

        result = get_folder_duplicates(db)
        assert result["stats"]["exact_match_groups"] == 1
        group = result["exact_match_groups"][0]
        assert group["hash_count"] == 2
        paths = {f["folder_path"] for f in group["folders"]}
        assert paths == {"folderA", "folderB"}

    def test_identical_folders_cross_drive(self, db):
        d1 = _add_drive(db, "DriveA")
        d2 = _add_drive(db, "DriveB")
        _add_file(db, d1, "photos/a.jpg", 500, "ph1")
        _add_file(db, d1, "photos/b.jpg", 600, "ph2")
        _add_file(db, d2, "backup/a.jpg", 500, "ph1")
        _add_file(db, d2, "backup/b.jpg", 600, "ph2")
        db.commit()

        result = get_folder_duplicates(db)
        assert result["stats"]["exact_match_groups"] == 1
        drives = {f["drive_name"] for f in result["exact_match_groups"][0]["folders"]}
        assert drives == {"DriveA", "DriveB"}

    def test_no_match_different_hashes(self, db):
        did = _add_drive(db, "DriveA")
        _add_file(db, did, "folderA/a.txt", 100, "h1")
        _add_file(db, did, "folderB/b.txt", 200, "h2")
        db.commit()

        result = get_folder_duplicates(db)
        assert result["stats"]["exact_match_groups"] == 0


class TestSubsetDetection:
    def test_proper_subset(self, db):
        did = _add_drive(db, "DriveA")
        # small folder: h1, h2
        _add_file(db, did, "small/a.txt", 100, "h1")
        _add_file(db, did, "small/b.txt", 200, "h2")
        # big folder: h1, h2, h3
        _add_file(db, did, "big/x.txt", 100, "h1")
        _add_file(db, did, "big/y.txt", 200, "h2")
        _add_file(db, did, "big/z.txt", 300, "h3")
        db.commit()

        result = get_folder_duplicates(db)
        assert result["stats"]["subset_pairs_found"] == 1
        pair = result["subset_pairs"][0]
        assert pair["subset_folder"]["folder_path"] == "small"
        assert pair["superset_folder"]["folder_path"] == "big"
        assert pair["overlap_percent"] == pytest.approx(66.7, abs=0.1)

    def test_cross_drive_subset(self, db):
        d1 = _add_drive(db, "DriveA")
        d2 = _add_drive(db, "DriveB")
        _add_file(db, d1, "partial/a.txt", 100, "h1")
        _add_file(db, d1, "partial/b.txt", 200, "h2")
        _add_file(db, d2, "full/x.txt", 100, "h1")
        _add_file(db, d2, "full/y.txt", 200, "h2")
        _add_file(db, d2, "full/z.txt", 300, "h3")
        db.commit()

        result = get_folder_duplicates(db)
        assert result["stats"]["subset_pairs_found"] == 1
        pair = result["subset_pairs"][0]
        assert pair["subset_folder"]["drive_name"] == "DriveA"
        assert pair["superset_folder"]["drive_name"] == "DriveB"


class TestDriveIdFilter:
    def test_filter_exact_match(self, db):
        d1 = _add_drive(db, "DriveA")
        d2 = _add_drive(db, "DriveB")
        d3 = _add_drive(db, "DriveC")
        # Match between DriveA and DriveB
        _add_file(db, d1, "f/a.txt", 100, "h1")
        _add_file(db, d1, "f/b.txt", 200, "h2")
        _add_file(db, d2, "g/a.txt", 100, "h1")
        _add_file(db, d2, "g/b.txt", 200, "h2")
        # Separate match on DriveC only
        _add_file(db, d3, "x/a.txt", 100, "h3")
        _add_file(db, d3, "y/a.txt", 100, "h3")
        db.commit()

        result = get_folder_duplicates(db, drive_id=d1)
        # Should only see the DriveA/DriveB match, not DriveC
        assert result["stats"]["exact_match_groups"] == 1

    def test_filter_subset(self, db):
        d1 = _add_drive(db, "DriveA")
        d2 = _add_drive(db, "DriveB")
        _add_file(db, d1, "small/a.txt", 100, "h1")
        _add_file(db, d1, "small/b.txt", 200, "h2")
        _add_file(db, d2, "big/x.txt", 100, "h1")
        _add_file(db, d2, "big/y.txt", 200, "h2")
        _add_file(db, d2, "big/z.txt", 300, "h3")
        db.commit()

        result = get_folder_duplicates(db, drive_id=d1)
        assert result["stats"]["subset_pairs_found"] == 1


class TestEmptyAndEdgeCases:
    def test_empty_database(self, db):
        _add_drive(db, "DriveA")
        db.commit()
        result = get_folder_duplicates(db)
        assert result["stats"]["exact_match_groups"] == 0
        assert result["stats"]["subset_pairs_found"] == 0

    def test_unhashed_files_ignored(self, db):
        did = _add_drive(db, "DriveA")
        _add_file(db, did, "folderA/a.txt", 100, None)
        _add_file(db, did, "folderB/b.txt", 200, None)
        db.commit()

        result = get_folder_duplicates(db)
        assert result["stats"]["total_folders_analyzed"] == 0

    def test_root_files(self, db):
        """Files with no parent directory use '.' as folder."""
        did = _add_drive(db, "DriveA")
        _add_file(db, did, "file1.txt", 100, "h1")
        _add_file(db, did, "sub/file2.txt", 100, "h1")
        db.commit()

        result = get_folder_duplicates(db)
        # '.' and 'sub' both have h1 — exact match
        assert result["stats"]["exact_match_groups"] == 1


class TestAPIEndpoint:
    def test_get_folder_duplicates(self, tmp_path, monkeypatch):
        db_file = tmp_path / "api_test.db"
        monkeypatch.setenv("DRIVECATALOG_DB", str(db_file))

        from starlette.testclient import TestClient

        from drivecatalog.api.main import app

        with TestClient(app) as client:
            # Seed data
            conn = sqlite3.connect(str(db_file))
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA foreign_keys = ON")
            d1 = conn.execute(
                "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
                ("DriveA", "U1", "/Volumes/A", 1_000_000_000),
            ).lastrowid
            d2 = conn.execute(
                "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
                ("DriveB", "U2", "/Volumes/B", 1_000_000_000),
            ).lastrowid
            for did, folder in [(d1, "photos"), (d2, "backup")]:
                _add_file(conn, did, f"{folder}/a.jpg", 500, "ph1")
                _add_file(conn, did, f"{folder}/b.jpg", 600, "ph2")
            conn.commit()
            conn.close()

            resp = client.get("/folder-duplicates")
            assert resp.status_code == 200
            data = resp.json()
            assert data["stats"]["exact_match_groups"] == 1
            assert len(data["exact_match_groups"]) == 1
            assert data["exact_match_groups"][0]["hash_count"] == 2

    def test_get_folder_duplicates_with_drive_filter(self, tmp_path, monkeypatch):
        db_file = tmp_path / "api_test2.db"
        monkeypatch.setenv("DRIVECATALOG_DB", str(db_file))

        from starlette.testclient import TestClient

        from drivecatalog.api.main import app

        with TestClient(app) as client:
            conn = sqlite3.connect(str(db_file))
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA foreign_keys = ON")
            d1 = conn.execute(
                "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
                ("DriveA", "U1", "/Volumes/A", 1_000_000_000),
            ).lastrowid
            _add_file(conn, d1, "f/a.txt", 100, "h1")
            _add_file(conn, d1, "f/b.txt", 200, "h2")
            _add_file(conn, d1, "g/a.txt", 100, "h1")
            _add_file(conn, d1, "g/b.txt", 200, "h2")
            conn.commit()
            conn.close()

            resp = client.get(f"/folder-duplicates?drive_id={d1}")
            assert resp.status_code == 200
            data = resp.json()
            assert data["stats"]["exact_match_groups"] == 1

    def test_get_folder_duplicates_empty(self, tmp_path, monkeypatch):
        db_file = tmp_path / "api_test3.db"
        monkeypatch.setenv("DRIVECATALOG_DB", str(db_file))

        from starlette.testclient import TestClient

        from drivecatalog.api.main import app

        with TestClient(app) as client:
            resp = client.get("/folder-duplicates")
            assert resp.status_code == 200
            data = resp.json()
            assert data["stats"]["exact_match_groups"] == 0
            assert data["stats"]["subset_pairs_found"] == 0
            assert data["exact_match_groups"] == []
            assert data["subset_pairs"] == []
