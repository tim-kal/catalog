"""Pydantic models for consolidation analysis API responses."""

from __future__ import annotations

from pydantic import BaseModel


# --- Distribution models ---


class DriveDistribution(BaseModel):
    """Per-drive file distribution with unique/duplicated classification."""

    drive_id: int
    drive_name: str
    total_files: int
    total_size_bytes: int
    unique_files: int
    unique_size_bytes: int
    duplicated_files: int
    duplicated_size_bytes: int
    reclaimable_bytes: int
    total_bytes: int | None
    used_bytes: int | None
    free_bytes: int | None


class DriveDistributionResponse(BaseModel):
    """Response wrapping per-drive distribution list."""

    drives: list[DriveDistribution]
    total_drives: int


# --- Consolidation candidate models ---


class TargetDrive(BaseModel):
    """A potential target drive for consolidation."""

    drive_name: str
    free_bytes: int


class ConsolidationCandidate(BaseModel):
    """Per-drive consolidation candidacy information."""

    drive_id: int
    drive_name: str
    total_files: int
    total_size_bytes: int
    unique_files: int
    unique_size_bytes: int
    duplicated_files: int
    duplicated_size_bytes: int
    reclaimable_bytes: int
    is_candidate: bool
    total_available_space: int
    target_drives: list[TargetDrive]


class ConsolidationCandidatesResponse(BaseModel):
    """Response wrapping consolidation candidates list."""

    candidates: list[ConsolidationCandidate]
    total_drives: int
    consolidatable_count: int


# --- Strategy models ---


class StrategyFile(BaseModel):
    """A file in the consolidation strategy."""

    path: str
    size_bytes: int
    partial_hash: str | None


class StrategyAssignment(BaseModel):
    """Files assigned to a specific target drive."""

    target_drive: str
    file_count: int
    total_bytes: int
    files: list[StrategyFile]


class StrategyTargetDrive(BaseModel):
    """Target drive capacity impact from strategy."""

    drive_name: str
    capacity_bytes: int
    free_before: int
    free_after: int


class ConsolidationStrategyResponse(BaseModel):
    """Response for a consolidation strategy computation."""

    source_drive: str
    total_unique_files: int
    total_unique_bytes: int
    total_bytes_to_transfer: int
    is_feasible: bool
    assignments: list[StrategyAssignment]
    unplaceable: list[StrategyFile]
    target_drives: list[StrategyTargetDrive]
