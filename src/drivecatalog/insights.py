"""Insights engine for DriveCatalog.

Computes actionable intelligence from the catalog data:
- Risk-ranked drives (most unprotected content + least free space)
- Content categories at risk (video, photos, audio, etc.)
- Prioritised recommended actions
- Easy wins (same-drive duplicates, cache files, redundant copies)

All queries are read-only and work without drives being mounted.
"""

from __future__ import annotations

from sqlite3 import Connection

from drivecatalog.duplicates import get_protection_stats

# Extension → category mapping
_CATEGORY_MAP: dict[str, tuple[str, str]] = {}
_VIDEO_EXTS = {"mov", "mp4", "r3d", "braw", "mxf", "mts", "mkv", "avi", "m4v", "wmv", "flv", "webm", "mpg", "mpeg"}
_RAW_PHOTO_EXTS = {"cr2", "arw", "dng", "nef", "raw", "raf", "orf", "rw2", "cr3", "srw"}
_PHOTO_EXTS = {"jpg", "jpeg", "png", "tiff", "tif", "gif", "heic", "heif", "bmp", "webp"}
_AUDIO_EXTS = {"wav", "mp3", "aiff", "flac", "aac", "ogg", "wma", "m4a", "alac"}
_PROJECT_EXTS = {"psd", "aep", "prproj", "drp", "fcpxml", "ai", "indd", "aepx", "blend", "fla"}
_ARCHIVE_EXTS = {"zip", "rar", "tar", "gz", "7z", "dmg", "iso", "bz2", "xz", "tgz"}
_CACHE_EXTS = {"dvcc", "ithmb", "lrprev", "thm", "xmp", "ds_store", "db", "bak", "tmp", "cache"}

for ext in _VIDEO_EXTS:
    _CATEGORY_MAP[ext] = ("Video", "film")
for ext in _RAW_PHOTO_EXTS:
    _CATEGORY_MAP[ext] = ("RAW Photos", "camera")
for ext in _PHOTO_EXTS:
    _CATEGORY_MAP[ext] = ("Photos", "photo")
for ext in _AUDIO_EXTS:
    _CATEGORY_MAP[ext] = ("Audio", "waveform")
for ext in _PROJECT_EXTS:
    _CATEGORY_MAP[ext] = ("Project Files", "doc.richtext")
for ext in _ARCHIVE_EXTS:
    _CATEGORY_MAP[ext] = ("Archives", "archivebox")
for ext in _CACHE_EXTS:
    _CATEGORY_MAP[ext] = ("Cache / Metadata", "gearshape")


def get_insights(conn: Connection) -> dict:
    """Compute full insights payload.

    Returns a dict with: health, drive_risks, at_risk_content, actions,
    consolidation summary.
    """
    # 1. Reuse existing protection stats for the health section
    protection = get_protection_stats(conn)

    # 2. Per-drive risk: unprotected content + capacity info
    drive_risks = _get_drive_risks(conn)

    # 3. Content categories at risk
    at_risk_content = _get_at_risk_content(conn)

    # 4. Consolidation summary
    consolidation = _get_consolidation_summary(conn)

    # 5. Build recommended actions from the data
    actions = _build_actions(protection, drive_risks, at_risk_content, consolidation)

    return {
        "health": {
            "backup_coverage_percent": protection["backup_coverage_percent"],
            "total_files": protection["total_files"],
            "hashed_files": protection["hashed_files"],
            "unhashed_files": protection["unhashed_files"],
            "unique_hashes": protection["unique_hashes"],
            "unprotected_hashes": protection["unprotected_files"],
            "unprotected_bytes": protection["unprotected_bytes"],
            "backed_up_hashes": protection["backed_up_files"],
            "backed_up_bytes": protection["backed_up_bytes"],
            "redundant_hashes": protection["over_backed_up_files"],
            "redundant_bytes": protection["over_backed_up_bytes"],
            "same_drive_duplicates": protection["same_drive_duplicate_count"],
            "reclaimable_bytes": protection["reclaimable_bytes"],
            "total_drives": protection["total_drives"],
            "total_storage_bytes": protection["total_storage_bytes"],
        },
        "drive_risks": drive_risks,
        "at_risk_content": at_risk_content,
        "actions": actions,
        "consolidation": consolidation,
    }


