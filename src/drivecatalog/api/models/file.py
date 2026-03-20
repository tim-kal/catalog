"""Pydantic models for file-related API responses."""

from __future__ import annotations

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


# --- Protection / Backup models ---


class FileLocation(BaseModel):
    """A file location within a file group."""

    drive_name: str
    path: str
    file_id: int


class FileGroup(BaseModel):
    """A group of files sharing the same hash, classified by protection status."""

    filename: str
    partial_hash: str
    size_bytes: int
    total_copies: int
    drive_count: int
    status: str  # unprotected, same_drive_duplicate, backed_up, over_backed_up
    same_drive_extras: int
    reclaimable_bytes: int
    locations: list[FileLocation]


class ProtectionStats(BaseModel):
    """System-wide protection and storage statistics."""

    total_drives: int
    total_files: int
    total_storage_bytes: int
    hashed_files: int
    unhashed_files: int
    unique_hashes: int
    unprotected_files: int
    unprotected_bytes: int
    backed_up_files: int
    backed_up_bytes: int
    over_backed_up_files: int
    over_backed_up_bytes: int
    same_drive_duplicate_count: int
    reclaimable_bytes: int
    backup_coverage_percent: float


class DriveProtectionStats(BaseModel):
    """Per-drive protection statistics."""

    drive_name: str
    total_files: int
    total_bytes: int
    hashed_files: int
    unhashed_files: int
    unprotected_files: int
    unprotected_bytes: int
    backed_up_files: int
    backed_up_bytes: int
    over_backed_up_files: int
    over_backed_up_bytes: int
    same_drive_duplicate_count: int
    reclaimable_bytes: int


class ProtectionResponse(BaseModel):
    """Full response for the backups/protection page (flat list)."""

    groups: list[FileGroup]
    stats: ProtectionStats


class DirectoryProtection(BaseModel):
    """Protection stats for a single directory."""

    path: str
    total_files: int
    total_bytes: int
    unhashed_files: int
    unprotected_files: int
    unprotected_bytes: int
    backed_up_files: int
    backed_up_bytes: int
    over_backed_up_files: int
    over_backed_up_bytes: int


class DriveProtectionSummary(BaseModel):
    """Drive-level protection summary with directory breakdown."""

    drive_name: str
    total_files: int
    total_bytes: int
    unprotected_files: int
    backed_up_files: int
    over_backed_up_files: int
    directories: list[DirectoryProtection]


class ProtectionTreeResponse(BaseModel):
    """Hierarchical protection view: drives > directories."""

    drives: list[DriveProtectionSummary]
    stats: ProtectionStats


# --- Verification models ---


class VerificationRequest(BaseModel):
    """Request to verify files are true duplicates before deletion."""

    file_ids: list[int]


class FileVerificationResult(BaseModel):
    """Verification result for a single file."""

    file_id: int
    drive_name: str
    path: str
    verification_hash: str | None
    accessible: bool


class VerificationResponse(BaseModel):
    """Response from verification hash computation."""

    verified: bool  # True if all accessible files have matching verification hashes
    results: list[FileVerificationResult]
    matching_hash: str | None  # The common hash if all match, None otherwise


# --- Legacy duplicate models (kept for backwards compat) ---


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


# --- Search models ---


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
