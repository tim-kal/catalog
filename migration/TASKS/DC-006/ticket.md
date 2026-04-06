# DC-006 — Feedback/Ticket Pipeline: Vercel Backend → GitHub Issues

## Goal
Build the Vercel serverless backend that receives bug reports from the app and creates GitHub Issues, so the developer gets notified and can track/respond to user feedback.

## Acceptance Criteria
- [ ] Vercel project at `catalog-beta.vercel.app` with the following endpoints:
  - `POST /api/register` — beta user registration (store in Vercel KV or similar)
  - `POST /api/heartbeat` — app usage tracking
  - `POST /api/bug-report` — receives bug report, creates GitHub Issue
- [ ] Bug report endpoint creates a GitHub Issue in the DriveSnapshots repo via GitHub API with:
  - Title from report
  - Body containing: description, app version, OS version, backend log snippet (if included)
  - Label: `bug-report` (auto-created if doesn't exist)
  - Label: `from-app` to distinguish from manually created issues
- [ ] GitHub Issue body includes user email (for follow-up) but NOT in the title (privacy)
- [ ] Rate limiting: max 5 bug reports per device_id per day
- [ ] Response includes the GitHub Issue URL so the app could show it to the user
- [ ] Environment variables: `GITHUB_TOKEN` (repo-scoped PAT), `GITHUB_REPO` (owner/repo)

## Relevant Files
- `DriveCatalog/Services/BetaService.swift` — client-side code that calls these endpoints (already exists, do not modify)
- The Vercel project should live in a new `backend/` directory at the project root

## Context
The app already has a BugReportView that collects title, description, and optionally the backend log. It sends this to `https://catalog-beta.vercel.app/api/bug-report` via BetaService.swift. The Vercel backend needs to actually exist and handle these requests.

The developer wants bug reports to arrive as GitHub Issues so they can be tracked, prioritized, and linked to PRs. Future enhancements (auto-analysis, auto-fix pipeline) are out of scope for this task — just get the basic pipeline working: app → Vercel → GitHub Issue → developer notification.

Tech stack: Vercel serverless functions (TypeScript or Python), GitHub REST API for issue creation.
