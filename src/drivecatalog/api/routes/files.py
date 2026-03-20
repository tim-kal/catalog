"""File browsing endpoints for DriveCatalog API."""

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from drivecatalog.database import get_connection

from ..models.file import FileListResponse, FileResponse
from ..models.scan import MediaMetadataResponse

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
    has_integrity_errors: bool | None = Query(
        None, description="Filter to files with integrity errors (requires is_media)"
    ),
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

        if has_integrity_errors is not None:
            if has_integrity_errors:
                conditions.append(
                    "EXISTS (SELECT 1 FROM media_metadata m "
                    "WHERE m.file_id = f.id AND m.integrity_errors IS NOT NULL)"
                )
            else:
                conditions.append(
                    "NOT EXISTS (SELECT 1 FROM media_metadata m "
                    "WHERE m.file_id = f.id AND m.integrity_errors IS NOT NULL)"
                )

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





class DirectoryEntry(BaseModel):
    """A directory in the browse response."""
    name: str
    path: str
    file_count: int
    total_bytes: int
    child_dir_count: int = 0


class BrowseResponse(BaseModel):
    """Response for directory browsing - lists directories and files at a path level."""
    drive: str
    current_path: str
    directories: list[DirectoryEntry]
    files: list[FileResponse]


@router.get("/browse", response_model=BrowseResponse)
async def browse_directory(
    drive: str = Query(..., description="Drive name (required)"),
    path: str = Query("", description="Directory path relative to drive root (empty = root)"),
) -> BrowseResponse:
    """Browse files like Finder — list directories and files at a specific path level.

    Returns immediate children only (not recursive). Directories show
    aggregated file count and total size.
    """
    conn = get_connection()
    try:
        # Verify drive exists
        drive_row = conn.execute(
            "SELECT id FROM drives WHERE name = ?", (drive,)
        ).fetchone()
        if not drive_row:
            raise HTTPException(status_code=404, detail=f"Drive {drive} not found")

        drive_id = drive_row["id"]

        # Normalize path: strip trailing slash, ensure no leading slash
        current_path = path.strip("/")
        prefix = f"{current_path}/" if current_path else ""

        # Get all files under this path prefix
        rows = conn.execute(
            """
            SELECT f.id, f.drive_id, ? as drive_name, f.path, f.filename,
                   f.size_bytes, f.mtime, f.partial_hash, f.is_media
            FROM files f
            WHERE f.drive_id = ? AND f.path LIKE ?
            ORDER BY f.path
            """,
            (drive, drive_id, f"{prefix}%"),
        ).fetchall()

        # Separate into direct files and subdirectories
        direct_files = []
        dir_stats: dict[str, dict] = {}  # dirname -> {count, bytes, subdirs}

        for row in rows:
            rel_path = row["path"]
            # Strip the current prefix to get the remainder
            remainder = rel_path[len(prefix):]

            if "/" in remainder:
                # This file is in a subdirectory
                dir_name = remainder.split("/", 1)[0]
                if dir_name not in dir_stats:
                    dir_stats[dir_name] = {"count": 0, "bytes": 0, "subdirs": set()}
                dir_stats[dir_name]["count"] += 1
                dir_stats[dir_name]["bytes"] += row["size_bytes"]
                # Track immediate child directories within this directory
                after_dir = remainder[len(dir_name) + 1:]
                if "/" in after_dir:
                    subdir_name = after_dir.split("/", 1)[0]
                    dir_stats[dir_name]["subdirs"].add(subdir_name)
            else:
                # Direct child file
                direct_files.append(
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
                )

        # Build directory entries
        directories = sorted([
            DirectoryEntry(
                name=name,
                path=f"{prefix}{name}" if prefix else name,
                file_count=stats["count"],
                total_bytes=stats["bytes"],
                child_dir_count=len(stats["subdirs"]),
            )
            for name, stats in dir_stats.items()
        ], key=lambda d: d.name.lower())

        # Also handle root level (no prefix) — files at drive root
        if not prefix:
            root_rows = conn.execute(
                """
                SELECT f.id, f.drive_id, ? as drive_name, f.path, f.filename,
                       f.size_bytes, f.mtime, f.partial_hash, f.is_media
                FROM files f
                WHERE f.drive_id = ? AND f.path NOT LIKE '%/%'
                ORDER BY f.path
                """,
                (drive, drive_id),
            ).fetchall()
            direct_files = [
                FileResponse(
                    id=r["id"],
                    drive_id=r["drive_id"],
                    drive_name=r["drive_name"],
                    path=r["path"],
                    filename=r["filename"],
                    size_bytes=r["size_bytes"],
                    mtime=r["mtime"],
                    partial_hash=r["partial_hash"],
                    is_media=bool(r["is_media"]),
                )
                for r in root_rows
            ]

        return BrowseResponse(
            drive=drive,
            current_path=current_path,
            directories=directories,
            files=direct_files,
        )
    finally:
        conn.close()


