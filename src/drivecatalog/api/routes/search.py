"""Search endpoints for DriveCatalog API."""

from fastapi import APIRouter, HTTPException, Query

from drivecatalog.database import get_connection
from drivecatalog.search import search_files

from ..models.file import SearchFile, SearchResultResponse

router = APIRouter(prefix="/search", tags=["search"])


@router.get("", response_model=SearchResultResponse)
async def search(
    q: str = Query(..., min_length=1, description="Search pattern (glob-style: *.mp4, *vacation*)"),
    drive: str | None = Query(None, description="Filter by drive name"),
    min_size: int | None = Query(None, ge=0, description="Minimum file size in bytes"),
    max_size: int | None = Query(None, ge=0, description="Maximum file size in bytes"),
    extension: str | None = Query(None, description="Filter by extension (without dot)"),
    limit: int = Query(100, ge=1, le=1000, description="Maximum results"),
) -> SearchResultResponse:
    """Search files by glob pattern with optional filters.

    Pattern uses glob-style wildcards:
    - * matches any characters (e.g., *.mp4 for all MP4 files)
    - ? matches a single character

    Examples:
    - q=*.mp4 - Find all MP4 files
    - q=*vacation* - Find files with 'vacation' in the path
    - q=IMG_*.jpg - Find JPEG files starting with IMG_
    """
    if not q or not q.strip():
        raise HTTPException(status_code=400, detail="Search query 'q' is required")

    conn = get_connection()
    try:
        results = search_files(
            conn,
            pattern=q,
            drive_name=drive,
            min_size=min_size,
            max_size=max_size,
            extension=extension,
            limit=limit,
        )

        files = [
            SearchFile(
                drive_name=r["drive_name"],
                path=r["path"],
                size_bytes=r["size_bytes"],
                mtime=r["mtime"],
            )
            for r in results
        ]

        return SearchResultResponse(
            files=files,
            total=len(files),
            pattern=q,
        )
    finally:
        conn.close()
