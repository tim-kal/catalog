"""Tests for search module."""

from drivecatalog.search import search_files


def test_glob_pattern_mp4(populated_db, tmp_db):
    """Pattern *.mp4 finds MP4 files."""
    results = search_files(tmp_db, "*.mp4")
    assert len(results) == 2
    assert all(r["path"].endswith(".mp4") for r in results)


def test_wildcard_name_search(populated_db, tmp_db):
    """Pattern *vacation* finds files with 'vacation' in path."""
    results = search_files(tmp_db, "*vacation*")
    assert len(results) == 2  # On both drives


def test_drive_name_filter(populated_db, tmp_db):
    """Filter by drive_name returns only that drive's files."""
    results = search_files(tmp_db, "*", drive_name="TestDrive")
    assert all(r["drive_name"] == "TestDrive" for r in results)
    assert len(results) == 4


def test_min_size_filter(populated_db, tmp_db):
    """min_size filters out smaller files."""
    results = search_files(tmp_db, "*", min_size=400_000)
    assert all(r["size_bytes"] >= 400_000 for r in results)


def test_max_size_filter(populated_db, tmp_db):
    """max_size filters out larger files."""
    results = search_files(tmp_db, "*", max_size=200_000)
    assert all(r["size_bytes"] <= 200_000 for r in results)


def test_extension_filter(populated_db, tmp_db):
    """Extension filter narrows by file type."""
    results = search_files(tmp_db, "*", extension="jpg")
    assert all(r["path"].endswith(".jpg") for r in results)


def test_limit_parameter(populated_db, tmp_db):
    """Limit parameter caps results."""
    results = search_files(tmp_db, "*", limit=2)
    assert len(results) == 2


def test_empty_result(populated_db, tmp_db):
    """Search for nonexistent pattern returns empty."""
    results = search_files(tmp_db, "*.xyz_nonexistent")
    assert results == []
