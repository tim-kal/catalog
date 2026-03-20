# Project Milestones: DriveCatalog

## v1.0 MVP (Shipped: 2026-01-24)

**Delivered:** Complete macOS CLI tool for cataloging external drives, detecting duplicates via partial hashing, and performing verified media transfers with mount automation.

**Phases completed:** 1-11 (14 plans total)

**Key accomplishments:**
- SQLite catalog with drives/files/media_metadata tables at ~/.drivecatalog/catalog.db
- macOS drive detection via diskutil with `drives add/list` commands
- File scanner with change detection (size+mtime) and Rich progress display
- Duplicate detection via xxHash partial hashing with reclaimable space analysis
- Verified copy with streaming SHA256 two-pass integrity verification
- Mount automation via FSEvents watcher with auto-scan on registered drives
- Media intelligence with ffprobe metadata extraction and container integrity verification

**Stats:**
- 48 files created/modified
- 2,359 lines of Python
- 11 phases, 14 plans
- 2 days from start to ship

**Git range:** `feat(01-01)` → `feat(11-01)`

**What's next:** v1.1 UI milestone

---

## v1.1 UI (Shipped: 2026-03-21)

**Delivered:** Native SwiftUI macOS desktop app backed by FastAPI server. Full drive management, Finder-style file browser, duplicate dashboard, search, verified copy wizard, and settings — all with real-time operation polling and background task support.

**Phases completed:** 12-20 (18 plans total)

**Key accomplishments:**
- FastAPI server with Pydantic models, CORS, background operations with progress tracking
- SwiftUI app with sidebar navigation, drive cards with storage bars, status indicators
- Finder-style column browser with folder expansion, backup coverage display, hover popovers
- Duplicate detection dashboard with reclaim analysis and cluster expansion
- Search with glob patterns and filters across all drives
- Verified copy wizard with progress polling
- Settings with health check, database stats
- Incremental smart scan with folder_stats caching
- Drive recognition via UUID, disk usage persistence for disconnected drives
- Integrity verification endpoint (scan + hash + duplicate checks)

**Stats:**
- 37 files, ~7,800 lines added
- 9 phases, 18 plans
- SwiftUI + FastAPI full-stack

**Git range:** Phase 12 → `5aed64b`

**What's next:** v2.0 Drive Consolidation Optimizer

---
