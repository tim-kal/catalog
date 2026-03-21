"""Consolidation analysis engine for DriveCatalog.

Analyzes file distribution across drives and computes optimal consolidation
strategies. Three core functions:

- get_drive_file_distribution: per-drive unique/duplicated/reclaimable breakdown
- get_consolidation_candidates: identifies drives that can be freed
- get_consolidation_strategy: optimal bin-packing assignment for a source drive
"""

from __future__ import annotations

from sqlite3 import Connection


def get_drive_file_distribution(conn: Connection) -> list[dict]:
    """Get per-drive file distribution with unique/duplicated classification.

    For each drive, computes:
    - Total files and size
    - Unique files (partial_hash only on this drive, or unhashed)
    - Duplicated files (partial_hash exists on at least one other drive)
    - Reclaimable bytes (duplicated_size_bytes -- copies exist elsewhere)
    - Drive capacity info (total_bytes, used_bytes, free_bytes)

    Returns list of dicts, one per drive.
    """
    # CTE: for each partial_hash, count how many distinct drives have it
    query = """
        WITH hash_drive_counts AS (
            SELECT partial_hash, COUNT(DISTINCT drive_id) as drive_count
            FROM files
            WHERE partial_hash IS NOT NULL
            GROUP BY partial_hash
        )
        SELECT
            d.id as drive_id,
            d.name as drive_name,
            d.total_bytes,
            d.used_bytes,
            COUNT(*) as total_files,
            COALESCE(SUM(f.size_bytes), 0) as total_size_bytes,
            -- Unique: unhashed files OR hashed files whose hash is only on this drive
            SUM(CASE
                WHEN f.partial_hash IS NULL THEN 1
                WHEN hdc.drive_count = 1 THEN 1
                ELSE 0
            END) as unique_files,
            SUM(CASE
                WHEN f.partial_hash IS NULL THEN f.size_bytes
                WHEN hdc.drive_count = 1 THEN f.size_bytes
                ELSE 0
            END) as unique_size_bytes,
            -- Duplicated: hashed files whose hash exists on other drives
            SUM(CASE
                WHEN f.partial_hash IS NOT NULL AND hdc.drive_count > 1 THEN 1
                ELSE 0
            END) as duplicated_files,
            SUM(CASE
                WHEN f.partial_hash IS NOT NULL AND hdc.drive_count > 1 THEN f.size_bytes
                ELSE 0
            END) as duplicated_size_bytes
        FROM files f
        JOIN drives d ON f.drive_id = d.id
        LEFT JOIN hash_drive_counts hdc ON f.partial_hash = hdc.partial_hash
        GROUP BY d.id, d.name, d.total_bytes, d.used_bytes
        ORDER BY d.name
    """
    rows = conn.execute(query).fetchall()

    results = []
    for row in rows:
        total_bytes = row["total_bytes"]
        used_bytes = row["used_bytes"]
        free_bytes = (
            (total_bytes - used_bytes)
            if total_bytes is not None and used_bytes is not None
            else None
        )
        duplicated_size = row["duplicated_size_bytes"] or 0

        results.append({
            "drive_id": row["drive_id"],
            "drive_name": row["drive_name"],
            "total_files": row["total_files"],
            "total_size_bytes": row["total_size_bytes"],
            "unique_files": row["unique_files"] or 0,
            "unique_size_bytes": row["unique_size_bytes"] or 0,
            "duplicated_files": row["duplicated_files"] or 0,
            "duplicated_size_bytes": duplicated_size,
            "reclaimable_bytes": duplicated_size,
            "total_bytes": total_bytes,
            "used_bytes": used_bytes,
            "free_bytes": free_bytes,
        })

    return results


def get_consolidation_candidates(conn: Connection) -> list[dict]:
    """Identify drives whose unique files can fit on other connected drives.

    A drive is a consolidation candidate if ALL its unique files (hash only on
    that drive + unhashed files) can fit on other drives that have sufficient
    free space.

    Returns list of dicts, one per drive, each containing the drive's
    distribution stats plus is_candidate, target_drives, total_available_space.
    """
    distributions = get_drive_file_distribution(conn)

    # Build list of potential target drives (known capacity, free space > 0)
    target_pool = []
    for dist in distributions:
        if (
            dist["total_bytes"] is not None
            and dist["used_bytes"] is not None
            and dist["free_bytes"] is not None
            and dist["free_bytes"] > 0
        ):
            target_pool.append({
                "drive_id": dist["drive_id"],
                "drive_name": dist["drive_name"],
                "free_bytes": dist["free_bytes"],
            })

    results = []
    for dist in distributions:
        unique_size = dist["unique_size_bytes"]

        # Target drives: all drives with free space EXCEPT the source drive itself
        targets = [
            {"drive_name": t["drive_name"], "free_bytes": t["free_bytes"]}
            for t in target_pool
            if t["drive_id"] != dist["drive_id"]
        ]
        targets.sort(key=lambda t: t["free_bytes"], reverse=True)

        total_available = sum(t["free_bytes"] for t in targets)
        is_candidate = unique_size <= total_available

        result = dict(dist)
        result["is_candidate"] = is_candidate
        result["target_drives"] = targets
        result["total_available_space"] = total_available

        results.append(result)

    return results
