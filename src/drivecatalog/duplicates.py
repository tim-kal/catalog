"""Protection-aware duplicate and backup detection for DriveCatalog.

Classifies files by backup status:
- unprotected: hash exists on only 1 drive (at risk)
- backed_up: hash exists on exactly 2 drives (properly backed up)
- over_backed_up: hash exists on 3+ drives (has removable copies)

Also tracks same-drive duplicates (multiple copies on one drive = waste).
"""

from __future__ import annotations

from sqlite3 import Connection


def get_protection_stats(conn: Connection) -> dict:
    """Get system-wide protection and storage statistics.

    Returns aggregate stats about backup coverage, duplicates, and storage.
    """
    # Total files and drives
    total_files = conn.execute("SELECT COUNT(*) FROM files").fetchone()[0]
    total_drives = conn.execute("SELECT COUNT(*) FROM drives").fetchone()[0]

    # Total storage across all cataloged files
    total_bytes_row = conn.execute(
        "SELECT COALESCE(SUM(size_bytes), 0) FROM files"
    ).fetchone()
    total_storage_bytes = total_bytes_row[0]

    # Hashed vs unhashed
    hashed_files = conn.execute(
        "SELECT COUNT(*) FROM files WHERE partial_hash IS NOT NULL"
    ).fetchone()[0]
    unhashed_files = total_files - hashed_files

    # Core protection query: for each unique hash, count drives and copies
    protection_query = """
        SELECT
            COUNT(*) as unique_hashes,
            -- Unprotected: only on 1 drive
            SUM(CASE WHEN drive_count = 1 THEN 1 ELSE 0 END) as unprotected_hashes,
            SUM(CASE WHEN drive_count = 1 THEN size_bytes ELSE 0 END) as unprotected_bytes,
            -- Backed up: on exactly 2 drives
            SUM(CASE WHEN drive_count = 2 THEN 1 ELSE 0 END) as backed_up_hashes,
            SUM(CASE WHEN drive_count = 2 THEN size_bytes ELSE 0 END) as backed_up_bytes,
            -- Over-backed-up: on 3+ drives
            SUM(CASE WHEN drive_count >= 3 THEN 1 ELSE 0 END) as over_backed_up_hashes,
            SUM(CASE WHEN drive_count >= 3 THEN size_bytes ELSE 0 END) as over_backed_up_bytes,
            -- Same-drive duplicates: extra copies beyond 1 per drive
            SUM(total_copies - drive_count) as same_drive_duplicate_count,
            SUM((total_copies - drive_count) * size_bytes) as reclaimable_bytes
        FROM (
            SELECT
                partial_hash,
                size_bytes,
                COUNT(*) as total_copies,
                COUNT(DISTINCT drive_id) as drive_count
            FROM files
            WHERE partial_hash IS NOT NULL
            GROUP BY partial_hash
        )
    """
    row = conn.execute(protection_query).fetchone()

    unique_hashes = row[0] or 0
    unprotected_hashes = row[1] or 0
    backed_up_hashes = row[3] or 0
    over_backed_up_hashes = row[5] or 0
    protected_hashes = backed_up_hashes + over_backed_up_hashes

    backup_coverage = (
        (protected_hashes / unique_hashes * 100) if unique_hashes > 0 else 0
    )

    return {
        "total_drives": total_drives,
        "total_files": total_files,
        "total_storage_bytes": total_storage_bytes,
        "hashed_files": hashed_files,
        "unhashed_files": unhashed_files,
        "unique_hashes": unique_hashes,
        "unprotected_files": row[1] or 0,
        "unprotected_bytes": row[2] or 0,
        "backed_up_files": row[3] or 0,
        "backed_up_bytes": row[4] or 0,
        "over_backed_up_files": row[5] or 0,
        "over_backed_up_bytes": row[6] or 0,
        "same_drive_duplicate_count": row[7] or 0,
        "reclaimable_bytes": row[8] or 0,
        "backup_coverage_percent": round(backup_coverage, 1),
    }


