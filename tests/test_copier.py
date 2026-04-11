"""Tests for copier module."""

import os
import time
from unittest.mock import patch

from drivecatalog.copier import CHUNK_SIZE, CopyResult, copy_file_verified


def test_successful_copy_verified(tmp_path):
    """Successful copy produces matching hashes."""
    src = tmp_path / "source.bin"
    dst = tmp_path / "dest" / "output.bin"
    content = b"test file content for hashing"
    src.write_bytes(content)

    result = copy_file_verified(src, dst)
    assert isinstance(result, CopyResult)
    assert result.verified is True
    assert result.source_hash == result.dest_hash
    assert result.error is None
    assert dst.read_bytes() == content


def test_bytes_copied_matches(tmp_path):
    """bytes_copied matches source file size."""
    src = tmp_path / "source.bin"
    content = b"x" * 1234
    src.write_bytes(content)
    dst = tmp_path / "dest.bin"

    result = copy_file_verified(src, dst)
    assert result.bytes_copied == 1234


def test_dest_parent_created(tmp_path):
    """Destination parent directories are created automatically."""
    src = tmp_path / "source.txt"
    src.write_text("hello")
    dst = tmp_path / "a" / "b" / "c" / "dest.txt"

    result = copy_file_verified(src, dst)
    assert result.verified is True
    assert dst.exists()


def test_missing_source_returns_error(tmp_path):
    """Missing source file returns error in CopyResult."""
    src = tmp_path / "nonexistent.bin"
    dst = tmp_path / "dest.bin"

    result = copy_file_verified(src, dst)
    assert result.verified is False
    assert result.error is not None
    assert result.bytes_copied == 0


def test_progress_callback(tmp_path):
    """progress_callback receives incremental byte counts."""
    src = tmp_path / "source.bin"
    src.write_bytes(b"A" * 200_000)
    dst = tmp_path / "dest.bin"

    progress_values = []
    result = copy_file_verified(src, dst, progress_callback=lambda b: progress_values.append(b))
    assert result.verified is True
    assert len(progress_values) > 0
    assert progress_values[-1] == 200_000


def test_large_file_copy(tmp_path):
    """Copy a file larger than chunk size."""
    src = tmp_path / "large.bin"
    content = b"Z" * (2 * 1024 * 1024 + 1)  # Larger than 1MB chunk
    src.write_bytes(content)
    dst = tmp_path / "large_dest.bin"

    result = copy_file_verified(src, dst)
    assert result.verified is True
    assert result.bytes_copied == len(content)


# --- DC-012: fsync, atomic write, 1MB buffer, metadata ---


def test_fsync_called(tmp_path):
    """fsync is called before closing the destination file."""
    src = tmp_path / "source.bin"
    src.write_bytes(b"fsync test content")
    dst = tmp_path / "dest.bin"

    with patch("os.fsync") as mock_fsync:
        result = copy_file_verified(src, dst)
    assert result.verified is True
    mock_fsync.assert_called_once()


def test_atomic_write_success(tmp_path):
    """On success, final path exists and .dctmp does not."""
    src = tmp_path / "source.bin"
    src.write_bytes(b"atomic write test")
    dst = tmp_path / "output.bin"
    tmp_file = dst.with_suffix(dst.suffix + ".dctmp")

    result = copy_file_verified(src, dst)
    assert result.verified is True
    assert dst.exists()
    assert not tmp_file.exists()


def test_atomic_write_mismatch(tmp_path):
    """On hash mismatch, .dctmp is deleted and final path does not exist."""
    src = tmp_path / "source.bin"
    src.write_bytes(b"original content")
    dst = tmp_path / "dest.bin"
    tmp_file = dst.with_suffix(dst.suffix + ".dctmp")

    real_fsync = os.fsync

    def corrupting_fsync(fd):
        real_fsync(fd)
        # Append corruption to temp file after fsync — causes hash mismatch
        with open(tmp_file, "ab") as f:
            f.write(b"CORRUPTION")

    with patch("os.fsync", side_effect=corrupting_fsync):
        result = copy_file_verified(src, dst)

    assert result.verified is False
    assert not tmp_file.exists()
    assert not dst.exists()


def test_metadata_mtime_preserved(tmp_path):
    """After copy, dest mtime matches source mtime within 1s tolerance."""
    src = tmp_path / "source.bin"
    src.write_bytes(b"metadata test")
    # Set mtime to 1 day ago
    old_time = time.time() - 86400
    os.utime(src, (old_time, old_time))
    dst = tmp_path / "dest.bin"

    result = copy_file_verified(src, dst)
    assert result.verified is True

    src_mtime = os.stat(src).st_mtime
    dst_mtime = os.stat(dst).st_mtime
    assert abs(src_mtime - dst_mtime) <= 1.0


def test_chunk_size_is_1mb():
    """Copier uses 1MB chunks for efficient large file transfer."""
    assert CHUNK_SIZE == 1 * 1024 * 1024
