"""Folder-level duplicate and subset detection for DriveCatalog.

Identifies:
- Exact-match folders: two folders with identical file-hash sets
- Subset folders: folder A's hashes are a proper subset of folder B's

Works across drives using existing `files` table data (no re-scanning).
Uses SQL aggregation + Python set operations for performance at 100k+ files.
"""

from __future__ import annotations

from collections import defaultdict
from sqlite3 import Connection


def _extract_parent(path: str) -> str:
    """Extract parent directory from a relative file path."""
    idx = path.rfind("/")
    return path[:idx] if idx >= 0 else "."


def get_folder_duplicates(
    conn: Connection,
    drive_id: int | None = None,
) -> dict:
    """Find duplicate and subset folders across all drives.

    Args:
        conn: Database connection.
        drive_id: If set, only return groups/pairs involving this drive.

    Returns:
        dict with exact_match_groups, subset_pairs, and stats.
    """
    # Fetch all hashed files (always cross-drive for detection accuracy)
    rows = conn.execute(
        """
        SELECT f.drive_id, d.name AS drive_name,
               f.path, f.partial_hash, f.size_bytes
        FROM files f
        JOIN drives d ON f.drive_id = d.id
        WHERE f.partial_hash IS NOT NULL
        """
    ).fetchall()

    # Build folder -> hash-set mapping
    folder_hashes: dict[tuple[int, str], set[str]] = defaultdict(set)
    folder_meta: dict[tuple[int, str], dict] = {}

    for row in rows:
        did = row["drive_id"]
        parent = _extract_parent(row["path"])
        key = (did, parent)
        folder_hashes[key].add(row["partial_hash"])

        if key not in folder_meta:
            folder_meta[key] = {
                "drive_id": did,
                "drive_name": row["drive_name"],
                "folder_path": parent,
                "file_count": 0,
                "total_bytes": 0,
            }
        folder_meta[key]["file_count"] += 1
        folder_meta[key]["total_bytes"] += row["size_bytes"]

    # --- Exact matches: group by frozenset(hashes) ---
    fp_groups: dict[frozenset[str], list[tuple[int, str]]] = defaultdict(list)
    for key, hashes in folder_hashes.items():
        if hashes:
            fp_groups[frozenset(hashes)].append(key)

    exact_matches: list[dict] = []
    for fp, keys in fp_groups.items():
        if len(keys) < 2:
            continue
        if drive_id is not None and not any(k[0] == drive_id for k in keys):
            continue
        exact_matches.append({
            "match_type": "exact",
            "hash_count": len(fp),
            "folders": [folder_meta[k] for k in keys],
        })
    exact_matches.sort(
        key=lambda g: max(f["total_bytes"] for f in g["folders"]),
        reverse=True,
    )

    # --- Subset detection ---
    # Only consider folders with >= 2 unique hashes to avoid trivial matches
    candidates = [
        (k, folder_hashes[k])
        for k in folder_hashes
        if len(folder_hashes[k]) >= 2
    ]
    candidates.sort(key=lambda x: len(x[1]))

    # Reverse index: hash -> set of folder keys containing it
    hash_to_folders: dict[str, set[tuple[int, str]]] = defaultdict(set)
    for key, hashes in candidates:
        for h in hashes:
            hash_to_folders[h].add(key)

    subsets: list[dict] = []
    seen_pairs: set[tuple[tuple[int, str], tuple[int, str]]] = set()

    for small_key, small_hashes in candidates:
        # Find folders containing ALL of small_key's hashes and strictly larger
        potential: set[tuple[int, str]] | None = None
        for h in small_hashes:
            folders_with_h = {
                k
                for k in hash_to_folders.get(h, set())
                if k != small_key and len(folder_hashes[k]) > len(small_hashes)
            }
            potential = folders_with_h if potential is None else potential & folders_with_h
            if not potential:
                break

        if not potential:
            continue

        for super_key in potential:
            if small_hashes == folder_hashes[super_key]:
                continue  # exact match, already handled
            pair = (small_key, super_key)
            if pair in seen_pairs:
                continue
            seen_pairs.add(pair)

            if drive_id is not None:
                if small_key[0] != drive_id and super_key[0] != drive_id:
                    continue

            subsets.append({
                "match_type": "subset",
                "subset_hash_count": len(small_hashes),
                "superset_hash_count": len(folder_hashes[super_key]),
                "overlap_percent": round(
                    len(small_hashes) / len(folder_hashes[super_key]) * 100, 1
                ),
                "subset_folder": folder_meta[small_key],
                "superset_folder": folder_meta[super_key],
            })

    subsets.sort(key=lambda s: s["subset_folder"]["total_bytes"], reverse=True)

    return {
        "exact_match_groups": exact_matches,
        "subset_pairs": subsets[:200],
        "stats": {
            "total_folders_analyzed": len(folder_hashes),
            "exact_match_groups": len(exact_matches),
            "subset_pairs_found": len(subsets),
        },
    }
