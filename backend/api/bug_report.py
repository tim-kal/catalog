"""POST /api/bug-report — Create a GitHub Issue from an in-app bug report.

Rate limited to 5 reports per device_id per calendar day.
Requires environment variables: GITHUB_TOKEN, GITHUB_REPO.
"""

from http.server import BaseHTTPRequestHandler
import json
import os
import urllib.request
import urllib.error
from datetime import date

# In-memory rate limit store.  Persists across warm invocations on the same
# Vercel instance.  For production scale, swap for Vercel KV / Upstash Redis.
_rate_limits: dict[str, dict[str, int]] = {}  # {device_id: {date_str: count}}

MAX_REPORTS_PER_DAY = 5


def _check_rate_limit(device_id: str) -> bool:
    """Return True if the device is within its daily quota."""
    today = date.today().isoformat()
    entry = _rate_limits.get(device_id)
    if entry is None or today not in entry:
        _rate_limits[device_id] = {today: 0}
    return _rate_limits[device_id][today] < MAX_REPORTS_PER_DAY


def _increment_rate_limit(device_id: str):
    today = date.today().isoformat()
    _rate_limits.setdefault(device_id, {})[today] = (
        _rate_limits.get(device_id, {}).get(today, 0) + 1
    )


def _create_github_issue(title: str, body: str) -> dict:
    """Create a GitHub issue and return the API response dict."""
    token = os.environ["GITHUB_TOKEN"]
    repo = os.environ["GITHUB_REPO"]

    url = f"https://api.github.com/repos/{repo}/issues"
    payload = json.dumps({
        "title": title,
        "body": body,
        "labels": ["bug-report", "from-app"],
    }).encode()

    req = urllib.request.Request(
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
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


class handler(BaseHTTPRequestHandler):
    def do_POST(self):
        # --- Parse body ---
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(content_length)) if content_length else {}
        except (json.JSONDecodeError, ValueError):
            self._json_response(400, {"error": "Invalid JSON body"})
            return

        # --- Validate required fields ---
        device_id = body.get("device_id")
        title = body.get("title")
        description = body.get("description", "")

        if not device_id:
            self._json_response(400, {"error": "device_id is required"})
            return
        if not title:
            self._json_response(400, {"error": "title is required"})
            return

        # --- Check env vars ---
        if not os.environ.get("GITHUB_TOKEN") or not os.environ.get("GITHUB_REPO"):
            self._json_response(500, {"error": "Server misconfigured: missing GITHUB_TOKEN or GITHUB_REPO"})
            return

        # --- Rate limit ---
        if not _check_rate_limit(device_id):
            self._json_response(429, {
                "error": "Rate limit exceeded",
                "detail": f"Maximum {MAX_REPORTS_PER_DAY} bug reports per device per day",
            })
            return

        # --- Build structured issue body ---
        app_version = body.get("app_version", "unknown")
        os_version = body.get("os_version", "unknown")
        log_snippet = body.get("log_snippet") or body.get("backend_log", "")
        email = body.get("email", "")

        issue_body_parts = [
            "## Bug Report",
            "",
            f"**Description:** {description}",
            "",
            "### Environment",
            f"- **App Version:** {app_version}",
            f"- **OS Version:** {os_version}",
            f"- **Device ID:** {device_id}",
        ]

        if log_snippet:
            issue_body_parts += [
                "",
                "### Log Snippet",
                "```",
                log_snippet,
                "```",
            ]

        if email:
            issue_body_parts += [
                "",
                f"**Reporter email:** {email}",
            ]

        issue_body_parts += [
            "",
            "---",
            "*Submitted via in-app bug reporter*",
        ]

        issue_body = "\n".join(issue_body_parts)

        # --- Create GitHub issue ---
        try:
            result = _create_github_issue(title, issue_body)
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else ""
            self._json_response(502, {
                "error": "Failed to create GitHub issue",
                "detail": f"GitHub API returned {e.code}: {error_body}",
            })
            return
        except Exception as e:
            self._json_response(502, {
                "error": "Failed to create GitHub issue",
                "detail": str(e),
            })
            return

        # --- Success — increment rate limit and respond ---
        _increment_rate_limit(device_id)

        self._json_response(201, {
            "status": "created",
            "issue_url": result.get("html_url", ""),
            "issue_number": result.get("number"),
        })

    def _json_response(self, status_code: int, data: dict):
        body = json.dumps(data).encode()
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass
