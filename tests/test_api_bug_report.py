"""Tests for the local /bug-report endpoint."""

from unittest.mock import patch, MagicMock

from drivecatalog.config import Config


def test_bug_report_rejects_without_config(test_client):
    """Returns 503 when github_token is not configured."""
    with patch("drivecatalog.api.routes.bug_report.load_config", return_value=Config()):
        resp = test_client.post("/bug-report", json={
            "device_id": "dev-1",
            "title": "Test bug",
            "description": "Something broke",
        })
    assert resp.status_code == 503
    assert "github_token" in resp.json()["detail"]


def test_bug_report_success(test_client):
    """Successful bug report creates a GitHub issue and returns 201."""
    mock_config = Config(github_token="ghp_test", github_repo="owner/repo")

    mock_resp = MagicMock()
    mock_resp.read.return_value = b'{"html_url": "https://github.com/owner/repo/issues/42", "number": 42}'
    mock_resp.__enter__ = lambda s: s
    mock_resp.__exit__ = MagicMock(return_value=False)

    with patch("drivecatalog.api.routes.bug_report.load_config", return_value=mock_config), \
         patch("drivecatalog.api.routes.bug_report.urllib.request.urlopen", return_value=mock_resp):
        resp = test_client.post("/bug-report", json={
            "device_id": "dev-1",
            "title": "App crashes",
            "description": "Crash on launch",
            "app_version": "1.4.2",
            "email": "user@test.com",
        })

    assert resp.status_code == 201
    data = resp.json()
    assert data["status"] == "created"
    assert data["issue_url"] == "https://github.com/owner/repo/issues/42"
    assert data["issue_number"] == 42


def test_bug_report_github_error(test_client):
    """Returns 502 when GitHub API rejects the request."""
    import urllib.error
    mock_config = Config(github_token="ghp_test", github_repo="owner/repo")

    err = urllib.error.HTTPError("url", 403, "Forbidden", {}, None)

    with patch("drivecatalog.api.routes.bug_report.load_config", return_value=mock_config), \
         patch("drivecatalog.api.routes.bug_report.urllib.request.urlopen", side_effect=err):
        resp = test_client.post("/bug-report", json={
            "device_id": "dev-1",
            "title": "Test",
        })

    assert resp.status_code == 502
