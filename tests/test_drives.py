"""Tests for drives module (mock macOS-specific calls)."""

from pathlib import Path
from unittest.mock import patch

from drivecatalog.drives import (
    get_drive_by_mount_path,
    validate_mount_path,
)


def test_validate_mount_path_valid(tmp_path):
    """Valid path under /Volumes passes validation."""
    with patch.object(Path, "exists", return_value=True), \
         patch.object(Path, "is_dir", return_value=True):
        assert validate_mount_path(Path("/Volumes/MyDrive")) is True


def test_validate_mount_path_rejects_non_volumes():
    """Paths outside /Volumes are rejected."""
    with patch.object(Path, "exists", return_value=True), \
         patch.object(Path, "is_dir", return_value=True):
        assert validate_mount_path(Path("/home/user/data")) is False


def test_validate_mount_path_nonexistent():
    """Non-existent paths are rejected."""
    assert validate_mount_path(Path("/Volumes/DoesNotExist_XYZ_123")) is False


def test_validate_mount_path_string_input():
    """String input is accepted and converted."""
    with patch.object(Path, "exists", return_value=True), \
         patch.object(Path, "is_dir", return_value=True):
        assert validate_mount_path("/Volumes/StringPath") is True


def test_get_drive_by_mount_path_found(tmp_db, sample_drive):
    """Returns drive dict when found."""
    result = get_drive_by_mount_path(tmp_db, Path("/Volumes/TestDrive"))
    assert result is not None
    assert result["name"] == "TestDrive"
    assert result["uuid"] == "AAAA-BBBB-CCCC"


def test_get_drive_by_mount_path_not_found(tmp_db, sample_drive):
    """Returns None for unknown path."""
    result = get_drive_by_mount_path(tmp_db, Path("/Volumes/Unknown"))
    assert result is None
