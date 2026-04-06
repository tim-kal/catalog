"""Protection and backup status endpoints for DriveCatalog API."""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Query

from drivecatalog.database import get_connection
from drivecatalog.duplicates import (
    get_directory_file_groups,
    get_drive_protection_stats,
    get_file_groups,
    get_protection_stats,
    get_protection_tree,
)
from drivecatalog.hasher import compute_verification_hash

from ..models.file import (
    DirectoryProtection,
    DriveProtectionStats,
    DriveProtectionSummary,
    FileGroup,
    FileLocation,
    FileVerificationResult,
    ProtectionResponse,
    ProtectionStats,
    ProtectionTreeResponse,
    VerificationRequest,
    VerificationResponse,
)

router = APIRouter(prefix="/duplicates", tags=["backups"])


@router.get("", response_model=ProtectionResponse)
async def list_file_groups(
    limit: int = Query(200, ge=1, le=10000),
    status: str | None = Query(
        None,
        description="Filter: unprotected, same_drive_duplicate, backed_up, over_backed_up",
    ),
    drive: str | None = Query(None, description="Filter to groups involving this drive"),
    sort_by: str = Query("reclaimable", description="Sort: reclaimable, size, copies, drive_count"),
) -> ProtectionResponse:
    """List file groups with protection classification."""
    conn = get_connection()
    try:
        raw_groups = get_file_groups(
            conn, status=status, drive_name=drive, sort_by=sort_by, limit=limit
        )

        groups = [
            FileGroup(
                filename=g["filename"],
                partial_hash=g["partial_hash"],
                size_bytes=g["size_bytes"],
                total_copies=g["total_copies"],
                drive_count=g["drive_count"],
                status=g["status"],
                same_drive_extras=g["same_drive_extras"],
                reclaimable_bytes=g["reclaimable_bytes"],
                locations=[
                    FileLocation(
                        drive_name=loc["drive_name"],
                        path=loc["path"],
                        file_id=loc["file_id"],
                        catalog_bundle=loc.get("catalog_bundle"),
                    )
                    for loc in g["locations"]
                ],
            )
            for g in raw_groups
        ]

        raw_stats = get_protection_stats(conn)
        stats = ProtectionStats(**raw_stats)

        return ProtectionResponse(groups=groups, stats=stats)
    finally:
        conn.close()


@router.get("/stats", response_model=ProtectionStats)
async def get_stats() -> ProtectionStats:
    """Get system-wide protection and storage statistics."""
    conn = get_connection()
    try:
        raw_stats = get_protection_stats(conn)
        return ProtectionStats(**raw_stats)
    finally:
        conn.close()


@router.get("/tree", response_model=ProtectionTreeResponse)
async def get_tree(
    drive: str | None = Query(None, description="Filter to a specific drive"),
) -> ProtectionTreeResponse:
    """Get protection stats grouped by drive and top-level directory.

    Returns a hierarchical view: drives > directories > protection stats.
    Use /duplicates/directory to drill into specific directories.
    """
    conn = get_connection()
    try:
        raw_drives = get_protection_tree(conn, drive_name=drive)
        raw_stats = get_protection_stats(conn)

        drives = [
            DriveProtectionSummary(
                drive_name=d["drive_name"],
                total_files=d["total_files"],
                total_bytes=d["total_bytes"],
                unprotected_files=d["unprotected_files"],
                backed_up_files=d["backed_up_files"],
                over_backed_up_files=d["over_backed_up_files"],
                directories=[
                    DirectoryProtection(**dir_data)
                    for dir_data in d["directories"]
                ],
            )
            for d in raw_drives
        ]

        return ProtectionTreeResponse(
            drives=drives,
            stats=ProtectionStats(**raw_stats),
        )
    finally:
        conn.close()


@router.get("/directory")
async def get_directory_files(
    drive: str = Query(..., description="Drive name"),
    path: str = Query(..., description="Directory path (use '.' for root)"),
    limit: int = Query(200, ge=1, le=5000),
) -> list[FileGroup]:
    """Get file groups within a specific directory on a drive.

    Returns files in the specified directory (not subdirectories) with their
    cross-drive protection status.
    """
    conn = get_connection()
    try:
        raw_groups = get_directory_file_groups(conn, drive, path, limit)
        return [
            FileGroup(
                filename=g["filename"],
                partial_hash=g["partial_hash"],
                size_bytes=g["size_bytes"],
                total_copies=g["total_copies"],
                drive_count=g["drive_count"],
                status=g["status"],
                same_drive_extras=g["same_drive_extras"],
                reclaimable_bytes=g["reclaimable_bytes"],
                locations=[
                    FileLocation(
                        drive_name=loc["drive_name"],
                        path=loc["path"],
                        file_id=loc["file_id"],
                        catalog_bundle=loc.get("catalog_bundle"),
                    )
                    for loc in g["locations"]
                ],
            )
            for g in raw_groups
        ]
    finally:
        conn.close()


@router.get("/drive/{drive_name}", response_model=DriveProtectionStats)
async def get_drive_stats(drive_name: str) -> DriveProtectionStats:
    """Get protection statistics for a specific drive."""
    conn = get_connection()
    try:
        raw = get_drive_protection_stats(conn, drive_name)
        if not raw:
            from fastapi import HTTPException

            raise HTTPException(404, f"Drive '{drive_name}' not found")
        return DriveProtectionStats(**raw)
    finally:
        conn.close()


@router.post("/verify", response_model=VerificationResponse)
async def verify_files(request: VerificationRequest) -> VerificationResponse:
    """Compute verification hashes for files to confirm they are true duplicates.

    Used before deletion to ensure files sharing a partial hash are genuinely
    identical (samples first + middle + last 64KB chunks).
    """
    from fastapi import HTTPException

    if len(request.file_ids) < 2:
        raise HTTPException(400, "Need at least 2 file IDs to verify")
    if len(request.file_ids) > 50:
        raise HTTPException(400, "Maximum 50 files per verification request")

    conn = get_connection()
    try:
        # Look up file paths and drive mount paths
        placeholders = ",".join("?" for _ in request.file_ids)
        rows = conn.execute(
            f"""
            SELECT f.id, f.path, f.size_bytes, d.name as drive_name, d.mount_path
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            WHERE f.id IN ({placeholders})
            """,
            request.file_ids,
        ).fetchall()

        if not rows:
            raise HTTPException(404, "No files found for the given IDs")

        results: list[FileVerificationResult] = []
        hashes: list[str] = []

        for row in rows:
            mount_path = row["mount_path"]
            full_path = Path(mount_path) / row["path"]

            if not full_path.exists():
                results.append(FileVerificationResult(
                    file_id=row["id"],
                    drive_name=row["drive_name"],
                    path=row["path"],
                    verification_hash=None,
                    accessible=False,
                ))
                continue

            vhash = compute_verification_hash(full_path, row["size_bytes"])
            accessible = vhash is not None
            if vhash:
                hashes.append(vhash)

            results.append(FileVerificationResult(
                file_id=row["id"],
                drive_name=row["drive_name"],
                path=row["path"],
                verification_hash=vhash,
                accessible=accessible,
            ))

        # Check if all accessible files have the same verification hash
        unique_hashes = set(hashes)
        all_match = len(unique_hashes) == 1 and len(hashes) >= 2

        return VerificationResponse(
            verified=all_match,
            results=results,
            matching_hash=unique_hashes.pop() if all_match else None,
        )
    finally:
        conn.close()
