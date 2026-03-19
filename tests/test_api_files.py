"""Tests for API files endpoints."""


def _setup_data(client):
    """Insert drive and files for testing."""
    from drivecatalog.database import get_connection

    conn = get_connection()
    try:
        conn.execute(
            "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
            ("TestDrive", "uuid-1", "/Volumes/TestDrive", 1_000_000_000),
        )
        conn.commit()
        drive_id = conn.execute("SELECT id FROM drives WHERE name = 'TestDrive'").fetchone()["id"]

        insert_sql = (
            "INSERT INTO files (drive_id, path, filename, size_bytes, "
            "mtime, partial_hash, is_media) VALUES (?, ?, ?, ?, ?, ?, ?)"
        )
        files = [
            (drive_id, "movies/vacation.mp4", "vacation.mp4",
             500_000, "2025-06-01T12:00:00", "hash1", 1),
            (drive_id, "photos/beach.jpg", "beach.jpg",
             200_000, "2025-06-02T12:00:00", None, 0),
            (drive_id, "docs/report.pdf", "report.pdf",
             50_000, "2025-06-03T12:00:00", None, 0),
        ]
        for d_id, path, fname, size, mtime, phash, is_media in files:
            conn.execute(
                insert_sql,
                (d_id, path, fname, size, mtime, phash, is_media),
            )
        conn.commit()
        return drive_id
    finally:
        conn.close()


def test_list_files_empty(test_client):
    """GET /files returns empty when no files."""
    resp = test_client.get("/files")
    assert resp.status_code == 200
    data = resp.json()
    assert data["files"] == []
    assert data["total"] == 0


def test_list_files_populated(test_client):
    """GET /files returns files."""
    _setup_data(test_client)
    resp = test_client.get("/files")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 3


def test_list_files_drive_filter(test_client):
    """GET /files?drive=TestDrive filters by drive."""
    _setup_data(test_client)
    resp = test_client.get("/files?drive=TestDrive")
    assert resp.status_code == 200
    assert resp.json()["total"] == 3


def test_list_files_extension_filter(test_client):
    """GET /files?extension=mp4 filters by extension."""
    _setup_data(test_client)
    resp = test_client.get("/files?extension=mp4")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 1
    assert data["files"][0]["filename"] == "vacation.mp4"


def test_list_files_size_filter(test_client):
    """GET /files with size filters."""
    _setup_data(test_client)
    resp = test_client.get("/files?min_size=100000&max_size=300000")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 1  # Only beach.jpg (200000)


def test_list_files_has_hash_filter(test_client):
    """GET /files?has_hash=true filters by hash presence."""
    _setup_data(test_client)
    resp = test_client.get("/files?has_hash=true")
    assert resp.status_code == 200
    assert resp.json()["total"] == 1


def test_list_files_is_media_filter(test_client):
    """GET /files?is_media=true filters by media flag."""
    _setup_data(test_client)
    resp = test_client.get("/files?is_media=true")
    assert resp.status_code == 200
    assert resp.json()["total"] == 1


def test_list_files_pagination(test_client):
    """GET /files with pagination."""
    _setup_data(test_client)
    resp = test_client.get("/files?page=1&page_size=2")
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["files"]) == 2
    assert data["total"] == 3
    assert data["page"] == 1
    assert data["page_size"] == 2


def test_get_file_found(test_client):
    """GET /files/{id} returns file details."""
    _setup_data(test_client)
    resp = test_client.get("/files/1")
    assert resp.status_code == 200
    data = resp.json()
    assert data["id"] == 1


def test_get_file_not_found(test_client):
    """GET /files/{id} returns 404."""
    resp = test_client.get("/files/999")
    assert resp.status_code == 404


def test_get_file_media_not_found(test_client):
    """GET /files/{id}/media returns 404 for file without metadata."""
    _setup_data(test_client)
    resp = test_client.get("/files/1/media")
    assert resp.status_code == 404
