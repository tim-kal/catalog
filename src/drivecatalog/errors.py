"""Structured error codes for DriveCatalog user support.

Provides a registry of error codes (DC-E001..DC-E010), a JSONL error log,
and helpers to include recent errors in API responses and bug reports.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

logger = logging.getLogger(__name__)

# Error log location
ERROR_LOG_PATH = Path.home() / ".drivecatalog" / "errors.jsonl"


@dataclass(frozen=True)
class ErrorCode:
    """Definition of a structured error code."""

    code: str
    title: str
    description: str
    severity: str  # critical | error | warning


# ---- Error Code Registry ----

REGISTRY: dict[str, ErrorCode] = {}


def _register(code: str, title: str, description: str, severity: str) -> ErrorCode:
    ec = ErrorCode(code=code, title=title, description=description, severity=severity)
    REGISTRY[code] = ec
    return ec


DC_E001 = _register(
    "DC-E001",
    "Database Connection Failed",
    "Could not open or create the catalog database.",
    "critical",
)
DC_E002 = _register(
    "DC-E002",
    "Drive Not Found",
    "The specified drive is not registered in the catalog.",
    "error",
)
DC_E003 = _register(
    "DC-E003",
    "Drive Not Mounted",
    "The drive is registered but not currently mounted.",
    "warning",
)
DC_E004 = _register(
    "DC-E004",
    "Scan Permission Denied",
    "Insufficient permissions to read one or more files during scan.",
    "warning",
)
DC_E005 = _register(
    "DC-E005",
    "Hash Computation Failed",
    "Failed to compute file hash due to I/O error.",
    "error",
)
DC_E006 = _register(
    "DC-E006",
    "Migration Failed",
    "Database migration could not be applied. A backup was restored.",
    "critical",
)
DC_E007 = _register(
    "DC-E007",
    "Copy Verification Failed",
    "File copy completed but integrity hash does not match source.",
    "critical",
)
DC_E008 = _register(
    "DC-E008",
    "Drive Recognition Ambiguous",
    "Multiple registered drives match this volume's fingerprint.",
    "warning",
)
DC_E009 = _register(
    "DC-E009",
    "Operation Conflict",
    "An operation is already running on this drive.",
    "error",
)
DC_E010 = _register(
    "DC-E010",
    "Invalid Request",
    "The API request contains invalid or missing parameters.",
    "error",
)


# ---- Error Logging ----


def log_error(code: str, context: dict | None = None) -> None:
    """Append a structured error entry to the JSONL error log.

    Args:
        code: Error code string (e.g. "DC-E001").
        context: Optional dict with extra context (drive name, file path, etc.).
    """
    error_def = REGISTRY.get(code)
    if error_def is None:
        logger.warning("log_error called with unknown code: %s", code)
        return

    entry = {
        "timestamp": datetime.now().isoformat(),
        "code": error_def.code,
        "title": error_def.title,
        "severity": error_def.severity,
    }
    if context:
        entry["context"] = context

    try:
        ERROR_LOG_PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with open(ERROR_LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except OSError:
        logger.exception("Failed to write error log entry")


def get_recent_errors(limit: int = 50) -> list[dict]:
    """Read the most recent error log entries.

    Args:
        limit: Maximum number of entries to return (newest first).

    Returns:
        List of error dicts, newest first.
    """
    if not ERROR_LOG_PATH.exists():
        return []

    entries: list[dict] = []
    try:
        with open(ERROR_LOG_PATH) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
    except OSError:
        return []

    # Return newest first, limited
    return list(reversed(entries[-limit:]))


def get_error_summary() -> dict:
    """Return a summary of error counts by code and severity.

    Returns:
        Dict with total_count, by_code (code -> count), by_severity, and recent (last 5).
    """
    entries = get_recent_errors(limit=1000)
    by_code: dict[str, int] = {}
    by_severity: dict[str, int] = {}

    for entry in entries:
        code = entry.get("code", "unknown")
        severity = entry.get("severity", "unknown")
        by_code[code] = by_code.get(code, 0) + 1
        by_severity[severity] = by_severity.get(severity, 0) + 1

    return {
        "total_count": len(entries),
        "by_code": by_code,
        "by_severity": by_severity,
        "recent": entries[:5],
    }


def get_bug_report_errors(limit: int = 10) -> list[dict]:
    """Get the last N errors formatted for inclusion in bug reports.

    Args:
        limit: Number of recent errors to include.

    Returns:
        List of error dicts for the bug report payload.
    """
    return get_recent_errors(limit=limit)


def get_all_error_codes() -> list[dict]:
    """Return all registered error code definitions.

    Returns:
        List of dicts with code, title, description, severity.
    """
    return [asdict(ec) for ec in REGISTRY.values()]
