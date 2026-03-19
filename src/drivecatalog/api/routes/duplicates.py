"""Duplicate detection endpoints for DriveCatalog API."""

from enum import StrEnum

from fastapi import APIRouter, Query

from drivecatalog.database import get_connection
from drivecatalog.duplicates import get_duplicate_clusters, get_duplicate_stats

from ..models.file import (
    DuplicateCluster,
    DuplicateFile,
    DuplicateListResponse,
    DuplicateStatsResponse,
)

router = APIRouter(prefix="/duplicates", tags=["duplicates"])


class SortBy(StrEnum):
    """Sort options for duplicate clusters."""

    reclaimable = "reclaimable"
    count = "count"
    size = "size"


@router.get("", response_model=DuplicateListResponse)
async def list_duplicates(
    limit: int = Query(100, ge=1, le=1000, description="Maximum clusters to return"),
    min_size: int | None = Query(None, ge=0, description="Minimum file size to consider"),
    sort_by: SortBy = Query(  # noqa: B008
        SortBy.reclaimable, description="Sort by: reclaimable, count, or size"
    ),
) -> DuplicateListResponse:
    """List duplicate file clusters with optional filtering.

    Returns clusters of files sharing the same partial hash, sorted by reclaimable space.
    """
    conn = get_connection()
    try:
        # Get all duplicate clusters from the existing module
        raw_clusters = get_duplicate_clusters(conn)

        # Apply min_size filter if specified
        if min_size is not None:
            raw_clusters = [c for c in raw_clusters if c["size_bytes"] >= min_size]

        # Sort by specified field
        if sort_by == SortBy.reclaimable:
            raw_clusters.sort(key=lambda c: c["reclaimable_bytes"], reverse=True)
        elif sort_by == SortBy.count:
            raw_clusters.sort(key=lambda c: c["count"], reverse=True)
        elif sort_by == SortBy.size:
            raw_clusters.sort(key=lambda c: c["size_bytes"], reverse=True)

        # Apply limit
        raw_clusters = raw_clusters[:limit]

        # Get file IDs for each file in the clusters (need to query for this)
        clusters = []
        for raw in raw_clusters:
            files = []
            for f in raw["files"]:
                # Look up file ID by drive_name and path
                file_row = conn.execute(
                    """
                    SELECT f.id FROM files f
                    JOIN drives d ON f.drive_id = d.id
                    WHERE d.name = ? AND f.path = ?
                    """,
                    (f["drive_name"], f["path"]),
                ).fetchone()

                file_id = file_row["id"] if file_row else 0

                files.append(
                    DuplicateFile(
                        drive_name=f["drive_name"],
                        path=f["path"],
                        file_id=file_id,
                    )
                )

            clusters.append(
                DuplicateCluster(
                    partial_hash=raw["partial_hash"],
                    size_bytes=raw["size_bytes"],
                    count=raw["count"],
                    reclaimable_bytes=raw["reclaimable_bytes"],
                    files=files,
                )
            )

        # Get stats
        raw_stats = get_duplicate_stats(conn)
        stats = DuplicateStatsResponse(
            total_clusters=raw_stats["total_clusters"],
            total_duplicate_files=raw_stats["total_duplicate_files"],
            total_bytes=raw_stats["total_bytes"],
            reclaimable_bytes=raw_stats["reclaimable_bytes"],
        )

        return DuplicateListResponse(clusters=clusters, stats=stats)
    finally:
        conn.close()


@router.get("/stats", response_model=DuplicateStatsResponse)
async def get_stats() -> DuplicateStatsResponse:
    """Get aggregate statistics about duplicates.

    Returns counts and byte totals for duplicate detection.
    """
    conn = get_connection()
    try:
        raw_stats = get_duplicate_stats(conn)

        return DuplicateStatsResponse(
            total_clusters=raw_stats["total_clusters"],
            total_duplicate_files=raw_stats["total_duplicate_files"],
            total_bytes=raw_stats["total_bytes"],
            reclaimable_bytes=raw_stats["reclaimable_bytes"],
        )
    finally:
        conn.close()