def _get_drive_risks(conn: Connection) -> list[dict]:
    """Rank drives by risk: unprotected content weighted by free space scarcity."""
    query = """
        WITH unprotected_hashes AS (
            SELECT partial_hash
            FROM files
            WHERE partial_hash IS NOT NULL
            GROUP BY partial_hash
            HAVING COUNT(DISTINCT drive_id) = 1
        )
        SELECT
            d.name as drive_name,
            COUNT(*) as unprotected_files,
            COALESCE(SUM(f.size_bytes), 0) as unprotected_bytes,
            d.total_bytes,
            d.used_bytes
        FROM files f
        JOIN drives d ON f.drive_id = d.id
        JOIN unprotected_hashes uh ON f.partial_hash = uh.partial_hash
        GROUP BY d.id
        ORDER BY unprotected_bytes DESC
    """
    rows = conn.execute(query).fetchall()

    results = []
    for r in rows:
        total = r["total_bytes"] or 0
        used = r["used_bytes"] or 0
        free = max(total - used, 0) if total and used is not None else 0
        free_pct = round(free * 100 / total, 1) if total > 0 else 0

        # Risk level based on unprotected content + free space
        unprotected = r["unprotected_bytes"]
        if unprotected > 1_000_000_000_000 and free_pct < 10:  # >1TB at risk, <10% free
            level = "critical"
        elif unprotected > 500_000_000_000 or free_pct < 5:  # >500GB or <5% free
            level = "high"
        elif unprotected > 100_000_000_000:  # >100GB
            level = "moderate"
        elif unprotected > 0:
            level = "low"
        else:
            level = "safe"

        results.append({
            "drive_name": r["drive_name"],
            "unprotected_files": r["unprotected_files"],
            "unprotected_bytes": unprotected,
            "total_bytes": total,
            "used_bytes": used,
            "free_bytes": free,
            "free_percent": free_pct,
            "risk_level": level,
        })

    return results


def _get_at_risk_content(conn: Connection) -> list[dict]:
    """Categorise unprotected files by content type."""
    query = """
        WITH unprotected_hashes AS (
            SELECT partial_hash
            FROM files
            WHERE partial_hash IS NOT NULL
            GROUP BY partial_hash
            HAVING COUNT(DISTINCT drive_id) = 1
        )
        SELECT
            LOWER(SUBSTR(f.filename, INSTR(f.filename, '.') + 1)) as ext,
            COUNT(*) as file_count,
            COALESCE(SUM(f.size_bytes), 0) as total_bytes
        FROM files f
        JOIN unprotected_hashes uh ON f.partial_hash = uh.partial_hash
        WHERE INSTR(f.filename, '.') > 0
        GROUP BY ext
        ORDER BY total_bytes DESC
    """
    rows = conn.execute(query).fetchall()

    # Aggregate into categories
    categories: dict[str, dict] = {}
    for r in rows:
        ext = r["ext"]
        cat_name, icon = _CATEGORY_MAP.get(ext, ("Other", "doc"))
        if cat_name not in categories:
            categories[cat_name] = {
                "category": cat_name,
                "icon": icon,
                "file_count": 0,
                "total_bytes": 0,
                "top_extensions": [],
            }
        cat = categories[cat_name]
        cat["file_count"] += r["file_count"]
        cat["total_bytes"] += r["total_bytes"]
        if len(cat["top_extensions"]) < 5:
            cat["top_extensions"].append(ext)

    # Sort by size descending
    result = sorted(categories.values(), key=lambda c: c["total_bytes"], reverse=True)
    return result


def _get_consolidation_summary(conn: Connection) -> dict:
    """Lightweight consolidation summary using the real consolidation engine."""
    from drivecatalog.consolidation import get_consolidation_candidates

    raw = get_consolidation_candidates(conn)
    candidates = [c["drive_name"] for c in raw if c["is_candidate"]]

    # Total free space
    free_row = conn.execute("""
        SELECT COALESCE(SUM(total_bytes - used_bytes), 0) as total_free
        FROM drives
        WHERE total_bytes IS NOT NULL AND used_bytes IS NOT NULL
          AND (total_bytes - used_bytes) > 0
    """).fetchone()
    total_free = free_row["total_free"] if free_row else 0

    return {
        "consolidatable_count": len(candidates),
        "candidate_drives": candidates[:5],
        "total_free_bytes": total_free,
    }