def get_drive_protection_stats(conn: Connection, drive_name: str) -> dict:
    """Get protection stats scoped to a single drive."""
    drive_row = conn.execute(
        "SELECT id FROM drives WHERE name = ?", (drive_name,)
    ).fetchone()
    if not drive_row:
        return {}
    drive_id = drive_row[0]

    total_files = conn.execute(
        "SELECT COUNT(*) FROM files WHERE drive_id = ?", (drive_id,)
    ).fetchone()[0]

    total_bytes = conn.execute(
        "SELECT COALESCE(SUM(size_bytes), 0) FROM files WHERE drive_id = ?",
        (drive_id,),
    ).fetchone()[0]

    hashed_files = conn.execute(
        "SELECT COUNT(*) FROM files WHERE drive_id = ? AND partial_hash IS NOT NULL",
        (drive_id,),
    ).fetchone()[0]

    # For each hashed file on this drive, check how many OTHER drives also have it
    query = """
        SELECT
            -- Files on this drive whose hash is ONLY on this drive
            SUM(CASE WHEN global_drive_count = 1 THEN 1 ELSE 0 END)
                as unprotected_files,
            SUM(CASE WHEN global_drive_count = 1 THEN f.size_bytes ELSE 0 END)
                as unprotected_bytes,
            -- Files on this drive whose hash is on exactly 2 drives
            SUM(CASE WHEN global_drive_count = 2 THEN 1 ELSE 0 END)
                as backed_up_files,
            SUM(CASE WHEN global_drive_count = 2 THEN f.size_bytes ELSE 0 END)
                as backed_up_bytes,
            -- Files on this drive whose hash is on 3+ drives
            SUM(CASE WHEN global_drive_count >= 3 THEN 1 ELSE 0 END)
                as over_backed_up_files,
            SUM(CASE WHEN global_drive_count >= 3 THEN f.size_bytes ELSE 0 END)
                as over_backed_up_bytes
        FROM files f
        JOIN (
            SELECT partial_hash, COUNT(DISTINCT drive_id) as global_drive_count
            FROM files
            WHERE partial_hash IS NOT NULL
            GROUP BY partial_hash
        ) hs ON f.partial_hash = hs.partial_hash
        WHERE f.drive_id = ? AND f.partial_hash IS NOT NULL
    """
    row = conn.execute(query, (drive_id,)).fetchone()

    # Same-drive duplicates on this specific drive
    dup_query = """
        SELECT
            SUM(cnt - 1) as same_drive_dupes,
            SUM((cnt - 1) * size_bytes) as reclaimable
        FROM (
            SELECT partial_hash, size_bytes, COUNT(*) as cnt
            FROM files
            WHERE drive_id = ? AND partial_hash IS NOT NULL
            GROUP BY partial_hash
            HAVING COUNT(*) > 1
        )
    """
    dup_row = conn.execute(dup_query, (drive_id,)).fetchone()

    return {
        "drive_name": drive_name,
        "total_files": total_files,
        "total_bytes": total_bytes,
        "hashed_files": hashed_files,
        "unhashed_files": total_files - hashed_files,
        "unprotected_files": row[0] or 0,
        "unprotected_bytes": row[1] or 0,
        "backed_up_files": row[2] or 0,
        "backed_up_bytes": row[3] or 0,
        "over_backed_up_files": row[4] or 0,
        "over_backed_up_bytes": row[5] or 0,
        "same_drive_duplicate_count": dup_row[0] or 0 if dup_row else 0,
        "reclaimable_bytes": dup_row[1] or 0 if dup_row else 0,
    }


