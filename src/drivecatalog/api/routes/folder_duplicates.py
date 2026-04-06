"""Folder-level duplicate detection endpoint for DriveCatalog API."""

from __future__ import annotations

from fastapi import APIRouter, Query

from drivecatalog.database import get_connection
from drivecatalog.folder_duplicates import get_folder_duplicates

from ..models.folder_duplicate import (
    ExactMatchGroup,
    FolderDuplicateResponse,
    FolderDuplicateStats,
    FolderInfo,
    SubsetPair,
)

router = APIRouter(prefix="/folder-duplicates", tags=["folder-duplicates"])


@router.get("", response_model=FolderDuplicateResponse)
async def list_folder_duplicates(
    drive_id: int | None = Query(None, description="Filter to groups involving this drive"),
) -> FolderDuplicateResponse:
    """Detect duplicate and subset folders across all drives.

    Returns exact-match groups (folders with identical content) and
    subset pairs (one folder entirely contained within another).
    Uses existing file hash data — no re-scanning required.
    """
    conn = get_connection()
    try:
        raw = get_folder_duplicates(conn, drive_id=drive_id)

        exact = [
            ExactMatchGroup(
                match_type=g["match_type"],
                hash_count=g["hash_count"],
                folders=[FolderInfo(**f) for f in g["folders"]],
            )
            for g in raw["exact_match_groups"]
        ]

        subs = [
            SubsetPair(
                match_type=s["match_type"],
                subset_hash_count=s["subset_hash_count"],
                superset_hash_count=s["superset_hash_count"],
                overlap_percent=s["overlap_percent"],
                subset_folder=FolderInfo(**s["subset_folder"]),
                superset_folder=FolderInfo(**s["superset_folder"]),
            )
            for s in raw["subset_pairs"]
        ]

        stats = FolderDuplicateStats(**raw["stats"])

        return FolderDuplicateResponse(
            exact_match_groups=exact,
            subset_pairs=subs,
            stats=stats,
        )
    finally:
        conn.close()
