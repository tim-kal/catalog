"""Tests for API search endpoints."""


def _setup_data(client):
    """Insert drive and files for search testing."""
    from drivecatalog.database import get_connection

    conn = get_connection()
    try:
        conn.execute(
            "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
            ("TestDrive", "uuid-1", "/Volumes/TestDrive", 1_000_000_000),
        )
        conn.commit()
        drive_id = conn.execute("SELECT id FROM drives WHERE name = 'TestDrive'").fetchone()["id"]
        for path, fname, size in [
            ("movies/vacation.mp4", "vacation.mp4", 500_000),
            ("movies/birthday.mp4", "birthday.mp4", 300_000),
            ("photos/beach.jpg", "beach.jpg", 200_000),
        ]:
            conn.execute(
                "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) "
                "VALUES (?, ?, ?, ?, ?)",
                (drive_id, path, fname, size, "2025-06-01T12:00:00"),
            )
        conn.commit()
    finally:
        conn.close()


def test_search_basic_pattern(test_client):
    """GET /search?q=*.mp4 returns matching files."""
    _setup_data(test_client)
    resp = test_client.get("/search?q=*.mp4")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 2
    assert data["pattern"] == "*.mp4"


def test_search_with_drive_filter(test_client):
    """GET /search?q=*&drive=TestDrive filters by drive."""
    _setup_data(test_client)
    resp = test_client.get("/search?q=*&drive=TestDrive")
    assert resp.status_code == 200
    assert resp.json()["total"] == 3


def test_search_missing_query(test_client):
    """GET /search without q returns 422."""
    resp = test_client.get("/search")
    assert resp.status_code == 422


def test_search_no_results(test_client):
    """GET /search for nonexistent pattern returns empty."""
    _setup_data(test_client)
    resp = test_client.get("/search?q=*.xyz_nothing")
    assert resp.status_code == 200
    assert resp.json()["total"] == 0