def get_protection_tree(conn: Connection, drive_name: str | None = None) -> list[dict]:
    """Get protection stats grouped by drive and top-level directory.

    Returns a list of drive entries, each containing directory-level protection
    summaries. Directories are sorted by unprotected file count (most urgent first).
    """
    # Build hash stats lookup: for each hash, how many distinct drives have it
    # plus how many same-drive extras exist per drive
    drive_filter = ""
    params: list = []
    if drive_name:
        drive_filter = "WHERE d.name = ?"
        params = [drive_name]

    query = f"""
        WITH hash_stats AS (
            SELECT partial_hash,
                   COUNT(DISTINCT drive_id) as drive_count,
                   COUNT(*) as total_copies
            FROM files
            WHERE partial_hash IS NOT NULL
            GROUP BY partial_hash
        )
        SELECT
            d.name as drive_name,
            CASE
                WHEN instr(f.path, '/') > 0
                THEN substr(f.path, 1, instr(f.path, '/') - 1)
                ELSE '.'
            END as top_dir,
            COUNT(*) as total_files,
            SUM(f.size_bytes) as total_bytes,
            SUM(CASE WHEN f.partial_hash IS NULL THEN 1 ELSE 0 END) as unhashed,
            SUM(CASE WHEN hs.drive_count = 1 THEN 1 ELSE 0 END) as unprotected,
            SUM(CASE WHEN hs.drive_count = 1 THEN f.size_bytes ELSE 0 END) as unprotected_bytes,
            SUM(CASE WHEN hs.drive_count = 2 THEN 1 ELSE 0 END) as backed_up,
            SUM(CASE WHEN hs.drive_count = 2 THEN f.size_bytes ELSE 0 END) as backed_up_bytes,
            SUM(CASE WHEN hs.drive_count >= 3 THEN 1 ELSE 0 END) as over_backed_up,
            SUM(CASE WHEN hs.drive_count >= 3 THEN f.size_bytes ELSE 0 END)
                as over_backed_up_bytes
        FROM files f
        JOIN drives d ON f.drive_id = d.id
        LEFT JOIN hash_stats hs ON f.partial_hash = hs.partial_hash
        {drive_filter}
        GROUP BY d.name, top_dir
        ORDER BY d.name, unprotected DESC, total_files DESC
    """
    rows = conn.execute(query, params).fetchall()

    # Group into drive -> directories structure
    drives: dict[str, dict] = {}
    for r in rows:
        dn = r["drive_name"]
        if dn not in drives:
            drives[dn] = {
                "drive_name": dn,
                "directories": [],
                "total_files": 0,
                "total_bytes": 0,
                "unprotected_files": 0,
                "backed_up_files": 0,
                "over_backed_up_files": 0,
            }
        drv = drives[dn]
        drv["total_files"] += r["total_files"]
        drv["total_bytes"] += r["total_bytes"]
        drv["unprotected_files"] += r["unprotected"]
        drv["backed_up_files"] += r["backed_up"]
        drv["over_backed_up_files"] += r["over_backed_up"]

        drv["directories"].append({
            "path": r["top_dir"],
            "total_files": r["total_files"],
            "total_bytes": r["total_bytes"],
            "unhashed_files": r["unhashed"],
            "unprotected_files": r["unprotected"],
            "unprotected_bytes": r["unprotected_bytes"],
            "backed_up_files": r["backed_up"],
            "backed_up_bytes": r["backed_up_bytes"],
            "over_backed_up_files": r["over_backed_up"],
            "over_backed_up_bytes": r["over_backed_up_bytes"],
        })

    return list(drives.values())


