"""Pydantic models for drive-related API responses."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict


class DriveResponse(BaseModel):
    """Response model for a single drive."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    uuid: str | None
    mount_path: str
    total_bytes: int
    last_scan: datetime | None
    file_count: int
    disk_uuid: str | None = None
    device_serial: str | None = None
    fs_fingerprint: str | None = None


class DriveListResponse(BaseModel):
    """Response model for listing drives."""

    drives: list[DriveResponse]
    total: int


class DriveCreateRequest(BaseModel):
    """Request model for creating/registering a drive."""

    path: str
    name: str | None = None


class DriveRecognizeResponse(BaseModel):
    """Response model for drive recognition."""

    status: str  # recognized, not_found, ambiguous, weak_match
    confidence: str  # certain, probable, ambiguous, weak, none
    drive: DriveResponse | None = None
    candidates: list[DriveResponse] | None = None
    mount_path: str | None = None


class DriveStatusResponse(BaseModel):
    """Response model for drive status."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    mounted: bool
    file_count: int
    folder_count: int
    hashed_count: int
    hash_coverage_percent: float
    last_scan: datetime | None
    first_seen: datetime | None
    video_count: int
    image_count: int
    audio_count: int
    # Disk usage (persisted — available even when disconnected)
    used_bytes: int | None = None
    # Drive health
    smart_status: str | None = None  # "Verified", "Failing", "Not Supported"
    media_type: str | None = None  # "SSD", "HDD"
    device_protocol: str | None = None  # "USB", "SATA", etc.
