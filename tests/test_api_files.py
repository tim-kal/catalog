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


def test_get_file_media_with_data(test_client):
    """GET /files/{id}/media returns metadata when present."""
    _setup_data(test_client)
    # Insert media metadata for file 1
    from drivecatalog.database import get_connection

    conn = get_connection()
    try:
        conn.execute(
            "INSERT INTO media_metadata "
            "(file_id, duration_seconds, codec_name, width, height, frame_rate, bit_rate) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (1, 120.5, "h264", 1920, 1080, "29.97", 5_000_000),
        )
        conn.commit()
    finally:
        conn.close()

    resp = test_client.get("/files/1/media")
    assert resp.status_code == 200
    data = resp.json()
    assert data["file_id"] == 1
    assert data["duration_seconds"] == 120.5
    assert data["codec_name"] == "h264"
    assert data["width"] == 1920
    assert data["height"] == 1080
    assert data["frame_rate"] == "29.97"
    assert data["bit_rate"] == 5_000_000
    assert data["integrity_errors"] is None


def test_get_file_media_nonexistent_file(test_client):
    """GET /files/{id}/media returns 404 for nonexistent file."""
    resp = test_client.get("/files/999/media")
    assert resp.status_code == 404


def test_list_files_pagination_page2(test_client):
    """GET /files page=2 returns remaining files."""
    _setup_data(test_client)
    resp = test_client.get("/files?page=2&page_size=2")
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["files"]) == 1  # 3 total, page_size=2, page 2 has 1
    assert data["total"] == 3
    assert data["page"] == 2


def test_list_files_pagination_beyond(test_client):
    """GET /files beyond last page returns empty."""
    _setup_data(test_client)
    resp = test_client.get("/files?page=100&page_size=10")
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["files"]) == 0
    assert data["total"] == 3


def test_list_files_path_prefix_filter(test_client):
    """GET /files?path_prefix=movies/ filters by directory."""
    _setup_data(test_client)
    resp = test_client.get("/files?path_prefix=movies/")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 1
    assert data["files"][0]["path"].startswith("movies/")


def test_list_files_nonexistent_drive(test_client):
    """GET /files?drive=NoSuchDrive returns empty."""
    _setup_data(test_client)
    resp = test_client.get("/files?drive=NoSuchDrive")
    assert resp.status_code == 200
    assert resp.json()["total"] == 0


def test_list_files_large_page_size(test_client):
    """GET /files with page_size=1000 (max) works."""
    _setup_data(test_client)
    resp = test_client.get("/files?page_size=1000")
    assert resp.status_code == 200
    assert resp.json()["total"] == 3


def test_list_files_page_size_over_max(test_client):
    """GET /files with page_size>1000 returns 422."""
    resp = test_client.get("/files?page_size=1001")
    assert resp.status_code == 422


def test_get_file_response_structure(test_client):
    """GET /files/{id} response has all required fields."""
    _setup_data(test_client)
    resp = test_client.get("/files/1")
    assert resp.status_code == 200
    data = resp.json()
    required_fields = ["id", "drive_id", "drive_name", "path", "filename",
                       "size_bytes", "mtime", "partial_hash", "is_media"]
    for field in required_fields:
        assert field in data, f"Missing field: {field}"


def test_list_files_has_hash_false(test_client):
    """GET /files?has_hash=false returns files without hash."""
    _setup_data(test_client)
    resp = test_client.get("/files?has_hash=false")
    assert resp.status_code == 200
    assert resp.json()["total"] == 2  # beach.jpg and report.pdf



