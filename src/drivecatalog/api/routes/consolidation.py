"""Consolidation analysis endpoints for DriveCatalog API."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query

from drivecatalog.consolidation import (
    get_consolidation_candidates,
    get_consolidation_recommendations,
    get_consolidation_strategy,
    get_drive_file_distribution,
)
from drivecatalog.database import get_connection

from ..models.consolidation import (
    ConsolidationCandidate,
    ConsolidationCandidatesResponse,
    ConsolidationStrategyResponse,
    DriveDistribution,
    DriveDistributionResponse,
    Recommendation,
    RecommendationsResponse,
    StrategyAssignment,
    StrategyFile,
    StrategyTargetDrive,
    TargetDrive,
)

router = APIRouter(prefix="/consolidation", tags=["consolidation"])


@router.get("/distribution", response_model=DriveDistributionResponse)
async def get_distribution() -> DriveDistributionResponse:
    """Get per-drive file distribution with unique/duplicated breakdown."""
    conn = get_connection()
    try:
        raw = get_drive_file_distribution(conn)
        drives = [DriveDistribution(**d) for d in raw]
        return DriveDistributionResponse(
            drives=drives,
            total_drives=len(drives),
        )
    finally:
        conn.close()


@router.get("/candidates", response_model=ConsolidationCandidatesResponse)
async def get_candidates() -> ConsolidationCandidatesResponse:
    """Identify drives whose unique files can fit on other connected drives."""
    conn = get_connection()
    try:
        raw = get_consolidation_candidates(conn)
        candidates = [
            ConsolidationCandidate(
                drive_id=c["drive_id"],
                drive_name=c["drive_name"],
                total_files=c["total_files"],
                total_size_bytes=c["total_size_bytes"],
                unique_files=c["unique_files"],
                unique_size_bytes=c["unique_size_bytes"],
                duplicated_files=c["duplicated_files"],
                duplicated_size_bytes=c["duplicated_size_bytes"],
                reclaimable_bytes=c["reclaimable_bytes"],
                is_candidate=c["is_candidate"],
                total_available_space=c["total_available_space"],
                target_drives=[
                    TargetDrive(
                        drive_name=t["drive_name"],
                        free_bytes=t["free_bytes"],
                    )
                    for t in c["target_drives"]
                ],
            )
            for c in raw
        ]
        consolidatable = sum(1 for c in candidates if c.is_candidate)
        return ConsolidationCandidatesResponse(
            candidates=candidates,
            total_drives=len(candidates),
            consolidatable_count=consolidatable,
        )
    finally:
        conn.close()


@router.get("/strategy", response_model=ConsolidationStrategyResponse)
async def get_strategy(
    drive: str = Query(..., description="Source drive name"),
) -> ConsolidationStrategyResponse:
    """Compute optimal consolidation strategy for a source drive."""
    conn = get_connection()
    try:
        raw = get_consolidation_strategy(conn, drive)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    finally:
        conn.close()

    return ConsolidationStrategyResponse(
        source_drive=raw["source_drive"],
        total_unique_files=raw["total_unique_files"],
        total_unique_bytes=raw["total_unique_bytes"],
        total_bytes_to_transfer=raw["total_bytes_to_transfer"],
        is_feasible=raw["is_feasible"],
        assignments=[
            StrategyAssignment(
                target_drive=a["target_drive"],
                file_count=a["file_count"],
                total_bytes=a["total_bytes"],
                files=[
                    StrategyFile(
                        path=f["path"],
                        size_bytes=f["size_bytes"],
                        partial_hash=f["partial_hash"],
                    )
                    for f in a["files"]
                ],
            )
            for a in raw["assignments"]
        ],
        unplaceable=[
            StrategyFile(
                path=f["path"],
                size_bytes=f["size_bytes"],
                partial_hash=f["partial_hash"],
            )
            for f in raw["unplaceable"]
        ],
        target_drives=[
            StrategyTargetDrive(
                drive_name=t["drive_name"],
                capacity_bytes=t["capacity_bytes"],
                free_before=t["free_before"],
                free_after=t["free_after"],
            )
            for t in raw["target_drives"]
        ],
    )


@router.get("/recommendations", response_model=RecommendationsResponse)
async def get_recommendations() -> RecommendationsResponse:
    """Get ordered move/delete recommendations sorted by space freed.

    Advisory only — does not execute any moves automatically.
    """
    conn = get_connection()
    try:
        raw = get_consolidation_recommendations(conn)
        recs = [Recommendation(**r) for r in raw]
        return RecommendationsResponse(
            recommendations=recs,
            total_count=len(recs),
        )
    finally:
        conn.close()
