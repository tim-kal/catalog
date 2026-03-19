"""Tests for scanner module."""

from drivecatalog.scanner import ScanResult, scan_drive


def test_scan_empty_directory(tmp_db, sample_drive, tmp_path):
    """Scanning empty dir returns zero counts."""
    empty_dir = tmp_path / "empty_drive"
    empty_dir.mkdir()
    result = scan_drive(sample_drive["id"], str(empty_dir), tmp_db)
    assert isinstance(result, ScanResult)
    assert result.new_files == 0
    assert result.total_scanned == 0


def test_scan_directory_with_files(tmp_db, sample_drive, tmp_path):
    """Scanning a directory with files inserts records."""
    drive_dir = tmp_path / "drive"
    drive_dir.mkdir()
    (drive_dir / "file1.txt").write_text("hello")
    (drive_dir / "file2.mp4").write_bytes(b"video data")

    result = scan_drive(sample_drive["id"], str(drive_dir), tmp_db)
    assert result.new_files == 2
    assert result.total_scanned == 2

    count = tmp_db.execute(
        "SELECT COUNT(*) FROM files WHERE drive_id = ?", (sample_drive["id"],)
    ).fetchone()[0]
    assert count == 2


def test_rescan_unchanged(tmp_db, sample_drive, tmp_path):
    """Re-scanning detects unchanged files."""
    drive_dir = tmp_path / "drive"
    drive_dir.mkdir()
    (drive_dir / "stable.txt").write_text("unchanged")

    scan_drive(sample_drive["id"], str(drive_dir), tmp_db)
    result2 = scan_drive(sample_drive["id"], str(drive_dir), tmp_db)
    assert result2.unchanged_files == 1
    assert result2.new_files == 0


def test_rescan_modified(tmp_db, sample_drive, tmp_path):
    """Re-scanning detects modified files (size change)."""
    drive_dir = tmp_path / "drive"
    drive_dir.mkdir()
    f = drive_dir / "changing.txt"
    f.write_text("original")

    scan_drive(sample_drive["id"], str(drive_dir), tmp_db)

    # Modify the file (change size)
    f.write_text("modified content that is longer")
    result2 = scan_drive(sample_drive["id"], str(drive_dir), tmp_db)
    assert result2.modified_files == 1


def test_hidden_files_skipped(tmp_db, sample_drive, tmp_path):
    """Hidden files and directories are skipped."""
    drive_dir = tmp_path / "drive"
    drive_dir.mkdir()
    (drive_dir / ".hidden_file").write_text("hidden")
    hidden_dir = drive_dir / ".hidden_dir"
    hidden_dir.mkdir()
    (hidden_dir / "inner.txt").write_text("should be skipped")
    (drive_dir / "visible.txt").write_text("visible")

    result = scan_drive(sample_drive["id"], str(drive_dir), tmp_db)
    assert result.new_files == 1  # Only visible.txt


def test_skip_directories_skipped(tmp_db, sample_drive, tmp_path):
    """System directories in SKIP_DIRECTORIES are skipped."""
    drive_dir = tmp_path / "drive"
    drive_dir.mkdir()
    skip_dir = drive_dir / ".Spotlight-V100"
    skip_dir.mkdir()
    (skip_dir / "store.db").write_text("index data")
    (drive_dir / "normal.txt").write_text("keep")

    result = scan_drive(sample_drive["id"], str(drive_dir), tmp_db)
    assert result.new_files == 1


def test_progress_callback(tmp_db, sample_drive, tmp_path):
    """Progress callback is called during scan."""
    drive_dir = tmp_path / "drive"
    drive_dir.mkdir()
    (drive_dir / "a.txt").write_text("a")

    calls = []
    scan_drive(
        sample_drive["id"],
        str(drive_dir),
        tmp_db,
        progress_callback=lambda path, stats: calls.append((path, stats)),
    )
    assert len(calls) > 0