def get_directory_file_groups(
    conn: Connection,
    drive_name: str,
    directory: str,
    limit: int = 200,
) -> list[dict]:
    """Get file groups within a specific directory on a specific drive.

    Returns file groups (same hash = same group) for files whose path
    starts with the given directory prefix.
    """
    path_prefix = f"{directory}/" if directory != "." else ""

    # Get all hashed files in this directory (not subdirectories) on this drive
    query = """
        SELECT f.id, f.path, f.size_bytes, f.partial_hash, d.name as drive_name
        FROM files f
        JOIN drives d ON f.drive_id = d.id
        WHERE d.name = ? AND f.partial_hash IS NOT NULL
          AND f.path LIKE ? AND f.path NOT LIKE ?
    """
    # Match files in this dir but not in subdirectories
    like_pattern = f"{path_prefix}%"
    not_like = f"{path_prefix}%/%"
    if directory == ".":
        # Root files: no slash in path
        query = """
            SELECT f.id, f.path, f.size_bytes, f.partial_hash, d.name as drive_name
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            WHERE d.name = ? AND f.partial_hash IS NOT NULL
              AND f.path NOT LIKE '%/%'
        """
        rows = conn.execute(query, (drive_name,)).fetchall()
    else:
        rows = conn.execute(query, (drive_name, like_pattern, not_like)).fetchall()

    if not rows:
        return []

    # For each unique hash found, get full cross-drive info
    hashes = {r["partial_hash"] for r in rows}
    groups = []

    for h in list(hashes)[:limit]:
        # Get all locations for this hash across all drives
        loc_rows = conn.execute(
            """
            SELECT d.name as drive_name, f.path, f.id as file_id,
                   f.catalog_bundle
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            WHERE f.partial_hash = ?
            ORDER BY d.name, f.path
            """,
            (h,),
        ).fetchall()

        size_row = conn.execute(
            "SELECT size_bytes FROM files WHERE partial_hash = ? LIMIT 1", (h,)
        ).fetchone()
        size_bytes = size_row["size_bytes"] if size_row else 0

        drive_count = len({r["drive_name"] for r in loc_rows})
        total_copies = len(loc_rows)
        same_drive_extras = total_copies - drive_count
        has_bundle = any(r["catalog_bundle"] for r in loc_rows)

        if drive_count == 1:
            status = "same_drive_duplicate" if same_drive_extras > 0 else "unprotected"
        elif drive_count == 2:
            status = "backed_up"
        else:
            status = "over_backed_up"

        # Pick representative filename
        basenames: dict[str, int] = {}
        for r in loc_rows:
            name = r["path"].rsplit("/", 1)[-1] if "/" in r["path"] else r["path"]
            basenames[name] = basenames.get(name, 0) + 1
        filename = max(basenames, key=basenames.get) if basenames else "unknown"

        reclaimable_copies = same_drive_extras
        if drive_count > 2:
            reclaimable_copies += drive_count - 2

        groups.append({
            "filename": filename,
            "partial_hash": h,
            "size_bytes": size_bytes,
            "total_copies": total_copies,
            "drive_count": drive_count,
            "status": status,
            "same_drive_extras": same_drive_extras,
            "reclaimable_bytes": reclaimable_copies * size_bytes,
            "catalog_bundle_warning": has_bundle,
            "locations": [
                {"drive_name": r["drive_name"], "path": r["path"], "file_id": r["file_id"]}
                for r in loc_rows
            ],
        })

    groups.sort(key=lambda g: g["reclaimable_bytes"], reverse=True)
    return groups