class BackupDriveCoverage(BaseModel):
    """Coverage stats for one backup drive."""

    drive_name: str
    file_count: int
    percent_coverage: float


class BackupStatusResponse(BaseModel):
    """Response for folder backup status across drives."""

    drive: str
    path: str
    total_files: int
    hashed_files: int
    backed_up_files: int
    backup_drives: list[BackupDriveCoverage]


@router.get("/browse/backup-status", response_model=BackupStatusResponse)
async def browse_backup_status(
    drive: str = Query(..., description="Source drive name"),
    path: str = Query(..., description="Folder path relative to drive root"),
) -> BackupStatusResponse:
    """Return backup coverage for a folder across all other drives.

    Matches files by partial_hash. Reports how many hashed files in the
    folder also exist on each other drive and the percentage of coverage.
    """
    conn = get_connection()
    try:
        # Verify source drive exists
        drive_row = conn.execute(
            "SELECT id FROM drives WHERE name = ?", (drive,)
        ).fetchone()
        if not drive_row:
            raise HTTPException(status_code=404, detail=f"Drive '{drive}' not found")

        drive_id = drive_row["id"]

        # Normalize path
        current_path = path.strip("/")
        prefix = f"{current_path}/" if current_path else ""

        # Fetch all files recursively under this path on the source drive
        rows = conn.execute(
            """
            SELECT partial_hash
            FROM files
            WHERE drive_id = ? AND path LIKE ?
            """,
            (drive_id, f"{prefix}%"),
        ).fetchall()

        total_files = len(rows)
        hashes = [r["partial_hash"] for r in rows if r["partial_hash"] is not None]
        hashed_files = len(hashes)

        if not hashes:
            return BackupStatusResponse(
                drive=drive,
                path=current_path,
                total_files=total_files,
                hashed_files=0,
                backed_up_files=0,
                backup_drives=[],
            )

        # For each hash, find which other drives have a matching file.
        # Use a single query with GROUP BY drive to count per-drive matches.
        # SQLite placeholders for IN clause.
        placeholders = ",".join("?" * len(hashes))
        coverage_rows = conn.execute(
            f"""
            SELECT d.name AS drive_name, COUNT(DISTINCT f.partial_hash) AS matched_hashes
            FROM files f
            JOIN drives d ON f.drive_id = d.id
            WHERE f.drive_id != ?
              AND f.partial_hash IS NOT NULL
              AND f.partial_hash IN ({placeholders})
            GROUP BY d.id
            ORDER BY matched_hashes DESC
            """,
            [drive_id, *hashes],
        ).fetchall()

        # Count how many source hashes are backed up on at least one other drive
        backed_up_hashes_row = conn.execute(
            f"""
            SELECT COUNT(DISTINCT f.partial_hash) AS backed_up
            FROM files f
            WHERE f.drive_id != ?
              AND f.partial_hash IS NOT NULL
              AND f.partial_hash IN ({placeholders})
            """,
            [drive_id, *hashes],
        ).fetchone()
        backed_up_files = backed_up_hashes_row["backed_up"] if backed_up_hashes_row else 0

        backup_drives = [
            BackupDriveCoverage(
                drive_name=r["drive_name"],
                file_count=r["matched_hashes"],
                percent_coverage=round(r["matched_hashes"] / hashed_files * 100, 1),
            )
            for r in coverage_rows
        ]

        return BackupStatusResponse(
            drive=drive,
            path=current_path,
            total_files=total_files,
            hashed_files=hashed_files,
            backed_up_files=backed_up_files,
            backup_drives=backup_drives,
        )
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


@router.get("/{file_id}/media", response_model=MediaMetadataResponse)
async def get_file_media_metadata(file_id: int) -> MediaMetadataResponse:
    """Get media metadata for a specific file.

    Returns video metadata (duration, codec, resolution, etc.) if available.
    Returns 404 if the file doesn't exist or has no media metadata.
    """
    conn = get_connection()
    try:
        # Check file exists
        file_row = conn.execute(
            "SELECT id FROM files WHERE id = ?", (file_id,)
        ).fetchone()

        if not file_row:
            raise HTTPException(status_code=404, detail=f"File with ID {file_id} not found")

        # Get media metadata
        row = conn.execute(
            """
            SELECT file_id, duration_seconds, codec_name, width, height,
                   frame_rate, bit_rate, integrity_verified_at, integrity_errors
            FROM media_metadata
            WHERE file_id = ?
            """,
            (file_id,),
        ).fetchone()

        if not row:
            raise HTTPException(
                status_code=404,
                detail=f"No media metadata found for file ID {file_id}",
            )

        return MediaMetadataResponse(
            file_id=row["file_id"],
            duration_seconds=row["duration_seconds"],
            codec_name=row["codec_name"],
            width=row["width"],
            height=row["height"],
            frame_rate=row["frame_rate"],
            bit_rate=row["bit_rate"],
            integrity_verified_at=row["integrity_verified_at"],
            integrity_errors=row["integrity_errors"],
        )
    finally:
        conn.close()
