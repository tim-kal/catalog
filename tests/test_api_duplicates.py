"""Tests for API duplicates (protection) endpoints."""


def _setup_duplicates(client):
    """Insert drives and files with duplicate hashes."""
    from drivecatalog.database import get_connection

    conn = get_connection()
    try:
        conn.execute(
            "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
            ("DriveA", "uuid-a", "/Volumes/DriveA", 1_000_000_000),
        )
        conn.execute(
            "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
            ("DriveB", "uuid-b", "/Volumes/DriveB", 1_000_000_000),
        )
        conn.commit()
        da = conn.execute("SELECT id FROM drives WHERE name = 'DriveA'").fetchone()["id"]
        db = conn.execute("SELECT id FROM drives WHERE name = 'DriveB'").fetchone()["id"]

        files = [
            (da, "video.mp4", "video.mp4", 500_000, "dup_hash_1"),
            (db, "video.mp4", "video.mp4", 500_000, "dup_hash_1"),
            (da, "unique.txt", "unique.txt", 100, "unique_hash"),
        ]
        for d_id, path, fname, size, phash in files:
            conn.execute(
                "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (d_id, path, fname, size, "2025-01-01", phash),
            )
        conn.commit()
    finally:
        conn.close()


def test_list_groups_empty(test_client):
    """GET /duplicates returns empty groups when no files."""
    resp = test_client.get("/duplicates")
    assert resp.status_code == 200
    data = resp.json()
    assert data["groups"] == []
    assert data["stats"]["total_files"] == 0


def test_list_groups_with_data(test_client):
    """GET /duplicates returns file groups with protection status."""
    _setup_duplicates(test_client)
    resp = test_client.get("/duplicates")
    assert resp.status_code == 200
    data = resp.json()
    # Should have groups for hashed files
    assert len(data["groups"]) >= 1
    # The duplicate hash should appear as a group with 2 copies
    dup_group = next((g for g in data["groups"] if g["partial_hash"] == "dup_hash_1"), None)
    assert dup_group is not None
    assert dup_group["total_copies"] == 2
    assert dup_group["drive_count"] == 2


def test_list_groups_sort_by_copies(test_client):
    """GET /duplicates?sort_by=copies works."""
    _setup_duplicates(test_client)
    resp = test_client.get("/duplicates?sort_by=copies")
    assert resp.status_code == 200


def test_stats(test_client):
    """GET /duplicates/stats returns protection statistics."""
    _setup_duplicates(test_client)
    resp = test_client.get("/duplicates/stats")
    assert resp.status_code == 200
    data = resp.json()
    # Should have standard ProtectionStats fields
    assert "total_files" in data
    assert "unique_hashes" in data
    assert "backup_coverage_percent" in data
    assert data["total_files"] == 3
    assert data["unique_hashes"] == 2  # dup_hash_1 + unique_hash


def test_stats_empty(test_client):
    """GET /duplicates/stats returns zeros when no files."""
    resp = test_client.get("/duplicates/stats")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total_files"] == 0
    assert data["unique_hashes"] == 0