def get_file_groups(
    conn: Connection,
    status: str | None = None,
    drive_name: str | None = None,
    sort_by: str = "reclaimable",
    limit: int = 100,
) -> list[dict]:
    """Get file groups classified by protection status.

    Each group is a set of files sharing the same hash, with:
    - Representative filename
    - Protection status (unprotected, backed_up, over_backed_up)
    - Same-drive duplicate info
    - All locations

    Args:
        status: Filter by status (unprotected, backed_up, over_backed_up,
                same_drive_duplicate). None = all statuses.
        drive_name: Filter to groups containing files on this drive.
        sort_by: Sort order (reclaimable, size, copies, drive_count).
        limit: Max groups to return.
    """
    # Build the base hash summary
    hash_query = """
        SELECT
            partial_hash,
            size_bytes,
            COUNT(*) as total_copies,
            COUNT(DISTINCT drive_id) as drive_count
        FROM files
        WHERE partial_hash IS NOT NULL
        GROUP BY partial_hash
    """
    hash_rows = conn.execute(hash_query).fetchall()

    if not hash_rows:
        return []

    groups = []
    for h in hash_rows:
        partial_hash = h[0]
        size_bytes = h[1]
        total_copies = h[2]
        drive_count = h[3]
        same_drive_extras = total_copies - drive_count

        # Determine status
        if drive_count == 1:
            if same_drive_extras > 0:
                file_status = "same_drive_duplicate"
            else:
                file_status = "unprotected"
        elif drive_count == 2:
            file_status = "backed_up"
        else:
            file_status = "over_backed_up"

        # Apply status filter
        if status is not None:
            if status == "same_drive_duplicate":
                # Show any group with same-drive extras, regardless of backup status
                if same_drive_extras == 0:
                    continue
            elif status == "unprotected":
                # Only 1 drive, including same-drive dupes (still not backed up)
                if drive_count > 1:
                    continue
            elif file_status != status:
                continue

        # Get all file locations
        files_query = """
            SELECT d.name as drive_name, f.path, f.id as file_id,
                   f.catalog_bundle
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            WHERE f.partial_hash = ?
            ORDER BY d.name, f.path
        """
        file_rows = conn.execute(files_query, (partial_hash,)).fetchall()

        # Apply drive filter
        if drive_name is not None:
            if not any(r[0] == drive_name for r in file_rows):
                continue

        # Pick representative filename (most common basename)
        basenames = {}
        for r in file_rows:
            path = r[1]
            name = path.rsplit("/", 1)[-1] if "/" in path else path
            basenames[name] = basenames.get(name, 0) + 1
        filename = max(basenames, key=basenames.get) if basenames else "unknown"

        has_bundle_member = any(r["catalog_bundle"] for r in file_rows)

        locations = [
            {"drive_name": r[0], "path": r[1], "file_id": r[2]}
            for r in file_rows
        ]

        # Calculate reclaimable: same-drive extras are always reclaimable.
        # For over_backed_up (3+ drives), copies beyond 2 drives are also reclaimable.
        reclaimable_copies = same_drive_extras
        if drive_count > 2:
            reclaimable_copies += drive_count - 2
        reclaimable_bytes = reclaimable_copies * size_bytes

        groups.append({
            "filename": filename,
            "partial_hash": partial_hash,
            "size_bytes": size_bytes,
            "total_copies": total_copies,
            "drive_count": drive_count,
            "status": file_status,
            "same_drive_extras": same_drive_extras,
            "reclaimable_bytes": reclaimable_bytes,
            "catalog_bundle_warning": has_bundle_member,
            "locations": locations,
        })

    # Sort
    sort_keys = {
        "reclaimable": lambda g: g["reclaimable_bytes"],
        "size": lambda g: g["size_bytes"],
        "copies": lambda g: g["total_copies"],
        "drive_count": lambda g: g["drive_count"],
    }
    key_fn = sort_keys.get(sort_by, sort_keys["reclaimable"])
    groups.sort(key=key_fn, reverse=True)

    return groups[:limit]


# --- Legacy compatibility wrappers ---


def get_duplicate_clusters(conn: Connection) -> list[dict]:
    """Legacy: get clusters of files with matching hashes (count > 1)."""
    groups = get_file_groups(conn, limit=10000)
    clusters = []
    for g in groups:
        if g["total_copies"] <= 1:
            continue
        clusters.append({
            "partial_hash": g["partial_hash"],
            "files": [
                {"drive_name": loc["drive_name"], "path": loc["path"], "size_bytes": g["size_bytes"]}
                for loc in g["locations"]
            ],
            "count": g["total_copies"],
            "size_bytes": g["size_bytes"],
            "reclaimable_bytes": g["size_bytes"] * (g["total_copies"] - 1),
        })
    return clusters


def get_duplicate_stats(conn: Connection) -> dict:
    """Legacy: get aggregate duplicate statistics."""
    stats = get_protection_stats(conn)
    return {
        "total_clusters": stats["unique_hashes"],
        "total_duplicate_files": stats["same_drive_duplicate_count"]
            + stats["backed_up_files"]
            + stats["over_backed_up_files"],
        "total_bytes": stats["total_storage_bytes"],
        "reclaimable_bytes": stats["reclaimable_bytes"],
    }