class TestBrowseEndpoint:
    """Tests for the Finder-style /files/browse endpoint."""

    def test_browse_root_empty_drive(self, test_client, populated_db):
        """Browse root of a drive with no files at root level."""
        response = test_client.get("/files/browse", params={"drive": "TestDrive"})
        assert response.status_code == 200
        data = response.json()
        assert data["drive"] == "TestDrive"
        assert data["current_path"] == ""
        assert isinstance(data["directories"], list)
        assert isinstance(data["files"], list)

    def test_browse_nonexistent_drive(self, test_client, populated_db):
        """Browse a drive that does not exist returns 404."""
        response = test_client.get("/files/browse", params={"drive": "NoSuchDrive"})
        assert response.status_code == 404

    def test_browse_requires_drive(self, test_client, populated_db):
        """Drive parameter is required."""
        response = test_client.get("/files/browse")
        assert response.status_code == 422

    def test_browse_returns_directories_and_files(self, test_client, tmp_db):
        """Browse should separate items into directories and direct files."""
        conn = tmp_db
        conn.execute(
            "INSERT INTO drives (name, mount_path, total_bytes) VALUES (?, ?, ?)",
            ("BrowseDrive", "/mnt/browse", 0),
        )
        drive_id = conn.execute(
            "SELECT id FROM drives WHERE name=?", ("BrowseDrive",)
        ).fetchone()[0]
        conn.execute(
            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (?, ?, ?, ?, ?)",
            (drive_id, "readme.txt", "readme.txt", 100, "2026-01-01T00:00:00"),
        )
        conn.execute(
            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (?, ?, ?, ?, ?)",
            (drive_id, "Photos/img1.jpg", "img1.jpg", 5000, "2026-01-01T00:00:00"),
        )
        conn.execute(
            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (?, ?, ?, ?, ?)",
            (drive_id, "Photos/img2.jpg", "img2.jpg", 3000, "2026-01-01T00:00:00"),
        )
        conn.execute(
            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (?, ?, ?, ?, ?)",
            (drive_id, "Videos/clip.mp4", "clip.mp4", 50000, "2026-01-01T00:00:00"),
        )
        conn.commit()

        response = test_client.get("/files/browse", params={"drive": "BrowseDrive"})
        assert response.status_code == 200
        data = response.json()

        assert len(data["directories"]) == 2
        assert len(data["files"]) == 1

        dirs = {d["name"]: d for d in data["directories"]}
        assert "Photos" in dirs
        assert dirs["Photos"]["file_count"] == 2
        assert dirs["Photos"]["total_bytes"] == 8000
        assert "Videos" in dirs
        assert dirs["Videos"]["file_count"] == 1

        assert data["files"][0]["filename"] == "readme.txt"

    def test_browse_subdirectory(self, test_client, tmp_db):
        """Browse into a subdirectory shows its contents."""
        conn = tmp_db
        conn.execute(
            "INSERT INTO drives (name, mount_path, total_bytes) VALUES (?, ?, ?)",
            ("BrowseDrive2", "/mnt/browse2", 0),
        )
        drive_id = conn.execute(
            "SELECT id FROM drives WHERE name=?", ("BrowseDrive2",)
        ).fetchone()[0]
        conn.execute(
            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (?, ?, ?, ?, ?)",
            (drive_id, "Photos/2024/jan.jpg", "jan.jpg", 1000, "2026-01-01T00:00:00"),
        )
        conn.execute(
            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (?, ?, ?, ?, ?)",
            (drive_id, "Photos/2024/feb.jpg", "feb.jpg", 2000, "2026-01-01T00:00:00"),
        )
        conn.execute(
            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) VALUES (?, ?, ?, ?, ?)",
            (drive_id, "Photos/hero.jpg", "hero.jpg", 500, "2026-01-01T00:00:00"),
        )
        conn.commit()

        response = test_client.get(
            "/files/browse", params={"drive": "BrowseDrive2", "path": "Photos"}
        )
        assert response.status_code == 200
        data = response.json()

        assert data["current_path"] == "Photos"
        assert len(data["directories"]) == 1
        assert data["directories"][0]["name"] == "2024"
        assert data["directories"][0]["file_count"] == 2
        assert len(data["files"]) == 1
        assert data["files"][0]["filename"] == "hero.jpg"
