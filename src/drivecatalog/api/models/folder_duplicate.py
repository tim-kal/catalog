"""Pydantic models for folder-duplicate API responses."""

from __future__ import annotations

from pydantic import BaseModel


class FolderInfo(BaseModel):
    """A folder location with metadata."""

    drive_id: int
    drive_name: str
    folder_path: str
    file_count: int
    total_bytes: int


class ExactMatchGroup(BaseModel):
    """A group of folders with identical file-hash sets."""

    match_type: str  # always "exact"
    hash_count: int
    folders: list[FolderInfo]


class SubsetPair(BaseModel):
    """A pair where one folder's hashes are a proper subset of another's."""

    match_type: str  # always "subset"
    subset_hash_count: int
    superset_hash_count: int
    overlap_percent: float
    subset_folder: FolderInfo
    superset_folder: FolderInfo


class FolderDuplicateStats(BaseModel):
    """Summary statistics for folder duplicate analysis."""

    total_folders_analyzed: int
    exact_match_groups: int
    subset_pairs_found: int


class FolderDuplicateResponse(BaseModel):
    """Top-level response for GET /folder-duplicates."""

    exact_match_groups: list[ExactMatchGroup]
    subset_pairs: list[SubsetPair]
    stats: FolderDuplicateStats
