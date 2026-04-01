"""Pydantic models for the insights API response."""

from __future__ import annotations

from pydantic import BaseModel


class InsightsHealth(BaseModel):
    """Overall backup health summary."""

    backup_coverage_percent: float
    total_files: int
    hashed_files: int
    unhashed_files: int
    unique_hashes: int
    unprotected_hashes: int
    unprotected_bytes: int
    backed_up_hashes: int
    backed_up_bytes: int
    redundant_hashes: int
    redundant_bytes: int
    same_drive_duplicates: int
    reclaimable_bytes: int
    total_drives: int
    total_storage_bytes: int


class DriveRisk(BaseModel):
    """Per-drive risk assessment."""

    drive_name: str
    unprotected_files: int
    unprotected_bytes: int
    total_bytes: int
    used_bytes: int
    free_bytes: int
    free_percent: float
    risk_level: str  # critical, high, moderate, low, safe


class AtRiskContent(BaseModel):
    """Content category at risk."""

    category: str
    icon: str
    file_count: int
    total_bytes: int
    top_extensions: list[str]


class RecommendedAction(BaseModel):
    """A prioritised recommended action."""

    id: str
    priority: int
    title: str
    description: str
    impact_bytes: int
    action_type: str  # backup, cleanup, consolidate
    target: str | None
    icon: str
    color: str


class ConsolidationSummary(BaseModel):
    """Lightweight consolidation status."""

    consolidatable_count: int
    candidate_drives: list[str]
    total_free_bytes: int


class InsightsResponse(BaseModel):
    """Full insights payload."""

    health: InsightsHealth
    drive_risks: list[DriveRisk]
    at_risk_content: list[AtRiskContent]
    actions: list[RecommendedAction]
    consolidation: ConsolidationSummary
