"""Bug report endpoint — creates GitHub issues directly via the GitHub API.

Token resolution order:
1. ~/.drivecatalog/config.yaml (github_token, github_repo)
2. App bundle Resources/.secrets/github_token (embedded at build time, never in git)
3. If neither → 503

Rate limited to 5 reports per hour in-process.
"""

import json
import logging
import os
import time
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from drivecatalog.config import load_config

logger = logging.getLogger(__name__)

_FALLBACK_REPO = "tim-kal/catalog"


def _load_bundle_token() -> str | None:
    """Read the GitHub token embedded in the app bundle by scripts/embed-secrets.sh."""
    # The app bundle is at .../DriveCatalog.app/Contents/Resources/.secrets/github_token
    # The Python backend runs from within the app or from the source tree.
    # Try multiple locations.
    candidates = [
        # Running inside app bundle (release)
        Path(__file__).resolve().parents[4] / "Resources" / ".secrets" / "github_token",
        # Source tree (dev builds via build script)
        Path(__file__).resolve().parents[4] / ".secrets" / "github_token",
    ]
    # Also check the SRCROOT-relative path for xcodebuild builds
    srcroot = os.environ.get("SRCROOT")
    if srcroot:
        candidates.append(Path(srcroot) / ".secrets" / "github_token")

    for path in candidates:
        if path.is_file():
            try:
                token = path.read_text().strip()
                if token:
                    return token
            except OSError:
                pass
    return None

router = APIRouter(prefix="/bug-report", tags=["bug-report"])

# Simple in-process rate limiter: {device_id: [timestamps]}
_recent_reports: dict[str, list[float]] = defaultdict(list)
MAX_REPORTS_PER_HOUR = 5


class BugReportRequest(BaseModel):
    device_id: str
    title: str
    description: str = ""
    app_version: str = "unknown"
    os_version: str = "unknown"
    email: str = ""
    backend_log: str = ""
    recent_errors: list[dict] | None = None


class BugReportResponse(BaseModel):
    status: str
    issue_url: str = ""
    issue_number: int | None = None


def _check_rate_limit(device_id: str) -> bool:
    now = time.time()
    cutoff = now - 3600
    _recent_reports[device_id] = [t for t in _recent_reports[device_id] if t > cutoff]
    return len(_recent_reports[device_id]) < MAX_REPORTS_PER_HOUR


@router.post("", response_model=BugReportResponse, status_code=201)
async def create_bug_report(req: BugReportRequest) -> BugReportResponse:
    """Create a GitHub issue from an in-app bug report."""
    config = load_config()
    token = config.github_token or _load_bundle_token()
    repo = config.github_repo or _FALLBACK_REPO

    if not token:
        raise HTTPException(
            status_code=503,
            detail="Bug reporting not configured. Set github_token in ~/.drivecatalog/config.yaml",
        )

    if not _check_rate_limit(req.device_id):
        raise HTTPException(429, f"Rate limit: max {MAX_REPORTS_PER_HOUR} reports per hour")

    # Build issue body
    parts = [
        "## Bug Report",
        "",
        f"**Description:** {req.description}",
        "",
        "### Environment",
        f"- **App Version:** {req.app_version}",
        f"- **OS Version:** {req.os_version}",
        f"- **Device ID:** {req.device_id}",
    ]

    if req.email:
        parts.append(f"- **Reporter:** {req.email}")

    if req.recent_errors:
        parts += ["", "### Recent Errors"]
        for err in req.recent_errors[:10]:
            code = err.get("code", "?")
            title = err.get("title", "?")
            parts.append(f"- `{code}`: {title}")

    if req.backend_log:
        parts += ["", "### Backend Log", "```", req.backend_log[-3000:], "```"]

    parts += ["", "---", "*Submitted via in-app bug reporter*"]
    issue_body = "\n".join(parts)

    # POST to GitHub API
    url = f"https://api.github.com/repos/{repo}/issues"
    payload = json.dumps({
        "title": req.title,
        "body": issue_body,
        "labels": ["bug-report", "from-app"],
    }).encode()

    gh_req = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )

    try:
        with urllib.request.urlopen(gh_req, timeout=15) as resp:
            result = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:500] if e.fp else str(e.code)
        logger.error("GitHub API error %d: %s", e.code, detail)
        raise HTTPException(502, f"GitHub API returned {e.code}") from None
    except Exception as e:
        logger.error("GitHub API request failed: %s", e)
        raise HTTPException(502, "Failed to reach GitHub API") from None

    _recent_reports[req.device_id].append(time.time())

    return BugReportResponse(
        status="created",
        issue_url=result.get("html_url", ""),
        issue_number=result.get("number"),
    )
