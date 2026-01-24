"""Pydantic models for drive-related API responses."""

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


class DriveListResponse(BaseModel):
    """Response model for listing drives."""

    drives: list[DriveResponse]
    total: int


class DriveCreateRequest(BaseModel):
    """Request model for creating/registering a drive."""

    path: str
    name: str | None = None


class DriveStatusResponse(BaseModel):
    """Response model for drive status."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    mounted: bool
    file_count: int
    hashed_count: int
    hash_coverage_percent: float
