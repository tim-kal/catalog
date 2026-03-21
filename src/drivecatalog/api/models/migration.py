"""Pydantic models for migration API request/response payloads."""

from __future__ import annotations

from pydantic import BaseModel


# --- Request models ---


class GeneratePlanRequest(BaseModel):
    """Request to generate a migration plan for a source drive."""

    source_drive: str


# --- File-level response models ---


class MigrationFileResponse(BaseModel):
    """A single file in a migration plan."""

    id: int
    source_path: str
    source_size_bytes: int
    target_drive_name: str | None
    target_path: str | None
    action: str
    status: str
    error: str | None


class FileStatusCount(BaseModel):
    """Count and bytes for a specific file status."""

    count: int
    bytes: int


# --- Plan response models ---


class MigrationPlanSummary(BaseModel):
    """Brief plan info returned after generation."""

    plan_id: int
    source_drive: str
    status: str
    total_files: int
    files_to_copy: int
    files_to_delete: int
    total_bytes_to_transfer: int
    is_feasible: bool


class MigrationPlanResponse(BaseModel):
    """Full migration plan details."""

    plan_id: int
    source_drive_name: str
    status: str
    total_files: int
    files_to_copy: int
    files_to_delete: int
    total_bytes_to_transfer: int
    files_completed: int
    bytes_transferred: int
    files_failed: int
    errors: list[str]
    operation_id: str | None
    created_at: str
    started_at: str | None
    completed_at: str | None
    file_status_counts: dict[str, FileStatusCount]


# --- Validation response models ---


class TargetSpaceInfo(BaseModel):
    """Free space check for a target drive."""

    drive_name: str
    bytes_needed: int
    bytes_available: int
    sufficient: bool


class ValidatePlanResponse(BaseModel):
    """Result of plan validation."""

    plan_id: int
    status: str
    valid: bool
    target_space: list[TargetSpaceInfo]


# --- File list response ---


class MigrationFilesResponse(BaseModel):
    """Paginated list of migration files."""

    plan_id: int
    files: list[MigrationFileResponse]
    total: int


# --- Execution response ---


class ExecuteResponse(BaseModel):
    """Response after starting migration execution."""

    plan_id: int
    operation_id: str
    status: str
    poll_url: str
