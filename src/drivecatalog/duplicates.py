"""Duplicate detection queries for DriveCatalog."""

from sqlite3 import Connection


def get_duplicate_clusters(conn: Connection) -> list[dict]:
    """Get clusters of files with matching partial hashes.

    Returns files grouped by partial_hash where count > 1 (duplicates).
    Each cluster includes the files, their locations, and reclaimable space.

    Args:
        conn: SQLite database connection.

    Returns:
        List of cluster dicts, each containing:
        - partial_hash: str
        - files: list of {drive_name, path, size_bytes}
        - count: int (number of copies)
        - size_bytes: int (size of one copy)
        - reclaimable_bytes: int (size_bytes * (count - 1))

        Ordered by reclaimable_bytes DESC (most impactful first).
    """
    # First, find all partial hashes with duplicates
    hash_query = """
        SELECT partial_hash, size_bytes, COUNT(*) as count
        FROM files
        WHERE partial_hash IS NOT NULL
        GROUP BY partial_hash
        HAVING COUNT(*) > 1
        ORDER BY size_bytes * (COUNT(*) - 1) DESC
    """
    hash_rows = conn.execute(hash_query).fetchall()

    if not hash_rows:
        return []

    clusters = []
    for hash_row in hash_rows:
        partial_hash = hash_row["partial_hash"]
        size_bytes = hash_row["size_bytes"]
        count = hash_row["count"]

        # Get all files in this cluster with drive names
        files_query = """
            SELECT d.name as drive_name, f.path, f.size_bytes
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            WHERE f.partial_hash = ?
            ORDER BY d.name, f.path
        """
        file_rows = conn.execute(files_query, (partial_hash,)).fetchall()

        files = [
            {
                "drive_name": row["drive_name"],
                "path": row["path"],
                "size_bytes": row["size_bytes"],
            }
            for row in file_rows
        ]

        clusters.append({
            "partial_hash": partial_hash,
            "files": files,
            "count": count,
            "size_bytes": size_bytes,
            "reclaimable_bytes": size_bytes * (count - 1),
        })

    return clusters


def get_duplicate_stats(conn: Connection) -> dict:
    """Get aggregate statistics about duplicates.

    Args:
        conn: SQLite database connection.

    Returns:
        Dict containing:
        - total_clusters: int (number of unique duplicate groups)
        - total_duplicate_files: int (sum of all copies across all clusters)
        - total_bytes: int (sum of size_bytes * count for all clusters)
        - reclaimable_bytes: int (sum of size_bytes * (count - 1) for all clusters)
    """
    query = """
        SELECT
            COUNT(*) as total_clusters,
            SUM(file_count) as total_duplicate_files,
            SUM(size_bytes * file_count) as total_bytes,
            SUM(size_bytes * (file_count - 1)) as reclaimable_bytes
        FROM (
            SELECT partial_hash, size_bytes, COUNT(*) as file_count
            FROM files
            WHERE partial_hash IS NOT NULL
            GROUP BY partial_hash
            HAVING COUNT(*) > 1
        )
    """
    row = conn.execute(query).fetchone()

    return {
        "total_clusters": row["total_clusters"] or 0,
        "total_duplicate_files": row["total_duplicate_files"] or 0,
        "total_bytes": row["total_bytes"] or 0,
        "reclaimable_bytes": row["reclaimable_bytes"] or 0,
    }
