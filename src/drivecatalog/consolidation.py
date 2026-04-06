"""Consolidation analysis engine for DriveCatalog.

Analyzes file distribution across drives and computes optimal consolidation
strategies. Four core functions:

- get_drive_file_distribution: per-drive unique/duplicated/reclaimable breakdown
- get_consolidation_candidates: identifies drives that can be freed
- get_consolidation_strategy: optimal bin-packing assignment for a source drive
- get_consolidation_recommendations: ordered move/delete recommendations
"""

from __future__ import annotations

from collections import defaultdict
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


def get_consolidation_strategy(conn: Connection, source_drive_name: str) -> dict:
    """Produce an optimal plan for moving a source drive's unique files to other drives.

    Uses greedy largest-first bin packing: sort unique files by size descending,
    assign each to the target drive with the most remaining free space.

    Args:
        conn: SQLite connection with Row factory.
        source_drive_name: Name of the drive to consolidate away from.

    Returns:
        Dict with source_drive, assignments, unplaceable files, feasibility flag,
        and target drive capacity impact.

    Raises:
        ValueError: If source_drive_name is not found in the database.
    """
    # 1. Look up the source drive
    drive_row = conn.execute(
        "SELECT id, name FROM drives WHERE name = ?", (source_drive_name,)
    ).fetchone()
    if not drive_row:
        raise ValueError(f"Drive not found: {source_drive_name!r}")
    source_drive_id = drive_row["id"]

    # 2. Get all unique files on the source drive:
    #    - partial_hash IS NULL (unhashed -- can't confirm duplicated)
    #    - OR partial_hash has COUNT(DISTINCT drive_id) = 1 (only on this drive)
    unique_files_query = """
        WITH hash_drive_counts AS (
            SELECT partial_hash, COUNT(DISTINCT drive_id) as drive_count
            FROM files
            WHERE partial_hash IS NOT NULL
            GROUP BY partial_hash
        )
        SELECT f.path, f.size_bytes, f.partial_hash
        FROM files f
        LEFT JOIN hash_drive_counts hdc ON f.partial_hash = hdc.partial_hash
        WHERE f.drive_id = ?
          AND (f.partial_hash IS NULL OR hdc.drive_count = 1)
        ORDER BY f.size_bytes DESC
    """
    unique_file_rows = conn.execute(unique_files_query, (source_drive_id,)).fetchall()

    unique_files = [
        {
            "path": row["path"],
            "size_bytes": row["size_bytes"],
            "partial_hash": row["partial_hash"],
        }
        for row in unique_file_rows
    ]

    total_unique_files = len(unique_files)
    total_unique_bytes = sum(f["size_bytes"] for f in unique_files)

    # 3. Early exit: no unique files
    if total_unique_files == 0:
        return {
            "source_drive": source_drive_name,
            "total_unique_files": 0,
            "total_unique_bytes": 0,
            "total_bytes_to_transfer": 0,
            "is_feasible": True,
            "assignments": [],
            "unplaceable": [],
            "target_drives": [],
        }

    # 4. Get available target drives (other drives with known capacity and free space)
    target_query = """
        SELECT id, name, total_bytes, used_bytes,
               (total_bytes - used_bytes) as free_bytes
        FROM drives
        WHERE id != ?
          AND total_bytes IS NOT NULL
          AND used_bytes IS NOT NULL
          AND (total_bytes - used_bytes) > 0
        ORDER BY (total_bytes - used_bytes) DESC
    """
    target_rows = conn.execute(target_query, (source_drive_id,)).fetchall()

    # Track mutable remaining capacity per target
    targets = [
        {
            "drive_name": row["name"],
            "capacity_bytes": row["total_bytes"],
            "free_before": row["free_bytes"],
            "remaining": row["free_bytes"],
        }
        for row in target_rows
    ]

    # 5. No available targets: everything is unplaceable
    if not targets:
        return {
            "source_drive": source_drive_name,
            "total_unique_files": total_unique_files,
            "total_unique_bytes": total_unique_bytes,
            "total_bytes_to_transfer": 0,
            "is_feasible": False,
            "assignments": [],
            "unplaceable": unique_files,
            "target_drives": [],
        }

    # 6. Greedy bin-packing: largest files first, most-free-space target first
    # Assignments keyed by target drive name
    assignment_map: dict[str, list[dict]] = {t["drive_name"]: [] for t in targets}
    unplaceable: list[dict] = []

    for file in unique_files:
        # Re-sort targets by remaining space (descending) before each assignment
        targets.sort(key=lambda t: t["remaining"], reverse=True)

        placed = False
        for target in targets:
            if target["remaining"] >= file["size_bytes"]:
                assignment_map[target["drive_name"]].append(file)
                target["remaining"] -= file["size_bytes"]
                placed = True
                break

        if not placed:
            unplaceable.append(file)

    # 7. Build result
    assignments = []
    for target in targets:
        files = assignment_map[target["drive_name"]]
        if files:
            assignments.append({
                "target_drive": target["drive_name"],
                "file_count": len(files),
                "total_bytes": sum(f["size_bytes"] for f in files),
                "files": files,
            })

    total_bytes_to_transfer = sum(a["total_bytes"] for a in assignments)

    target_drives_info = [
        {
            "drive_name": t["drive_name"],
            "capacity_bytes": t["capacity_bytes"],
            "free_before": t["free_before"],
            "free_after": t["remaining"],
        }
        for t in targets
    ]

    return {
        "source_drive": source_drive_name,
        "total_unique_files": total_unique_files,
        "total_unique_bytes": total_unique_bytes,
        "total_bytes_to_transfer": total_bytes_to_transfer,
        "is_feasible": len(unplaceable) == 0,
        "assignments": assignments,
        "unplaceable": unplaceable,
        "target_drives": target_drives_info,
    }


