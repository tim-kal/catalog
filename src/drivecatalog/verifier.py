"""Deterministic verification of scan, hash, and duplicate integrity."""

import os
import random
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable

from .hasher import compute_partial_hash
from .scanner import SKIP_DIRECTORIES


def _should_skip(name: str) -> bool:
    return name.startswith(".") or name in SKIP_DIRECTORIES


@dataclass
class VerificationResult:
    """Full verification report for a drive."""

    # Scan integrity
    files_on_disk: int = 0
    files_in_db: int = 0
    missing_from_db: int = 0  # on disk but not in DB
    stale_in_db: int = 0  # in DB but not on disk
    size_mismatches: int = 0  # file exists but size changed

    # Hash integrity
    hashes_checked: int = 0
    hashes_matched: int = 0
    hashes_mismatched: int = 0
    hash_read_errors: int = 0
    mismatched_files: list[dict] = field(default_factory=list)

    # Duplicate integrity
    duplicate_clusters_checked: int = 0
    duplicate_clusters_valid: int = 0
    duplicate_clusters_invalid: int = 0
    false_duplicates: list[dict] = field(default_factory=list)

    # Overall
    started_at: str = ""
    completed_at: str = ""
    cancelled: bool = False

    @property
    def scan_pass(self) -> bool:
        return self.missing_from_db == 0 and self.stale_in_db == 0 and self.size_mismatches == 0

    @property
    def hash_pass(self) -> bool:
        return self.hashes_mismatched == 0 and self.hashes_checked > 0

    @property
    def duplicate_pass(self) -> bool:
        return self.duplicate_clusters_invalid == 0

    @property
    def all_pass(self) -> bool:
        return self.scan_pass and self.hash_pass and self.duplicate_pass

    def to_dict(self) -> dict:
        return {
            "scan": {
                "pass": self.scan_pass,
                "files_on_disk": self.files_on_disk,
                "files_in_db": self.files_in_db,
                "missing_from_db": self.missing_from_db,
                "stale_in_db": self.stale_in_db,
                "size_mismatches": self.size_mismatches,
            },
            "hash": {
                "pass": self.hash_pass,
                "checked": self.hashes_checked,
                "matched": self.hashes_matched,
                "mismatched": self.hashes_mismatched,
                "read_errors": self.hash_read_errors,
                "mismatched_files": self.mismatched_files[:20],
            },
            "duplicates": {
                "pass": self.duplicate_pass,
                "clusters_checked": self.duplicate_clusters_checked,
                "clusters_valid": self.duplicate_clusters_valid,
                "clusters_invalid": self.duplicate_clusters_invalid,
                "false_duplicates": self.false_duplicates[:20],
            },
            "all_pass": self.all_pass,
            "started_at": self.started_at,
            "completed_at": self.completed_at,
        }


