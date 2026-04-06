"""Tests for consolidation recommendations endpoint (DC-004)."""

import sqlite3

import pytest

from drivecatalog.consolidation import get_consolidation_recommendations
from drivecatalog.database import init_db

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


def _add_drive(conn, name, total_bytes=10_000_000_000, used_bytes=2_000_000_000):
    conn.execute(
        "INSERT INTO drives (name, uuid, mount_path, total_bytes, used_bytes) "
        "VALUES (?, ?, ?, ?, ?)",
        (name, f"UUID-{name}", f"/Volumes/{name}", total_bytes, used_bytes),
    )
    conn.commit()
    return conn.execute("SELECT id FROM drives WHERE name = ?", (name,)).fetchone()[0]


def _add_file(conn, drive_id, path, size, phash):
    filename = path.rsplit("/", 1)[-1] if "/" in path else path
    conn.execute(INSERT_FILE, (drive_id, path, filename, size, "2025-01-01T00:00:00", phash))


class TestRecommendationsCore:
    def test_empty_db_returns_empty(self, db):
        recs = get_consolidation_recommendations(db)
        assert recs == []

    def test_full_duplicate_folder_recommended(self, db):
        """A folder whose files all exist on another drive should be recommended."""
        did_a = _add_drive(db, "DriveA")
        did_b = _add_drive(db, "DriveB")

        # DriveA has folder "photos" with 2 files
        _add_file(db, did_a, "photos/a.jpg", 500_000, "h1")
        _add_file(db, did_a, "photos/b.jpg", 300_000, "h2")

        # DriveB has same files (different paths, same hashes)
        _add_file(db, did_b, "backup/a.jpg", 500_000, "h1")
        _add_file(db, did_b, "backup/b.jpg", 300_000, "h2")
        db.commit()

        recs = get_consolidation_recommendations(db)
        assert len(recs) >= 1

        # At least one rec should reference DriveA/photos or DriveB/backup
        sources = {r["source_drive"] for r in recs}
        assert sources & {"DriveA", "DriveB"}

    def test_sorted_by_space_freed_descending(self, db):
        """Recommendations must be sorted by space_freed_after DESC."""
        did_a = _add_drive(db, "DriveA")
        did_b = _add_drive(db, "DriveB")

        # Small duplicate folder
        _add_file(db, did_a, "small/x.txt", 100, "hs")
        _add_file(db, did_b, "small/x.txt", 100, "hs")

        # Large duplicate folder
        _add_file(db, did_a, "big/y.mp4", 9_000_000, "hb")
        _add_file(db, did_b, "big/y.mp4", 9_000_000, "hb")
        db.commit()

        recs = get_consolidation_recommendations(db)
        freed_values = [r["space_freed_after"] for r in recs]
        assert freed_values == sorted(freed_values, reverse=True)

    def test_no_recommendation_that_fills_target(self, db):
        """Recommendations that would fill the target beyond safety margin are excluded."""
        # DriveA: nearly full (9.5 GB used of 10 GB)
        did_a = _add_drive(db, "DriveA", total_bytes=10_000_000_000, used_bytes=9_500_000_000)
        # DriveB: also nearly full
        did_b = _add_drive(db, "DriveB", total_bytes=10_000_000_000, used_bytes=9_900_000_000)

        # DriveA has a unique file that would need to move to DriveB
        _add_file(db, did_a, "data/big.bin", 200_000_000, "hu")
        db.commit()

        recs = get_consolidation_recommendations(db)
        # No consolidation rec should target DriveB (only 100MB free, needs 200MB)
        for r in recs:
            if r["folder_path"] == "*" and r["source_drive"] == "DriveA":
                assert r["target_drive"] != "DriveB"

    def test_recommendation_fields(self, db):
        """Each recommendation has all required fields."""
        did_a = _add_drive(db, "DriveA")
        did_b = _add_drive(db, "DriveB")

        _add_file(db, did_a, "docs/report.pdf", 1_000_000, "hr")
        _add_file(db, did_b, "docs/report.pdf", 1_000_000, "hr")
        db.commit()

        recs = get_consolidation_recommendations(db)
        assert len(recs) >= 1

        required_fields = {"source_drive", "target_drive", "folder_path", "size_bytes", "space_freed_after", "reason"}
        for rec in recs:
            assert required_fields <= set(rec.keys())
            assert isinstance(rec["size_bytes"], int)
            assert isinstance(rec["space_freed_after"], int)
            assert rec["space_freed_after"] > 0


class TestRecommendationsAPI:
    def test_endpoint_returns_200(self, test_client):
        resp = test_client.get("/consolidation/recommendations")
        assert resp.status_code == 200
        data = resp.json()
        assert "recommendations" in data
        assert "total_count" in data
        assert isinstance(data["recommendations"], list)

    def test_endpoint_with_data(self, test_client):
        from drivecatalog.database import get_connection

        conn = get_connection()
        try:
            conn.execute(
                "INSERT INTO drives (name, uuid, mount_path, total_bytes, used_bytes) "
                "VALUES (?, ?, ?, ?, ?)",
                ("DriveX", "UUID-X", "/Volumes/DriveX", 10_000_000_000, 2_000_000_000),
            )
            conn.execute(
                "INSERT INTO drives (name, uuid, mount_path, total_bytes, used_bytes) "
                "VALUES (?, ?, ?, ?, ?)",
                ("DriveY", "UUID-Y", "/Volumes/DriveY", 10_000_000_000, 1_000_000_000),
            )
            conn.execute(INSERT_FILE, (1, "vid/a.mp4", "a.mp4", 5_000_000, "2025-01-01T00:00:00", "hv"))
            conn.execute(INSERT_FILE, (2, "vid/a.mp4", "a.mp4", 5_000_000, "2025-01-01T00:00:00", "hv"))
            conn.commit()
        finally:
            conn.close()

        resp = test_client.get("/consolidation/recommendations")
        assert resp.status_code == 200
        data = resp.json()
        assert data["total_count"] >= 1
        rec = data["recommendations"][0]
        assert "source_drive" in rec
        assert "target_drive" in rec
        assert "folder_path" in rec
        assert "size_bytes" in rec
        assert "space_freed_after" in rec
        assert "reason" in rec
