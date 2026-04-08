"""Tests for API drives endpoints."""

from unittest.mock import patch

from drivecatalog.drives import DriveIdentifiers, RecognitionResult


def _insert_drive(client, name="TestDrive", mount_path="/Volumes/TestDrive"):
    """Helper to insert a drive directly into the DB via the test client's app."""
    from drivecatalog.database import get_connection

    conn = get_connection()
    try:
        conn.execute(
            "INSERT INTO drives (name, uuid, mount_path, total_bytes) VALUES (?, ?, ?, ?)",
            (name, f"uuid-{name}", mount_path, 1_000_000_000),
        )
        conn.commit()
    finally:
        conn.close()


def _insert_file(client, drive_name="TestDrive", path="video.mp4", size=1000):
    """Helper to insert a file record."""
    from drivecatalog.database import get_connection

    conn = get_connection()
    try:
        drive = conn.execute("SELECT id FROM drives WHERE name = ?", (drive_name,)).fetchone()
        conn.execute(
            "INSERT INTO files (drive_id, path, filename, size_bytes, mtime) "
            "VALUES (?, ?, ?, ?, ?)",
            (drive["id"], path, path.split("/")[-1], size, "2025-06-01T12:00:00"),
        )
        conn.commit()
    finally:
        conn.close()


def test_list_drives_empty(test_client):
    """GET /drives returns empty list when no drives."""
    resp = test_client.get("/drives")
    assert resp.status_code == 200
    data = resp.json()
    assert data["drives"] == []
    assert data["total"] == 0


def test_list_drives_populated(test_client):
    """GET /drives returns drives."""
    _insert_drive(test_client, "Drive1")
    _insert_drive(test_client, "Drive2", "/Volumes/Drive2")
    resp = test_client.get("/drives")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 2


def test_get_drive_found(test_client):
    """GET /drives/{name} returns drive details."""
    _insert_drive(test_client)
    resp = test_client.get("/drives/TestDrive")
    assert resp.status_code == 200
    data = resp.json()
    assert data["name"] == "TestDrive"
    assert data["file_count"] == 0


def test_get_drive_not_found(test_client):
    """GET /drives/{name} returns 404 for unknown drive."""
    resp = test_client.get("/drives/NonExistent")
    assert resp.status_code == 404


def test_delete_drive_success(test_client):
    """DELETE /drives/{name}?confirm=true deletes drive."""
    _insert_drive(test_client)
    resp = test_client.delete("/drives/TestDrive?confirm=true")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "deleted"


def test_delete_drive_no_confirm(test_client):
    """DELETE /drives/{name} without confirm returns 400."""
    _insert_drive(test_client)
    resp = test_client.delete("/drives/TestDrive")
    assert resp.status_code == 400


def test_delete_drive_not_found(test_client):
    """DELETE /drives/{name}?confirm=true returns 404 for unknown."""
    resp = test_client.delete("/drives/NonExistent?confirm=true")
    assert resp.status_code == 404


def test_get_drive_status(test_client):
    """GET /drives/{name}/status returns status info."""
    _insert_drive(test_client)
    _insert_file(test_client)
    resp = test_client.get("/drives/TestDrive/status")
    assert resp.status_code == 200
    data = resp.json()
    assert data["name"] == "TestDrive"
    assert data["file_count"] == 1
    assert data["hashed_count"] == 0
    assert data["hash_coverage_percent"] == 0.0


def test_get_drive_status_not_found(test_client):
    """GET /drives/{name}/status returns 404."""
    resp = test_client.get("/drives/NonExistent/status")
    assert resp.status_code == 404