def verify_drive(
    drive_id: int,
    mount_path: str,
    conn: sqlite3.Connection,
    progress_callback: Callable[[str, int, int], None] | None = None,
    cancel_check: Callable[[], bool] | None = None,
    hash_sample_percent: int = 100,
) -> VerificationResult:
    """Run full deterministic verification of a drive's scan data.

    Three phases:
    1. Scan integrity — compare filesystem against DB entries
    2. Hash integrity — re-hash files and compare against stored hashes
    3. Duplicate integrity — verify duplicate clusters are real

    Args:
        drive_id: Database ID of the drive.
        mount_path: Filesystem path to the mounted drive.
        conn: Database connection.
        progress_callback: Optional (phase_name, current, total) callback.
        cancel_check: Optional callable returning True to abort.
        hash_sample_percent: Percentage of hashed files to re-verify (1-100).
    """
    result = VerificationResult(started_at=datetime.now().isoformat())
    mount = Path(mount_path)

    # ── Phase 1: Scan Integrity ──────────────────────────────────────────

    # Build set of all files currently on disk
    disk_files: dict[str, int] = {}  # relative_path -> size_bytes
    for dirpath, dirnames, filenames in os.walk(mount_path):
        if cancel_check and cancel_check():
            result.cancelled = True
            return result

        dirnames[:] = [d for d in dirnames if not _should_skip(d)]
        current = Path(dirpath)
        for fname in filenames:
            if fname.startswith("."):
                continue
            fpath = current / fname
            try:
                stat = fpath.stat()
                rel = str(fpath.relative_to(mount))
                disk_files[rel] = stat.st_size
            except (OSError, PermissionError):
                pass

    result.files_on_disk = len(disk_files)

    # Get all DB entries for this drive
    db_rows = conn.execute(
        "SELECT path, size_bytes FROM files WHERE drive_id = ?",
        (drive_id,),
    ).fetchall()
    db_files: dict[str, int] = {row["path"]: row["size_bytes"] for row in db_rows}
    result.files_in_db = len(db_files)

    if progress_callback:
        progress_callback("scan", 0, 3)

    # Files on disk but not in DB
    for path in disk_files:
        if path not in db_files:
            result.missing_from_db += 1

    # Files in DB but not on disk
    for path in db_files:
        if path not in disk_files:
            result.stale_in_db += 1

    # Size mismatches (file exists in both but size differs)
    for path in disk_files:
        if path in db_files and disk_files[path] != db_files[path]:
            result.size_mismatches += 1

    if progress_callback:
        progress_callback("scan", 1, 3)

    if cancel_check and cancel_check():
        result.cancelled = True
        return result

    # ── Phase 2: Hash Integrity ──────────────────────────────────────────

    hashed_rows = conn.execute(
        "SELECT id, path, size_bytes, partial_hash FROM files "
        "WHERE drive_id = ? AND partial_hash IS NOT NULL",
        (drive_id,),
    ).fetchall()

    # Sample if not checking 100%
    if hash_sample_percent < 100 and len(hashed_rows) > 0:
        sample_size = max(1, len(hashed_rows) * hash_sample_percent // 100)
        hashed_rows = random.sample(list(hashed_rows), sample_size)

    total_to_check = len(hashed_rows)

    for i, row in enumerate(hashed_rows):
        if cancel_check and cancel_check():
            result.cancelled = True
            return result

        file_path = mount / row["path"]
        stored_hash = row["partial_hash"]

        recomputed = compute_partial_hash(file_path, row["size_bytes"])

        if recomputed is None:
            result.hash_read_errors += 1
        elif recomputed == stored_hash:
            result.hashes_matched += 1
        else:
            result.hashes_mismatched += 1
            result.mismatched_files.append({
                "path": row["path"],
                "stored_hash": stored_hash,
                "actual_hash": recomputed,
            })

        result.hashes_checked += 1

        if progress_callback and (i % 50 == 0 or i == total_to_check - 1):
            progress_callback("hash", i + 1, total_to_check)

    if progress_callback:
        progress_callback("hash", total_to_check, total_to_check)

    if cancel_check and cancel_check():
        result.cancelled = True
        return result

    # ── Phase 3: Duplicate Integrity ─────────────────────────────────────
    # For each duplicate cluster, re-hash all members and confirm they match.

    clusters = conn.execute(
        """
        SELECT partial_hash, COUNT(*) as cnt
        FROM files
        WHERE drive_id = ? AND partial_hash IS NOT NULL
        GROUP BY partial_hash
        HAVING cnt > 1
        ORDER BY cnt DESC
        LIMIT 500
        """,
        (drive_id,),
    ).fetchall()

    total_clusters = len(clusters)

    for ci, cluster in enumerate(clusters):
        if cancel_check and cancel_check():
            result.cancelled = True
            return result

        cluster_hash = cluster["partial_hash"]
        members = conn.execute(
            "SELECT id, path, size_bytes FROM files "
            "WHERE drive_id = ? AND partial_hash = ?",
            (drive_id, cluster_hash),
        ).fetchall()

        # Re-hash each member and check they all produce the same hash
        recomputed_hashes = set()
        for member in members:
            h = compute_partial_hash(mount / member["path"], member["size_bytes"])
            if h is not None:
                recomputed_hashes.add(h)

        result.duplicate_clusters_checked += 1

        if len(recomputed_hashes) == 1 and cluster_hash in recomputed_hashes:
            result.duplicate_clusters_valid += 1
        else:
            result.duplicate_clusters_invalid += 1
            result.false_duplicates.append({
                "stored_hash": cluster_hash,
                "member_count": len(members),
                "unique_hashes_found": len(recomputed_hashes),
                "sample_paths": [m["path"] for m in members[:3]],
            })

        if progress_callback and (ci % 10 == 0 or ci == total_clusters - 1):
            progress_callback("duplicates", ci + 1, total_clusters)

    result.completed_at = datetime.now().isoformat()
    return result
