"""Pydantic models for DriveCatalog API."""

from .drive import (
    DriveCreateRequest,
    DriveListResponse,
    DriveResponse,
    DriveStatusResponse,
)
from .file import (
    DuplicateCluster,
    DuplicateFile,
    DuplicateListResponse,
    DuplicateStatsResponse,
    FileListResponse,
    FileResponse,
    SearchResultResponse,
)
from .scan import (
    CopyRequest,
    CopyResultResponse,
    MediaMetadataResponse,
    OperationResponse,
    ScanResultResponse,
)

__all__ = [
    # Drive models
    "DriveResponse",
    "DriveListResponse",
    "DriveCreateRequest",
    "DriveStatusResponse",
    # File models
    "FileResponse",
    "FileListResponse",
    "DuplicateFile",
    "DuplicateCluster",
    "DuplicateStatsResponse",
    "DuplicateListResponse",
    "SearchResultResponse",
    # Scan/Operation models
    "ScanResultResponse",
    "OperationResponse",
    "CopyRequest",
    "CopyResultResponse",
    "MediaMetadataResponse",
]
