"""Pydantic models for file-related API responses."""

from pydantic import BaseModel, ConfigDict


class FileResponse(BaseModel):
    """Response model for a single file."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    drive_id: int
    drive_name: str
    path: str
    filename: str
    size_bytes: int
    mtime: str | None
    partial_hash: str | None
    is_media: bool


class FileListResponse(BaseModel):
    """Response model for listing files."""

    files: list[FileResponse]
    total: int
    page: int
    page_size: int


class DuplicateFile(BaseModel):
    """A file within a duplicate cluster."""

    drive_name: str
    path: str
    file_id: int


class DuplicateCluster(BaseModel):
    """A cluster of duplicate files sharing the same hash."""

    partial_hash: str
    size_bytes: int
    count: int
    reclaimable_bytes: int
    files: list[DuplicateFile]


class DuplicateStatsResponse(BaseModel):
    """Statistics about duplicates in the catalog."""

    total_clusters: int
    total_duplicate_files: int
    total_bytes: int
    reclaimable_bytes: int


class DuplicateListResponse(BaseModel):
    """Response model for listing duplicates."""

    clusters: list[DuplicateCluster]
    stats: DuplicateStatsResponse


class SearchFile(BaseModel):
    """File result from search query (simplified view)."""

    drive_name: str
    path: str
    size_bytes: int
    mtime: str | None


class SearchResultResponse(BaseModel):
    """Response model for search results."""

    files: list[SearchFile]
    total: int
    pattern: str