# Minimum free bytes to leave on a target drive after a recommended move.
# 1 GB or 10% of capacity, whichever is smaller.
_MIN_FREE_BYTES = 1_073_741_824  # 1 GB
_MIN_FREE_PCT = 0.10


def _safe_free_limit(capacity_bytes: int | None) -> int:
    """Return the minimum free bytes a target drive should keep."""
    if capacity_bytes is None or capacity_bytes <= 0:
        return _MIN_FREE_BYTES
    return min(_MIN_FREE_BYTES, int(capacity_bytes * _MIN_FREE_PCT))


def get_consolidation_recommendations(conn: Connection) -> list[dict]:
    """Generate an ordered list of advisory move/delete recommendations.

    Considers three sources of reclaimable space:
    1. Full duplicate folders — every file in the folder exists on another drive.
    2. Subset folders — folder A's files are a strict subset of folder B's.
    3. Consolidation candidates — drives whose unique files can be moved elsewhere.

    Each recommendation contains:
        source_drive, target_drive, folder_path, size_bytes,
        space_freed_after, reason

    Results are sorted by space_freed_after descending.
    Recommendations that would fill the target drive beyond the safety margin
    are excluded.
    """
    # --- Build drive capacity lookup ---
    drive_rows = conn.execute(
        "SELECT id, name, total_bytes, used_bytes FROM drives"
    ).fetchall()
    drive_cap: dict[str, dict] = {}
    for dr in drive_rows:
        total = dr["total_bytes"]
        used = dr["used_bytes"]
        free = (total - used) if total is not None and used is not None else None
        drive_cap[dr["name"]] = {
            "drive_id": dr["id"],
            "total_bytes": total,
            "free_bytes": free,
        }

    # Track cumulative space committed to each target so we don't over-fill
    committed: dict[str, int] = defaultdict(int)

    def _target_has_room(target_name: str, needed_bytes: int) -> bool:
        cap = drive_cap.get(target_name)
        if cap is None or cap["free_bytes"] is None:
            return False
        effective_free = cap["free_bytes"] - committed[target_name]
        limit = _safe_free_limit(cap["total_bytes"])
        return effective_free - needed_bytes >= limit

    recommendations: list[dict] = []

    # ------------------------------------------------------------------
    # 1. Full-duplicate folders: every hashed file on source exists on
    #    at least one other drive.  Deleting frees the entire folder.
    # ------------------------------------------------------------------
    dup_folder_query = """
        WITH hash_drive_counts AS (
            SELECT partial_hash, COUNT(DISTINCT drive_id) AS drive_count
            FROM files
            WHERE partial_hash IS NOT NULL
            GROUP BY partial_hash
        ),
        folder_files AS (
            SELECT
                f.drive_id,
                d.name AS drive_name,
                CASE
                    WHEN INSTR(f.path, '/') > 0
                    THEN SUBSTR(f.path, 1, INSTR(f.path, '/') - 1)
                    ELSE '.'
                END AS folder_path,
                f.size_bytes,
                f.partial_hash,
                hdc.drive_count
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            LEFT JOIN hash_drive_counts hdc ON f.partial_hash = hdc.partial_hash
        )
        SELECT
            drive_name,
            folder_path,
            COUNT(*) AS file_count,
            SUM(size_bytes) AS total_bytes,
            -- All files are hashed AND duplicated elsewhere
            MIN(CASE WHEN partial_hash IS NOT NULL AND drive_count > 1 THEN 1 ELSE 0 END) AS all_duplicated
        FROM folder_files
        GROUP BY drive_id, drive_name, folder_path
        HAVING all_duplicated = 1 AND file_count >= 1
        ORDER BY total_bytes DESC
    """
    for row in conn.execute(dup_folder_query).fetchall():
        source = row["drive_name"]
        size = row["total_bytes"]
        # Find the best target — the drive with the most free space that already
        # holds copies (any drive except source, since files are duplicated).
        best_target = None
        for tname, tcap in sorted(
            drive_cap.items(),
            key=lambda kv: (kv[1]["free_bytes"] or 0),
            reverse=True,
        ):
            if tname == source:
                continue
            if tcap["free_bytes"] is not None and tcap["free_bytes"] > 0:
                best_target = tname
                break

        if best_target is None:
            best_target = ""  # delete-only; copies exist elsewhere

        recommendations.append({
            "source_drive": source,
            "target_drive": best_target,
            "folder_path": row["folder_path"],
            "size_bytes": size,
            "space_freed_after": size,
            "reason": f"All {row['file_count']} files already duplicated on other drives",
        })

    # ------------------------------------------------------------------
    # 2. Subset folders
    # ------------------------------------------------------------------
    from drivecatalog.folder_duplicates import get_folder_duplicates

    fd_result = get_folder_duplicates(conn)
    for pair in fd_result.get("subset_pairs", []):
        sub = pair["subset_folder"]
        sup = pair["superset_folder"]
        size = sub["total_bytes"]
        source = sub["drive_name"]
        target = sup["drive_name"]

        # Skip if source == target (same drive subset is not a cross-drive rec)
        if source == target:
            continue

        recommendations.append({
            "source_drive": source,
            "target_drive": target,
            "folder_path": sub["folder_path"],
            "size_bytes": size,
            "space_freed_after": size,
            "reason": (
                f"Subset of {target}/{sup['folder_path']} "
                f"({pair['overlap_percent']:.0f}% overlap)"
            ),
        })

    # ------------------------------------------------------------------
    # 3. Consolidation candidate drives (unique files can be moved)
    # ------------------------------------------------------------------
    candidates = get_consolidation_candidates(conn)
    for cand in candidates:
        if not cand["is_candidate"]:
            continue
        source = cand["drive_name"]
        unique_bytes = cand["unique_size_bytes"]
        if unique_bytes <= 0:
            continue

        # Pick the target with most free space
        targets = cand["target_drives"]
        if not targets:
            continue
        best = targets[0]  # already sorted by free_bytes desc

        recommendations.append({
            "source_drive": source,
            "target_drive": best["drive_name"],
            "folder_path": "*",
            "size_bytes": unique_bytes,
            "space_freed_after": cand["total_size_bytes"],
            "reason": (
                f"Drive can be fully emptied — {cand['unique_files']} unique files "
                f"fit on {len(targets)} target drive{'s' if len(targets) != 1 else ''}"
            ),
        })

    # ------------------------------------------------------------------
    # Deduplicate: prefer the recommendation with the largest space_freed
    # for the same (source_drive, folder_path) pair.
    # ------------------------------------------------------------------
    seen: dict[tuple[str, str], int] = {}
    deduped: list[dict] = []
    for rec in sorted(recommendations, key=lambda r: r["space_freed_after"], reverse=True):
        key = (rec["source_drive"], rec["folder_path"])
        if key in seen:
            continue
        seen[key] = len(deduped)
        deduped.append(rec)

    # ------------------------------------------------------------------
    # Filter: exclude recommendations that would fill the target drive
    # ------------------------------------------------------------------
    filtered: list[dict] = []
    for rec in deduped:
        target = rec["target_drive"]
        size = rec["size_bytes"]

        # Delete-only recommendations (target == "") don't move data
        if not target:
            filtered.append(rec)
            continue

        # For consolidation recs with target_drive, check capacity
        if not _target_has_room(target, size):
            continue

        committed[target] += size
        filtered.append(rec)

    # Sort by space_freed_after descending (already mostly sorted, re-sort to be safe)
    filtered.sort(key=lambda r: r["space_freed_after"], reverse=True)

    return filtered
