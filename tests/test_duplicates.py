"""Tests for duplicates module."""

from drivecatalog.duplicates import get_duplicate_clusters, get_duplicate_stats


def test_no_duplicates(tmp_db, sample_drive):
    """No duplicates returns empty list."""
    # Insert files with unique hashes
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (sample_drive["id"], "a.txt", "a.txt", 100, "2025-01-01", "unique1"),
    )
    tmp_db.execute(
        "INSERT INTO files (drive_id, path, filename, size_bytes, mtime, partial_hash) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (sample_drive["id"], "b.txt", "b.txt", 200, "2025-01-01", "unique2"),
    )
    tmp_db.commit()

    clusters = get_duplicate_clusters(tmp_db)
    assert clusters == []


def test_duplicate_detection(populated_db, tmp_db):
    """Two files with same hash are detected as duplicates."""
    clusters = get_duplicate_clusters(tmp_db)
    assert len(clusters) == 2  # hash_dup1 and hash_dup2

    hashes = {c["partial_hash"] for c in clusters}
    assert "hash_dup1" in hashes
    assert "hash_dup2" in hashes


def test_reclaimable_bytes(populated_db, tmp_db):
    """Reclaimable bytes = size * (count - 1)."""
    clusters = get_duplicate_clusters(tmp_db)
    for cluster in clusters:
        expected = cluster["size_bytes"] * (cluster["count"] - 1)
        assert cluster["reclaimable_bytes"] == expected


def test_duplicate_stats(populated_db, tmp_db):
    """Aggregate stats are correct."""
    stats = get_duplicate_stats(tmp_db)
    assert stats["total_clusters"] == 2
    assert stats["total_duplicate_files"] == 4  # 2 files * 2 clusters
    # hash_dup1: 500000 * 2 = 1000000, hash_dup2: 300000 * 2 = 600000
    assert stats["total_bytes"] == 1_600_000
    # hash_dup1: 500000 * 1 = 500000, hash_dup2: 300000 * 1 = 300000
    assert stats["reclaimable_bytes"] == 800_000


def test_no_duplicates_stats(tmp_db, sample_drive):
    """Stats with no duplicates returns zeros."""
    stats = get_duplicate_stats(tmp_db)
    assert stats["total_clusters"] == 0
    assert stats["total_duplicate_files"] == 0
    assert stats["total_bytes"] == 0
    assert stats["reclaimable_bytes"] == 0
