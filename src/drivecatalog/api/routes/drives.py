"""Drive management endpoints for DriveCatalog API."""

from pathlib import Path

from fastapi import APIRouter, HTTPException

from drivecatalog.database import get_connection
from drivecatalog.drives import get_drive_info, validate_mount_path

from ..models.drive import (
    DriveCreateRequest,
    DriveListResponse,
    DriveResponse,
    DriveStatusResponse,
)

router = APIRouter(prefix="/drives", tags=["drives"])


@router.get("", response_model=DriveListResponse)
async def list_drives() -> DriveListResponse:
    """List all registered drives with file counts."""
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT d.*, (SELECT COUNT(*) FROM files WHERE drive_id = d.id) as file_count
            FROM drives d ORDER BY d.name
            """
        ).fetchall()

        drives = [
            DriveResponse(
                id=row["id"],
                name=row["name"],
                uuid=row["uuid"],
                mount_path=row["mount_path"] or "",
                total_bytes=row["total_bytes"] or 0,
                last_scan=row["last_scan"],
                file_count=row["file_count"],
            )
            for row in rows
        ]

        return DriveListResponse(drives=drives, total=len(drives))
    finally:
        conn.close()


@router.post("", response_model=DriveResponse, status_code=201)
async def create_drive(request: DriveCreateRequest) -> DriveResponse:
    """Register a new drive for cataloging.

    The path must be a valid mount point under /Volumes/.
    """
    path_obj = Path(request.path)

    # Check if path exists first
    if not path_obj.exists():
        raise HTTPException(status_code=404, detail=f"Path '{request.path}' does not exist")

    # Validate mount path
    if not validate_mount_path(path_obj):
        raise HTTPException(
            status_code=400,
            detail=f"'{request.path}' is not a valid mount point. Must be under /Volumes/.",
        )

    # Get drive information
    drive_info = get_drive_info(path_obj)
    drive_name = request.name if request.name else drive_info["name"]

    conn = get_connection()
    try:
        # Check if already registered by UUID or mount_path
        existing = conn.execute(
            "SELECT name FROM drives WHERE uuid = ? OR mount_path = ?",
            (drive_info["uuid"], drive_info["mount_path"]),
        ).fetchone()

        if existing:
            raise HTTPException(
                status_code=400,
                detail=f"Drive already registered as '{existing['name']}'",
            )

        # Insert new drive
        cursor = conn.execute(
            """
            INSERT INTO drives (name, uuid, mount_path, total_bytes)
            VALUES (?, ?, ?, ?)
            """,
            (drive_name, drive_info["uuid"], drive_info["mount_path"], drive_info["total_bytes"]),
        )
        conn.commit()

        # Return the created drive
        drive_id = cursor.lastrowid
        return DriveResponse(
            id=drive_id,
            name=drive_name,
            uuid=drive_info["uuid"],
            mount_path=drive_info["mount_path"],
            total_bytes=drive_info["total_bytes"],
            last_scan=None,
            file_count=0,
        )
    finally:
        conn.close()
