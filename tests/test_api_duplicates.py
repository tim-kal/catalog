"""Tests for API duplicates endpoints."""


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


def test_list_duplicates_empty(test_client):
    """GET /duplicates returns empty when no duplicates."""
    resp = test_client.get("/duplicates")
    assert resp.status_code == 200
    data = resp.json()
    assert data["clusters"] == []
    assert data["stats"]["total_clusters"] == 0


def test_list_duplicates_with_data(test_client):
    """GET /duplicates returns clusters."""
    _setup_duplicates(test_client)
    resp = test_client.get("/duplicates")
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["clusters"]) == 1
    assert data["clusters"][0]["count"] == 2


def test_list_duplicates_sort_by_count(test_client):
    """GET /duplicates?sort_by=count works."""
    _setup_duplicates(test_client)
    resp = test_client.get("/duplicates?sort_by=count")
    assert resp.status_code == 200


def test_duplicate_stats(test_client):
    """GET /duplicates/stats returns aggregate stats."""
    _setup_duplicates(test_client)
    resp = test_client.get("/duplicates/stats")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total_clusters"] == 1
    assert data["total_duplicate_files"] == 2
    assert data["reclaimable_bytes"] == 500_000


def test_duplicate_stats_empty(test_client):
    """GET /duplicates/stats returns zeros when no duplicates."""
    resp = test_client.get("/duplicates/stats")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total_clusters"] == 0
