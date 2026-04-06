# DriveSnapshots — State

## What It Is
**DriveCatalog** — a macOS desktop app (SwiftUI frontend + Python/FastAPI backend) for cataloging external drives, detecting duplicates, browsing files, and managing consolidation/migration workflows. Currently at v1.2.

## Architecture
- **Frontend**: SwiftUI macOS app (14.0+, Swift 5.9). ~12k lines across 43 Swift files. Uses `NavigationSplitView` with sidebar tabs: Drives, Files, Backups, Insights, Action Queue, Consolidate (hidden by default), Settings.
- **Backend**: Python FastAPI server (`src/drivecatalog/`). ~5.4k lines across 30+ modules. Started as an embedded subprocess by `BackendService.swift`. CORS wide open for local access.
- **Database**: SQLite with WAL mode at `~/.drivecatalog/catalog.db`. Custom migration system in `migrations.py`.
- **Build**: XcodeGen (`project.yml`). Embedded Python runtime in app bundle for release; `uv` fallback for dev.
- **Communication**: Swift frontend calls Python backend via HTTP (localhost). `APIService.swift` is the HTTP client.

## Key Subsystems
| Area | Backend | Frontend |
|------|---------|----------|
| Drive management | `drives.py`, routes/drives | DrivesView, DriveDetailView, AddDriveSheet |
| File scanning | `scanner.py`, `hasher.py` | (driven by backend, status shown in UI) |
| Duplicate detection | `duplicates.py`, routes/duplicates | DuplicatesView, DuplicateClusterRow, ReclaimSheet |
| File browsing | routes/files, `search.py` | BrowserView, FileRow, SearchView |
| Insights | `insights.py`, routes/insights | InsightsView |
| Consolidation | `consolidation.py`, routes/consolidation | ConsolidatePageView, ConsolidationWizardView |
| Migration | `migration.py`, routes/migrations | (UI TBD) |
| Actions/Ops | `audit.py`, routes/actions, operations | ActionQueueView, ActionDrillDownView |
| Copy/Verify | `copier.py`, `verifier.py`, routes/copy | CopySheet |
| Updates/Beta | (external) | UpdateService, BetaService, LicenseManager |

## Recent Activity (last ~10 commits)
Active feature work: drive rename, sort headers, clear data dialog, how-it-works guide, quick-check reliability improvements, search improvements, beta access system, auto-updater, insights simplification. Project is in active development with frequent commits.

## Migrate Orchestrator
Project is configured with migrate orchestrator (`config.yaml`). Using Claude Opus 4.6. Design files exist but are fresh (first orient).
