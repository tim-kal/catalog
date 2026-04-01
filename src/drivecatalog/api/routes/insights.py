"""Insights endpoint for DriveCatalog API."""

from __future__ import annotations

from fastapi import APIRouter

from drivecatalog.database import get_connection
from drivecatalog.insights import get_insights

from ..models.insights import (
    AtRiskContent,
    ConsolidationSummary,
    DriveRisk,
    InsightsHealth,
    InsightsResponse,
    RecommendedAction,
)

router = APIRouter(prefix="/insights", tags=["insights"])


@router.get("", response_model=InsightsResponse)
async def insights() -> InsightsResponse:
    """Compute actionable insights across all drives."""
    conn = get_connection()
    try:
        raw = get_insights(conn)
    finally:
        conn.close()

    return InsightsResponse(
        health=InsightsHealth(**raw["health"]),
        drive_risks=[DriveRisk(**d) for d in raw["drive_risks"]],
        at_risk_content=[AtRiskContent(**c) for c in raw["at_risk_content"]],
        actions=[RecommendedAction(**a) for a in raw["actions"]],
        consolidation=ConsolidationSummary(**raw["consolidation"]),
    )
