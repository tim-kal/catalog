"""Error code endpoints for DriveCatalog API."""

from fastapi import APIRouter

from drivecatalog.errors import get_all_error_codes, get_error_summary, get_recent_errors

router = APIRouter(tags=["errors"])


@router.get("/errors")
async def list_errors(limit: int = 50) -> list[dict]:
    """Return recent error log entries, newest first."""
    return get_recent_errors(limit=limit)


@router.get("/errors/summary")
async def error_summary() -> dict:
    """Return error counts grouped by code and severity, plus recent entries."""
    return get_error_summary()


@router.get("/errors/codes")
async def error_codes() -> list[dict]:
    """Return all registered error code definitions."""
    return get_all_error_codes()
