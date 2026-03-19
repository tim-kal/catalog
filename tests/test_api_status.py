"""Tests for API status and health endpoints."""


def test_health_endpoint(test_client):
    """GET /health returns ok."""
    resp = test_client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_status_endpoint(test_client):
    """GET /status returns database stats."""
    resp = test_client.get("/status")
    assert resp.status_code == 200
    data = resp.json()
    assert data["initialized"] is True
    assert data["drives_count"] == 0
    assert data["files_count"] == 0
    assert "db_path" in data


def test_status_with_data(test_client):
    """GET /status reflects data after inserts."""
    from drivecatalog.database import get_connection

    conn = get_connection()
    try:
        conn.execute(
            "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
            ("D1", "uuid-1", "/Volumes/D1", 1_000_000),
        )
        conn.execute(
            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash) "
            "VALUES (1, 'f.txt', 'f.txt', 100, '2025-01-01', 'abc')",
        )
        conn.commit()
    finally:
        conn.close()

    resp = test_client.get("/status")
    data = resp.json()
    assert data["drives_count"] == 1
    assert data["files_count"] == 1
    assert data["hashed_count"] == 1
    assert data["hash_coverage_percent"] == 100.0
