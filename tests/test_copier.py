"""Tests for copier module."""


from drivecatalog.copier import CopyResult, copy_file_verified


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
    content = b"Z" * (128 * 1024 + 1)
    src.write_bytes(content)
    dst = tmp_path / "large_dest.bin"

    result = copy_file_verified(src, dst)
    assert result.verified is True
    assert result.bytes_copied == len(content)
