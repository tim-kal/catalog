"""Verification tests for DC-006: backend Vercel serverless endpoints.

Tests the handler classes directly by simulating HTTP requests via
the BaseHTTPRequestHandler interface without needing a running server.
"""

import importlib
import io
import json
import os
import sys
import unittest
from http.server import HTTPServer
from threading import Thread
from unittest.mock import patch, MagicMock

# Add backend/api to path so imports work
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

from api import register, heartbeat, bug_report


def _make_request(handler_cls, method, body=None):
    """Spin up a tiny server, send one request, return (status, parsed_json)."""
    server = HTTPServer(("127.0.0.1", 0), handler_cls)
    port = server.server_address[1]

    t = Thread(target=server.handle_request, daemon=True)
    t.start()

    import urllib.request
    import urllib.error

    payload = json.dumps(body).encode() if body else b""
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/",
        data=payload,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())
    finally:
        t.join(timeout=5)
        server.server_close()


class TestRegister(unittest.TestCase):
    def test_register_success(self):
        status, data = _make_request(register.handler, "POST", {
            "device_id": "test-device-1",
            "app_version": "1.0.0",
            "os_version": "macOS 14.0",
        })
        self.assertEqual(status, 200)
        self.assertEqual(data["status"], "registered")
        self.assertEqual(data["device_id"], "test-device-1")

    def test_register_missing_device_id(self):
        status, data = _make_request(register.handler, "POST", {
            "app_version": "1.0.0",
        })
        self.assertEqual(status, 400)
        self.assertIn("device_id", data["error"])


class TestHeartbeat(unittest.TestCase):
    def test_heartbeat_success(self):
        status, data = _make_request(heartbeat.handler, "POST", {
            "device_id": "test-device-1",
        })
        self.assertEqual(status, 200)
        self.assertEqual(data["status"], "ok")

    def test_heartbeat_missing_device_id(self):
        status, data = _make_request(heartbeat.handler, "POST", {})
        self.assertEqual(status, 400)
        self.assertIn("device_id", data["error"])


class TestBugReport(unittest.TestCase):
    def setUp(self):
        bug_report._rate_limits.clear()

    @patch.dict(os.environ, {"GITHUB_TOKEN": "test-token", "GITHUB_REPO": "owner/repo"})
    @patch("api.bug_report._create_github_issue")
    def test_bug_report_success(self, mock_create):
        mock_create.return_value = {
            "html_url": "https://github.com/owner/repo/issues/42",
            "number": 42,
        }
        status, data = _make_request(bug_report.handler, "POST", {
            "device_id": "dev-1",
            "title": "App crashes on launch",
            "description": "Crash when opening the app",
            "app_version": "1.0.0",
            "os_version": "macOS 14.0",
            "log_snippet": "ERROR: nil pointer",
            "email": "user@example.com",
        })
        self.assertEqual(status, 201)
        self.assertEqual(data["status"], "created")
        self.assertEqual(data["issue_url"], "https://github.com/owner/repo/issues/42")
        self.assertEqual(data["issue_number"], 42)

        # Verify the issue body was structured correctly
        call_args = mock_create.call_args
        issue_body = call_args[0][1]
        self.assertIn("App Version:** 1.0.0", issue_body)
        self.assertIn("OS Version:** macOS 14.0", issue_body)
        self.assertIn("ERROR: nil pointer", issue_body)
        self.assertIn("user@example.com", issue_body)
    def test_bug_report_labels_in_source(self):
        """Verify _create_github_issue source contains correct labels."""
        src_path = os.path.join(os.path.dirname(__file__), "..", "backend", "api", "bug_report.py")
        with open(src_path) as f:
            src = f.read()
        self.assertIn('"bug-report"', src)
        self.assertIn('"from-app"', src)

    def test_bug_report_missing_title(self):
        status, data = _make_request(bug_report.handler, "POST", {
            "device_id": "dev-1",
        })
        self.assertEqual(status, 400)
        self.assertIn("title", data["error"])

    def test_bug_report_missing_device_id(self):
        status, data = _make_request(bug_report.handler, "POST", {
            "title": "Some bug",
        })
        self.assertEqual(status, 400)
        self.assertIn("device_id", data["error"])

    @patch.dict(os.environ, {"GITHUB_TOKEN": "test-token", "GITHUB_REPO": "owner/repo"})
    @patch("api.bug_report._create_github_issue")
    def test_rate_limiting(self, mock_create):
        mock_create.return_value = {"html_url": "https://github.com/owner/repo/issues/1", "number": 1}

        device_id = "rate-limit-test"
        for i in range(5):
            status, data = _make_request(bug_report.handler, "POST", {
                "device_id": device_id,
                "title": f"Bug #{i+1}",
            })
            self.assertEqual(status, 201, f"Request {i+1} should succeed")

        # 6th request should be rate-limited
        status, data = _make_request(bug_report.handler, "POST", {
            "device_id": device_id,
            "title": "Bug #6",
        })
        self.assertEqual(status, 429)
        self.assertIn("Rate limit", data["error"])

    @patch.dict(os.environ, {"GITHUB_TOKEN": "test-token", "GITHUB_REPO": "owner/repo"})
    @patch("api.bug_report._create_github_issue")
    def test_rate_limit_different_devices(self, mock_create):
        mock_create.return_value = {"html_url": "https://github.com/owner/repo/issues/1", "number": 1}

        # Fill rate limit for device A
        for i in range(5):
            _make_request(bug_report.handler, "POST", {
                "device_id": "device-A",
                "title": f"Bug #{i+1}",
            })

        # Device B should still work
        status, data = _make_request(bug_report.handler, "POST", {
            "device_id": "device-B",
            "title": "Bug from B",
        })
        self.assertEqual(status, 201)

    def test_missing_env_vars(self):
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("GITHUB_TOKEN", None)
            os.environ.pop("GITHUB_REPO", None)
            status, data = _make_request(bug_report.handler, "POST", {
                "device_id": "dev-1",
                "title": "Some bug",
            })
            self.assertEqual(status, 500)
            self.assertIn("misconfigured", data["error"])

    @patch.dict(os.environ, {"GITHUB_TOKEN": "test-token", "GITHUB_REPO": "owner/repo"})
    @patch("api.bug_report._create_github_issue")
    def test_issue_url_returned(self, mock_create):
        expected_url = "https://github.com/owner/repo/issues/99"
        mock_create.return_value = {"html_url": expected_url, "number": 99}
        status, data = _make_request(bug_report.handler, "POST", {
            "device_id": "dev-url",
            "title": "URL test",
        })
        self.assertEqual(status, 201)
        self.assertEqual(data["issue_url"], expected_url)


if __name__ == "__main__":
    unittest.main()
