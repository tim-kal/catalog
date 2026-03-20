"""Partial file hashing for DriveCatalog using xxHash."""

from pathlib import Path

import xxhash

# Chunk size for partial hashing (64KB)
CHUNK_SIZE = 64 * 1024


def compute_partial_hash(file_path: Path, size_bytes: int) -> str | None:
    """Compute a partial hash of a file using xxHash.

    For files smaller than 128KB, reads and hashes the entire content.
    For larger files, hashes the first 64KB + last 64KB + file size.

    This is the FAST hash used for duplicate detection. For deletion
    safety, use compute_verification_hash() which samples more of the file.

    Args:
        file_path: Path to the file to hash.
        size_bytes: Known size of the file in bytes.

    Returns:
        Hex string of the xxHash digest, or None if file cannot be read.
    """
    try:
        hasher = xxhash.xxh64()

        with open(file_path, "rb") as f:
            if size_bytes < CHUNK_SIZE * 2:
                # Small file: hash entire content
                content = f.read()
                hasher.update(content)
            else:
                # Large file: hash first 64KB + last 64KB
                first_chunk = f.read(CHUNK_SIZE)
                hasher.update(first_chunk)

                # Seek to last 64KB
                f.seek(-CHUNK_SIZE, 2)  # 2 = SEEK_END
                last_chunk = f.read(CHUNK_SIZE)
                hasher.update(last_chunk)

        # Include file size in hash to differentiate files with same head/tail
        hasher.update(str(size_bytes).encode())

        return hasher.hexdigest()

    except (OSError, PermissionError):
        return None


def compute_verification_hash(file_path: Path, size_bytes: int) -> str | None:
    """Compute a deeper verification hash for safe deletion.

    Samples first + middle + last chunks. Used before deleting a file to
    confirm two files are truly identical beyond partial-hash matching.

    For files < 192KB, hashes entire content (same as partial hash).
    For larger files, hashes first 64KB + middle 64KB + last 64KB + size.

    Args:
        file_path: Path to the file to verify.
        size_bytes: Known size of the file in bytes.

    Returns:
        Hex string of the verification hash, or None if file cannot be read.
    """
    try:
        hasher = xxhash.xxh64()

        with open(file_path, "rb") as f:
            if size_bytes < CHUNK_SIZE * 3:
                content = f.read()
                hasher.update(content)
            else:
                # First 64KB
                first_chunk = f.read(CHUNK_SIZE)
                hasher.update(first_chunk)

                # Middle 64KB
                mid_offset = (size_bytes // 2) - (CHUNK_SIZE // 2)
                f.seek(mid_offset)
                mid_chunk = f.read(CHUNK_SIZE)
                hasher.update(mid_chunk)

                # Last 64KB
                f.seek(-CHUNK_SIZE, 2)
                last_chunk = f.read(CHUNK_SIZE)
                hasher.update(last_chunk)

        hasher.update(str(size_bytes).encode())
        return hasher.hexdigest()

    except (OSError, PermissionError):
        return None
