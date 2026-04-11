"""Tests for multi-signal drive recognition (DC-008)."""

import hashlib
import plistlib
from pathlib import Path
from unittest.mock import patch

import pytest

from drivecatalog.drives import (
    DriveIdentifiers,
    RecognitionResult,
    collect_drive_identifiers,
    recognize_drive,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _make_plist_bytes(data: dict) -> bytes:
    """Create a plist binary from a dict, as diskutil would return."""
    return plistlib.dumps(data)


def _make_fingerprint(total_size: int, fs_type: str, block_size: int) -> str:
    raw = f"{total_size}:{fs_type}:{block_size}"
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


@pytest.fixture()
def apfs_plist():
    """Full APFS diskutil output with all fields."""
    return {
        "VolumeUUID": "AAAA-1111-2222-3333",
        "DiskUUID": "BBBB-4444-5555-6666",
        "DeviceIdentifier": "disk2s1",
        "TotalSize": 500_000_000_000,
        "FilesystemType": "apfs",
        "VolumeAllocationBlockSize": 4096,
        "ParentWholeDisk": "disk2",
    }


@pytest.fixture()
def fat32_plist():
    """FAT32 diskutil output — no VolumeUUID."""
    return {
        "DeviceIdentifier": "disk3s1",
        "TotalSize": 32_000_000_000,
        "FilesystemType": "msdos",
        "VolumeAllocationBlockSize": 32768,
        "ParentWholeDisk": "disk3",
    }


@pytest.fixture()
def exfat_plist():
    """exFAT diskutil output — no VolumeUUID, no DiskUUID."""
    return {
        "DeviceIdentifier": "disk4s1",
        "TotalSize": 64_000_000_000,
        "FilesystemType": "exfat",
        "VolumeAllocationBlockSize": 131072,
        "ParentWholeDisk": "disk4",
    }


@pytest.fixture()
def parent_disk_plist():
    """Parent whole-disk plist with serial number."""
    return {
        "IORegistryEntryName": "USB2.0 Flash Disk SN12345",
    }


def _insert_drive(conn, name, uuid=None, mount_path=None, total_bytes=0,
                   disk_uuid=None, device_serial=None, partition_index=None,
                   fs_fingerprint=None):
    """Insert a drive row with all identifier columns."""
    conn.execute(
        """INSERT INTO drives
        (name, uuid, mount_path, total_bytes, disk_uuid, device_serial, partition_index, fs_fingerprint)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (name, uuid, mount_path, total_bytes, disk_uuid, device_serial,
         partition_index, fs_fingerprint),
    )
    conn.commit()
    return dict(conn.execute(
        "SELECT * FROM drives WHERE name = ?", (name,)
    ).fetchone())


# ---------------------------------------------------------------------------
# collect_drive_identifiers tests
# ---------------------------------------------------------------------------


class TestCollectDriveIdentifiers:
    """Test collect_drive_identifiers with mocked diskutil output."""

    def test_apfs_all_fields(self, apfs_plist, parent_disk_plist):
        """APFS drive returns all identifiers."""
        import plistlib as _plistlib

        ioreg_plist = _plistlib.dumps([{
            "Device Characteristics": {"Serial Number": "USB2.0 Flash Disk SN12345"},
            "IORegistryEntryChildren": [{"BSD Name": "disk2"}],
        }])

        def mock_run(cmd, **kwargs):
            class R:
                returncode = 0
            r = R()
            if cmd[:3] == ["diskutil", "info", "-plist"]:
                r.stdout = _make_plist_bytes(apfs_plist)
            elif cmd[:4] == ["ioreg", "-r", "-c", "IOBlockStorageDevice"]:
                r.stdout = ioreg_plist
            else:
                r.stdout = b""
            return r

        with patch("drivecatalog.drives.subprocess.run", side_effect=mock_run):
            ids = collect_drive_identifiers(Path("/Volumes/MyAPFS"))

        assert ids.volume_uuid == "AAAA-1111-2222-3333"
        assert ids.disk_uuid == "BBBB-4444-5555-6666"
        assert ids.partition_index == 1
        assert ids.fs_fingerprint is not None
        assert ids.device_serial == "USB2.0 Flash Disk SN12345"

    def test_fat32_no_volume_uuid(self, fat32_plist, parent_disk_plist):
        """FAT32 drive has no VolumeUUID but other identifiers work."""
        import plistlib as _plistlib

        ioreg_plist = _plistlib.dumps([{
            "Device Characteristics": {"Serial Number": "USB2.0 Flash Disk SN12345"},
            "IORegistryEntryChildren": [{"BSD Name": "disk3"}],
        }])

        def mock_run(cmd, **kwargs):
            class R:
                returncode = 0
            r = R()
            if cmd[:3] == ["diskutil", "info", "-plist"]:
                r.stdout = _make_plist_bytes(fat32_plist)
            elif cmd[:4] == ["ioreg", "-r", "-c", "IOBlockStorageDevice"]:
                r.stdout = ioreg_plist
            else:
                r.stdout = b""
            return r

        with patch("drivecatalog.drives.subprocess.run", side_effect=mock_run):
            ids = collect_drive_identifiers(Path("/Volumes/USBFAT"))

        assert ids.volume_uuid is None
        assert ids.disk_uuid is None
        assert ids.partition_index == 1
        assert ids.fs_fingerprint is not None
        assert ids.device_serial == "USB2.0 Flash Disk SN12345"

    def test_exfat_no_uuid_no_disk_uuid(self, exfat_plist, parent_disk_plist):
        """exFAT drive has no VolumeUUID and no DiskUUID."""
        import plistlib as _plistlib

        ioreg_plist = _plistlib.dumps([{
            "Device Characteristics": {"Serial Number": "USB2.0 Flash Disk SN12345"},
            "IORegistryEntryChildren": [{"BSD Name": "disk4"}],
        }])

        def mock_run(cmd, **kwargs):
            class R:
                returncode = 0
            r = R()
            if cmd[:3] == ["diskutil", "info", "-plist"]:
                r.stdout = _make_plist_bytes(exfat_plist)
            elif cmd[:4] == ["ioreg", "-r", "-c", "IOBlockStorageDevice"]:
                r.stdout = ioreg_plist
            else:
                r.stdout = b""
            return r

        with patch("drivecatalog.drives.subprocess.run", side_effect=mock_run):
            ids = collect_drive_identifiers(Path("/Volumes/USBexFAT"))

        assert ids.volume_uuid is None
        assert ids.disk_uuid is None
        assert ids.partition_index == 1
        assert ids.fs_fingerprint is not None

    def test_diskutil_failure_returns_empty(self):
        """If diskutil fails, return empty identifiers."""
        def mock_run(cmd, **kwargs):
            class R:
                returncode = 1
                stdout = b""
            return R()

        with patch("drivecatalog.drives.subprocess.run", side_effect=mock_run):
            ids = collect_drive_identifiers(Path("/Volumes/Broken"))

        assert ids.volume_uuid is None
        assert ids.disk_uuid is None
        assert ids.device_serial is None
        assert ids.partition_index is None
        assert ids.fs_fingerprint is None


# ---------------------------------------------------------------------------
# recognize_drive cascade tests
# ---------------------------------------------------------------------------


def _mock_collect(ids: DriveIdentifiers):
    """Return a patcher that makes collect_drive_identifiers return given ids."""
    return patch(
        "drivecatalog.drives.collect_drive_identifiers",
        return_value=ids,
    )


def _mock_drive_size(size: int = 500_000_000_000):
    """Mock get_drive_size to avoid actual statvfs."""
    return patch("drivecatalog.drives.get_drive_size", return_value=size)


class TestRecognizeDriveCascade:
    """Test the priority cascade in recognize_drive."""

    def test_uuid_match_wins_over_mount_path(self, tmp_db):
        """When VolumeUUID matches drive A but mount_path matches drive B, drive A wins."""
        drive_a = _insert_drive(
            tmp_db, "DriveA", uuid="UUID-A",
            mount_path="/Volumes/OldPath",
        )
        _insert_drive(
            tmp_db, "DriveB", uuid="UUID-B",
            mount_path="/Volumes/CurrentPath",
        )

        ids = DriveIdentifiers(volume_uuid="UUID-A")
        with _mock_collect(ids), _mock_drive_size():
            result = recognize_drive(tmp_db, Path("/Volumes/CurrentPath"))

        assert result.confidence == "certain"
        assert result.drive is not None
        assert result.drive["id"] == drive_a["id"]

    def test_disk_uuid_match(self, tmp_db):
        """DiskUUID match works when VolumeUUID is absent."""
        drive = _insert_drive(
            tmp_db, "DiskDrive", disk_uuid="DISKUUID-1",
        )

        ids = DriveIdentifiers(disk_uuid="DISKUUID-1")
        with _mock_collect(ids), _mock_drive_size():
            result = recognize_drive(tmp_db, Path("/Volumes/SomeDrive"))

        assert result.confidence == "certain"
        assert result.drive["id"] == drive["id"]

    def test_serial_partition_match(self, tmp_db):
        """Device serial + partition index match works."""
        drive = _insert_drive(
            tmp_db, "SerialDrive",
            device_serial="SN12345", partition_index=1,
        )

        ids = DriveIdentifiers(device_serial="SN12345", partition_index=1)
        with _mock_collect(ids), _mock_drive_size():
            result = recognize_drive(tmp_db, Path("/Volumes/X"))

        assert result.confidence == "certain"
        assert result.drive["id"] == drive["id"]

    def test_fingerprint_single_candidate_without_overlap_is_ambiguous(self, tmp_db):
        """Single FS fingerprint match without corroboration must stay ambiguous."""
        fp = _make_fingerprint(500_000_000_000, "apfs", 4096)
        _insert_drive(tmp_db, "FPDrive", fs_fingerprint=fp)

        ids = DriveIdentifiers(fs_fingerprint=fp)
        with _mock_collect(ids), _mock_drive_size():
            result = recognize_drive(tmp_db, Path("/Volumes/FP"))

        assert result.confidence == "ambiguous"
        assert result.drive is None
        assert result.candidates is not None
        assert len(result.candidates) == 1

    def test_fingerprint_multiple_candidates_ambiguous(self, tmp_db):
        """Multiple FS fingerprint matches return ambiguous with candidate list."""
        fp = _make_fingerprint(32_000_000_000, "msdos", 32768)
        _insert_drive(tmp_db, "USB1", fs_fingerprint=fp)
        _insert_drive(tmp_db, "USB2", fs_fingerprint=fp)

        ids = DriveIdentifiers(fs_fingerprint=fp)
        with _mock_collect(ids), _mock_drive_size():
            result = recognize_drive(tmp_db, Path("/Volumes/USBx"))

        assert result.confidence == "ambiguous"
        assert result.drive is None
        assert result.candidates is not None
        assert len(result.candidates) == 2

    def test_fingerprint_same_path_without_identifier_overlap_stays_ambiguous(self, tmp_db):
        """Same-path mount must not auto-reinclude a fingerprint row without overlap."""
        fp = _make_fingerprint(500_000_000_000, "apfs", 4096)
        _insert_drive(
            tmp_db,
            "FPDrive",
            mount_path="/Volumes/Samsung T7",
            fs_fingerprint=fp,
        )
        ids = DriveIdentifiers(fs_fingerprint=fp)

        with _mock_collect(ids), _mock_drive_size(), \
                patch("drivecatalog.drives.Path.exists", return_value=True):
            result = recognize_drive(tmp_db, Path("/Volumes/Samsung T7"))

        assert result.confidence == "ambiguous"
        assert result.drive is None

    def test_mount_path_only_weak(self, tmp_db):
        """mount_path-only match returns weak confidence."""
        _insert_drive(
            tmp_db, "PathDrive",
            mount_path="/Volumes/PathDrive",
        )

        ids = DriveIdentifiers()  # All fields None
        with _mock_collect(ids), _mock_drive_size():
            result = recognize_drive(tmp_db, Path("/Volumes/PathDrive"))

        assert result.confidence == "weak"
        assert result.drive is not None

    def test_no_match_returns_none(self, tmp_db):
        """Unknown drive returns none confidence."""
        ids = DriveIdentifiers()
        with _mock_collect(ids), _mock_drive_size():
            result = recognize_drive(tmp_db, Path("/Volumes/Unknown"))

        assert result.confidence == "none"
        assert result.drive is None

    def test_renamed_drive_uuid_recognized_and_updated(self, tmp_db):
        """A renamed drive (different mount_path, same UUID) is recognized and DB updated."""
        drive = _insert_drive(
            tmp_db, "OldName", uuid="UUID-RENAME",
            mount_path="/Volumes/OldName",
        )

        ids = DriveIdentifiers(volume_uuid="UUID-RENAME")
        with _mock_collect(ids), _mock_drive_size():
            result = recognize_drive(tmp_db, Path("/Volumes/NewName"))

        assert result.confidence == "certain"
        assert result.drive["id"] == drive["id"]

        # Verify DB was updated
        row = tmp_db.execute(
            "SELECT name, mount_path FROM drives WHERE id = ?", (drive["id"],)
        ).fetchone()
        # Recognition must preserve user-assigned drive names.
        assert row["name"] == "OldName"
        assert row["mount_path"] == "/Volumes/NewName"

    def test_identifiers_updated_on_recognition(self, tmp_db):
        """On recognition, all stored identifiers are updated."""
        drive = _insert_drive(
            tmp_db, "UpdateMe", uuid="UUID-UPD",
        )

        ids = DriveIdentifiers(
            volume_uuid="UUID-UPD",
            disk_uuid="NEW-DISK-UUID",
            device_serial="NEW-SERIAL",
            partition_index=2,
            fs_fingerprint="abcdef0123456789",
        )
        with _mock_collect(ids), _mock_drive_size():
            recognize_drive(tmp_db, Path("/Volumes/UpdateMe"))

        row = tmp_db.execute(
            "SELECT disk_uuid, device_serial, partition_index, fs_fingerprint FROM drives WHERE id = ?",
            (drive["id"],),
        ).fetchone()
        assert row["disk_uuid"] == "NEW-DISK-UUID"
        assert row["device_serial"] == "NEW-SERIAL"
        assert row["partition_index"] == 2
        assert row["fs_fingerprint"] == "abcdef0123456789"
