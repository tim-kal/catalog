"""Tests for hasher module."""


from drivecatalog.hasher import CHUNK_SIZE, compute_partial_hash


def test_small_file_hashes_entire_content(tmp_path):
    """Files < 128KB are hashed entirely."""
    f = tmp_path / "small.bin"
    content = b"hello world"
    f.write_bytes(content)
    h = compute_partial_hash(f, len(content))
    assert h is not None
    assert isinstance(h, str)
    assert len(h) == 16  # xxh64 hex digest is 16 chars


def test_large_file_partial_hash(tmp_path):
    """Files >= 128KB use first+last 64KB + size."""
    f = tmp_path / "large.bin"
    content = b"A" * CHUNK_SIZE + b"B" * CHUNK_SIZE + b"C" * CHUNK_SIZE
    f.write_bytes(content)
    h = compute_partial_hash(f, len(content))
    assert h is not None


def test_deterministic(tmp_path):
    """Same content produces the same hash."""
    f = tmp_path / "det.bin"
    content = b"deterministic content"
    f.write_bytes(content)
    h1 = compute_partial_hash(f, len(content))
    h2 = compute_partial_hash(f, len(content))
    assert h1 == h2


def test_different_content_different_hash(tmp_path):
    """Different content produces different hashes."""
    f1 = tmp_path / "a.bin"
    f2 = tmp_path / "b.bin"
    f1.write_bytes(b"content A")
    f2.write_bytes(b"content B")
    h1 = compute_partial_hash(f1, 9)
    h2 = compute_partial_hash(f2, 9)
    assert h1 != h2


def test_missing_file_returns_none(tmp_path):
    """Non-existent file returns None."""
    h = compute_partial_hash(tmp_path / "nonexistent.bin", 100)
    assert h is None


def test_large_file_different_from_small(tmp_path):
    """A large file and small file with same prefix produce different hashes."""
    small = tmp_path / "small.bin"
    large = tmp_path / "large.bin"
    prefix = b"X" * CHUNK_SIZE
    small.write_bytes(prefix)
    large.write_bytes(prefix + b"Y" * CHUNK_SIZE * 2)
    h_small = compute_partial_hash(small, len(prefix))
    h_large = compute_partial_hash(large, CHUNK_SIZE * 3)
    assert h_small != h_large
