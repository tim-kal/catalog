"""Pydantic models for scan and operation-related API responses."""

from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict


class ScanResultResponse(BaseModel):
    """Response model for scan results."""

    new_files: int
    modified_files: int
    unchanged_files: int
    errors: int
    total_scanned: int


class OperationResponse(BaseModel):
    """Response model for async operations."""

    model_config = ConfigDict(from_attributes=True)

    id: str
    type: str  # scan, hash, copy, media, verify
    status: str  # pending, running, completed, failed
    progress_percent: float | None
    result: dict[str, Any] | None
    error: str | None
    created_at: datetime
    completed_at: datetime | None


class CopyRequest(BaseModel):
    """Request model for file copy operations."""

    source_drive: str
    source_path: str
    dest_drive: str
    dest_path: str | None = None


class CopyResultResponse(BaseModel):
    """Response model for copy operation results."""

    bytes_copied: int
    source_hash: str
    dest_hash: str
    verified: bool


class MediaMetadataResponse(BaseModel):
    """Response model for media file metadata."""

    model_config = ConfigDict(from_attributes=True)

    file_id: int
    duration_seconds: float | None
    codec_name: str | None
    width: int | None
    height: int | None
    frame_rate: str | None
    bit_rate: int | None
    integrity_verified_at: datetime | None
    integrity_errors: str | None