def _build_actions(
    protection: dict,
    drive_risks: list[dict],
    at_risk_content: list[dict],
    consolidation: dict,
) -> list[dict]:
    """Build prioritised action list from computed data."""
    actions = []
    priority = 0

    # Action 1: Back up top 3 highest-risk drives only
    critical_drives = [dr for dr in drive_risks if dr["risk_level"] in ("critical", "high")]
    for dr in critical_drives[:3]:
        priority += 1
        free_str = f"{dr['free_percent']}% free" if dr["free_percent"] > 0 else "no free space"
        actions.append({
            "id": f"backup_{dr['drive_name'].replace(' ', '_').lower()}",
            "priority": priority,
            "title": f"Back up {dr['drive_name']}",
            "description": (
                f"{_fmt_bytes(dr['unprotected_bytes'])} at risk — copy to another drive to protect. "
                f"Drive is {free_str}."
            ),
            "impact_bytes": dr["unprotected_bytes"],
            "action_type": "backup",
            "target": dr["drive_name"],
            "icon": "exclamationmark.triangle.fill",
            "color": "red" if dr["risk_level"] == "critical" else "orange",
        })

    # Summarise remaining critical/high drives if more than 3
    remaining = critical_drives[3:]
    if remaining:
        priority += 1
        total_remaining = sum(dr["unprotected_bytes"] for dr in remaining)
        names = ", ".join(dr["drive_name"] for dr in remaining)
        actions.append({
            "id": "backup_remaining_critical",
            "priority": priority,
            "title": f"{len(remaining)} more drives need backups",
            "description": f"{names} — {_fmt_bytes(total_remaining)} total unprotected",
            "impact_bytes": total_remaining,
            "action_type": "backup",
            "target": None,
            "icon": "exclamationmark.shield.fill",
            "color": "orange",
        })

    # Action 2: Clean same-drive duplicates
    dupes = protection["same_drive_duplicate_count"]
    reclaimable = protection["reclaimable_bytes"]
    if dupes > 0:
        priority += 1
        actions.append({
            "id": "clean_same_drive_dupes",
            "priority": priority,
            "title": "Clean same-drive duplicates",
            "description": (
                f"Free up {_fmt_bytes(reclaimable)} by removing {dupes:,} duplicate files "
                f"that exist multiple times on the same drive."
            ),
            "impact_bytes": reclaimable,
            "action_type": "cleanup",
            "target": None,
            "icon": "doc.on.doc.fill",
            "color": "orange",
        })

    # Action 3: Trim redundant copies (3+ drives)
    redundant = protection["over_backed_up_files"]
    if redundant > 100:
        priority += 1
        actions.append({
            "id": "trim_redundant",
            "priority": priority,
            "title": "Trim redundant copies",
            "description": (
                f"Free up {_fmt_bytes(protection['over_backed_up_bytes'])} — "
                f"{redundant:,} files already exist on 3+ drives and can be safely removed from extras."
            ),
            "impact_bytes": protection["over_backed_up_bytes"],
            "action_type": "cleanup",
            "target": None,
            "icon": "minus.circle.fill",
            "color": "blue",
        })

    # Action 4: Consolidate drives
    if consolidation["consolidatable_count"] > 0:
        priority += 1
        n = consolidation["consolidatable_count"]
        actions.append({
            "id": "consolidate_drives",
            "priority": priority,
            "title": f"Consolidate {n} drive{'s' if n != 1 else ''}",
            "description": (
                f"{n} drive{'s' if n != 1 else ''} can be emptied "
                f"by moving their unique files to other drives with space "
                f"(sequential allocation verified)"
            ),
            "impact_bytes": 0,
            "action_type": "consolidate",
            "target": None,
            "icon": "arrow.triangle.merge",
            "color": "green",
        })

    return actions


def _fmt_bytes(b: int) -> str:
    """Format bytes as human-readable string."""
    if b >= 1_099_511_627_776:  # 1 TB
        return f"{b / 1_099_511_627_776:.1f} TB"
    if b >= 1_073_741_824:  # 1 GB
        return f"{b / 1_073_741_824:.1f} GB"
    if b >= 1_048_576:  # 1 MB
        return f"{b / 1_048_576:.0f} MB"
    return f"{b:,} bytes"
