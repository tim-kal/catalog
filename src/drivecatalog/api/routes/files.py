"""File browsing endpoints for DriveCatalog API."""

from fastapi import APIRouter, HTTPException, Query

from drivecatalog.database import get_connection

from ..models.file import FileListResponse, FileResponse

router = APIRouter(prefix="/files", tags=["files"])


@router.get("", response_model=FileListResponse)
async def list_files(
    drive: str | None = Query(None, description="Filter by drive name"),
    path_prefix: str | None = Query(None, description="Filter by path prefix (directory browsing)"),
    extension: str | None = Query(None, description="Filter by file extension (without dot)"),
    min_size: int | None = Query(None, ge=0, description="Minimum file size in bytes"),
    max_size: int | None = Query(None, ge=0, description="Maximum file size in bytes"),
    has_hash: bool | None = Query(None, description="Filter by hash presence"),
    is_media: bool | None = Query(None, description="Filter by media flag"),
    page: int = Query(1, ge=1, description="Page number"),
    page_size: int = Query(100, ge=1, le=1000, description="Results per page"),
) -> FileListResponse:
    """List files with optional filtering and pagination."""
    conn = get_connection()
    try:
        # Build query with optional filters
        conditions = []
        params: list = []

        if drive is not None:
            conditions.append("d.name = ?")
            params.append(drive)

        if path_prefix is not None:
            conditions.append("f.path LIKE ?")
            params.append(f"{path_prefix}%")

        if extension is not None:
            conditions.append("f.path LIKE ?")
            params.append(f"%.{extension}")

        if min_size is not None:
            conditions.append("f.size_bytes >= ?")
            params.append(min_size)

        if max_size is not None:
            conditions.append("f.size_bytes <= ?")
            params.append(max_size)

        if has_hash is not None:
            if has_hash:
                conditions.append("f.partial_hash IS NOT NULL")
            else:
                conditions.append("f.partial_hash IS NULL")

        if is_media is not None:
            conditions.append("f.is_media = ?")
            params.append(1 if is_media else 0)

        where_clause = " AND ".join(conditions) if conditions else "1=1"

        # Get total count
        count_query = f"""
            SELECT COUNT(*)
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            WHERE {where_clause}
        """
        total = conn.execute(count_query, params).fetchone()[0]

        # Get paginated results
        offset = (page - 1) * page_size
        data_query = f"""
            SELECT f.id, f.drive_id, d.name as drive_name, f.path, f.filename,
                   f.size_bytes, f.mtime, f.partial_hash, f.is_media
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            WHERE {where_clause}
            ORDER BY f.path
            LIMIT ? OFFSET ?
        """
        rows = conn.execute(data_query, [*params, page_size, offset]).fetchall()

        files = [
            FileResponse(
                id=row["id"],
                drive_id=row["drive_id"],
                drive_name=row["drive_name"],
                path=row["path"],
                filename=row["filename"],
                size_bytes=row["size_bytes"],
                mtime=row["mtime"],
                partial_hash=row["partial_hash"],
                is_media=bool(row["is_media"]),
            )
            for row in rows
        ]

        return FileListResponse(files=files, total=total, page=page, page_size=page_size)
    finally:
        conn.close()


@router.get("/{file_id}", response_model=FileResponse)
async def get_file(file_id: int) -> FileResponse:
    """Get details for a single file by ID."""
    conn = get_connection()
    try:
        row = conn.execute(
            """
            SELECT f.id, f.drive_id, d.name as drive_name, f.path, f.filename,
                   f.size_bytes, f.mtime, f.partial_hash, f.is_media
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            WHERE f.id = ?
            """,
            (file_id,),
        ).fetchone()

        if not row:
            raise HTTPException(status_code=404, detail=f"File with ID {file_id} not found")

        return FileResponse(
            id=row["id"],
            drive_id=row["drive_id"],
            drive_name=row["drive_name"],
            path=row["path"],
            filename=row["filename"],
            size_bytes=row["size_bytes"],
            mtime=row["mtime"],
            partial_hash=row["partial_hash"],
            is_media=bool(row["is_media"]),
        )
    finally:
        conn.close()
