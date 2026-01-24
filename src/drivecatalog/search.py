"""File search queries for DriveCatalog."""

from sqlite3 import Connection


def search_files(
    conn: Connection,
    pattern: str,
    *,
    drive_name: str | None = None,
    min_size: int | None = None,
    max_size: int | None = None,
    extension: str | None = None,
    limit: int = 100,
) -> list[dict]:
    """Search for files matching a pattern with optional filters.

    Args:
        conn: SQLite database connection.
        pattern: Glob-style pattern (e.g., "*.mp4", "*vacation*").
                 Wildcards: * (any chars), ? (single char).
        drive_name: Filter by drive name (exact match).
        min_size: Minimum file size in bytes.
        max_size: Maximum file size in bytes.
        extension: Filter by file extension (without dot, e.g., "mp4").
        limit: Maximum number of results (default 100).

    Returns:
        List of dicts, each containing:
        - drive_name: str
        - path: str (relative to mount point)
        - size_bytes: int
        - mtime: str (modification time)

        Ordered by mtime DESC (most recently modified first).
    """
    # Convert glob pattern to SQL LIKE pattern
    sql_pattern = pattern.replace("*", "%").replace("?", "_")

    # Build query with optional filters
    query_parts = [
        """
        SELECT d.name as drive_name, f.path, f.size_bytes, f.mtime
        FROM files f
        JOIN drives d ON f.drive_id = d.id
        WHERE f.path LIKE ?
        """
    ]
    params: list = [sql_pattern]

    if drive_name is not None:
        query_parts.append("AND d.name = ?")
        params.append(drive_name)

    if min_size is not None:
        query_parts.append("AND f.size_bytes >= ?")
        params.append(min_size)

    if max_size is not None:
        query_parts.append("AND f.size_bytes <= ?")
        params.append(max_size)

    if extension is not None:
        # Match files ending with .extension
        ext_pattern = f"%.{extension}"
        query_parts.append("AND f.path LIKE ?")
        params.append(ext_pattern)

    query_parts.append("ORDER BY f.mtime DESC")
    query_parts.append("LIMIT ?")
    params.append(limit)

    query = "\n".join(query_parts)
    rows = conn.execute(query, params).fetchall()

    return [
        {
            "drive_name": row["drive_name"],
            "path": row["path"],
            "size_bytes": row["size_bytes"],
            "mtime": row["mtime"],
        }
        for row in rows
    ]