def test_create_drive_success(test_client, tmp_path):
    """POST /drives creates a new drive with mocked macOS calls."""
    drive_mount = tmp_path / "FakeDrive"
    drive_mount.mkdir()

    with patch("drivecatalog.api.routes.drives.validate_mount_path", return_value=True), \
         patch("drivecatalog.api.routes.drives.get_drive_info", return_value={
             "uuid": "test-uuid-123",
             "total_bytes": 500_000_000,
             "name": "FakeDrive",
             "mount_path": str(drive_mount),
         }):
        resp = test_client.post("/drives", json={"path": str(drive_mount)})
    assert resp.status_code == 201
    data = resp.json()
    assert data["name"] == "FakeDrive"
    assert data["uuid"] == "test-uuid-123"


def test_create_drive_nonexistent_path(test_client):
    """POST /drives with non-existent path returns 404."""
    resp = test_client.post("/drives", json={"path": "/Volumes/NonExistent_XYZ_999"})
    assert resp.status_code == 404


def test_create_drive_force_new_when_ambiguous(test_client, tmp_path):
    """POST /drives?force_new=true bypasses ambiguous block and creates a new row."""
    drive_mount = tmp_path / "AmbiguousDrive"
    drive_mount.mkdir()

    fake_candidates = [{"id": 1, "name": "Old A"}, {"id": 2, "name": "Old B"}]
    with patch("drivecatalog.api.routes.drives.validate_mount_path", return_value=True), \
         patch("drivecatalog.api.routes.drives.get_drive_info", return_value={
             "uuid": "new-uuid-123",
             "total_bytes": 500_000_000,
             "name": "AmbiguousDrive",
             "mount_path": str(drive_mount),
         }), \
         patch("drivecatalog.api.routes.drives.collect_drive_identifiers", return_value=DriveIdentifiers()), \
         patch("drivecatalog.api.routes.drives.recognize_drive", return_value=RecognitionResult(
             drive=None, confidence="ambiguous", candidates=fake_candidates
         )):
        resp = test_client.post("/drives?force_new=true", json={"path": str(drive_mount)})

    assert resp.status_code == 201
    data = resp.json()
    assert data["name"] == "AmbiguousDrive"


def test_resolve_ambiguous_rejects_mismatch(test_client, tmp_path):
    """resolve-ambiguous must reject when selected drive identifiers do not overlap."""
    _insert_drive(test_client, "DriveA", "/Volumes/DriveA")

    from drivecatalog.database import get_connection
    conn = get_connection()
    try:
        conn.execute(
            """
            UPDATE drives
            SET total_bytes = ?, fs_fingerprint = ?, partition_index = ?, uuid = ?, disk_uuid = ?, device_serial = ?
            WHERE name = ?
            """,
            (1_000_000, "aaaa1111bbbb2222", 1, "UUID-A", "DISK-A", "SERIAL-A", "DriveA"),
        )
        drive_id = conn.execute("SELECT id FROM drives WHERE name = 'DriveA'").fetchone()[0]
        conn.commit()
    finally:
        conn.close()

    mount = tmp_path / "MountedB"
    mount.mkdir()
    with patch("drivecatalog.api.routes.drives.collect_drive_identifiers", return_value=DriveIdentifiers(
        volume_uuid="UUID-B",
        disk_uuid="DISK-B",
        device_serial="SERIAL-B",
        partition_index=2,
        fs_fingerprint="ffff1111eeee2222",
    )), patch("drivecatalog.api.routes.drives.get_drive_info", return_value={
        "uuid": "UUID-B",
        "total_bytes": 2_000_000,
        "name": "MountedB",
        "mount_path": str(mount),
    }):
        resp = test_client.post(
            f"/drives/resolve-ambiguous?mount_path={mount}&drive_id={drive_id}"
        )

    assert resp.status_code == 409


def test_trigger_scan_not_found(test_client):
    """POST /drives/{name}/scan returns 404 for unknown drive."""
    resp = test_client.post("/drives/NonExistent/scan")
    assert resp.status_code == 404


def test_trigger_hash_not_found(test_client):
    """POST /drives/{name}/hash returns 404 for unknown drive."""
    resp = test_client.post("/drives/NonExistent/hash")
    assert resp.status_code == 404
