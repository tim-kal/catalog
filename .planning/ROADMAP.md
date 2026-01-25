# Roadmap: DriveCatalog

## Overview

Build a macOS CLI tool for cataloging external drives, detecting duplicates via partial hashing, and performing verified media transfers. Start with database foundation and core scanning, progress through duplicate detection and search, then add mount automation and media-specific features.

## Milestones

- ✅ [v1.0 MVP](milestones/v1.0-ROADMAP.md) (Phases 1-11) — SHIPPED 2026-01-24
- 🚧 **v1.1 UI** — Phases 12-20 (in progress)

## Completed Milestones

<details>
<summary>v1.0 MVP (Phases 1-11) — SHIPPED 2026-01-24</summary>

- [x] Phase 1: Foundation (4/4 plans) — completed 2026-01-23
- [x] Phase 2: Drive Management (1/1 plan) — completed 2026-01-23
- [x] Phase 3: File Scanner (1/1 plan) — completed 2026-01-24
- [x] Phase 4: Partial Hashing (1/1 plan) — completed 2026-01-24
- [x] Phase 5: Duplicate Detection (1/1 plan) — completed 2026-01-24
- [x] Phase 6: Search (1/1 plan) — completed 2026-01-24
- [x] Phase 7: Verified Copy (1/1 plan) — completed 2026-01-24
- [x] Phase 8: Mount Detection (1/1 plan) — completed 2026-01-24
- [x] Phase 9: Config & Auto-scan (1/1 plan) — completed 2026-01-24
- [x] Phase 10: Media Metadata (1/1 plan) — completed 2026-01-24
- [x] Phase 11: Integrity Verification (1/1 plan) — completed 2026-01-24

Full details: [milestones/v1.0-ROADMAP.md](milestones/v1.0-ROADMAP.md)

</details>

## 🚧 v1.1 UI (In Progress)

**Milestone Goal:** Add a native SwiftUI interface to the existing DriveCatalog CLI, providing a polished macOS desktop experience for drive cataloging, duplicate detection, and verified transfers.

### Phase 12: Architecture & Python API ✅

**Goal**: Define Swift↔Python communication pattern and expose existing functionality as API
**Depends on**: v1.0 complete
**Research**: Complete (Swift/Python integration patterns)
**Status**: Complete (5/5 plans)

Plans:
- [x] 12-01: FastAPI foundation with Pydantic models — completed 2026-01-24
- [x] 12-02: Drives API routes (CRUD, status) — completed 2026-01-24
- [x] 12-03: Files, search, and duplicates API routes — completed 2026-01-24
- [x] 12-04: Background operations (scan, hash) — completed 2026-01-24
- [x] 12-05: Copy, media metadata, and integrity routes — completed 2026-01-25

### Phase 13: SwiftUI Project Setup ✅

**Goal**: Create Xcode project with basic app lifecycle, window structure, and navigation shell
**Depends on**: Phase 12
**Research**: Unlikely (standard SwiftUI patterns)
**Status**: Complete (2/2 plans)

Plans:
- [x] 13-01: Xcode project foundation with xcodegen — completed 2026-01-25
- [x] 13-02: Navigation shell with sidebar and placeholder views — completed 2026-01-25

### Phase 14: Swift Data Models ✅

**Goal**: Define Swift types for drives, files, duplicates matching Python database schema
**Depends on**: Phase 13
**Research**: Unlikely (internal patterns)
**Status**: Complete (1/1 plans)

Plans:
- [x] 14-01: Codable Swift structs mirroring Python Pydantic models — completed 2026-01-25

### Phase 15: Drive Management View

**Goal**: List registered drives, add/remove drives, show scan status and last-scanned dates
**Depends on**: Phase 14
**Research**: Unlikely (uses Phase 12 API)
**Status**: In progress (1/3 plans)

Plans:
- [x] 15-01: API Service Foundation (networking layer) — completed 2026-01-25
- [ ] 15-02: Drive List View with add/delete
- [ ] 15-03: Drive Detail View with status and actions

### Phase 16: File Browser

**Goal**: Browse files by drive with tree/list view, show file details, navigate directory structure
**Depends on**: Phase 15
**Research**: Unlikely (standard UI patterns)
**Plans**: TBD

Plans:
- [ ] 16-01: TBD

### Phase 17: Duplicate Dashboard

**Goal**: View duplicate file groups, show reclaimable space, enable group actions (delete, move)
**Depends on**: Phase 16
**Research**: Unlikely (uses existing duplicate detection)
**Plans**: TBD

Plans:
- [ ] 17-01: TBD

### Phase 18: Search Interface

**Goal**: Search files across drives, filter by type/size/date, display results with navigation
**Depends on**: Phase 17
**Research**: Unlikely (standard UI patterns)
**Plans**: TBD

Plans:
- [ ] 18-01: TBD

### Phase 19: Copy & Verify UI

**Goal**: Copy wizard for verified transfers, progress tracking, verification status display
**Depends on**: Phase 18
**Research**: Unlikely (wraps existing copy functionality)
**Plans**: TBD

Plans:
- [ ] 19-01: TBD

### Phase 20: Settings & Mount Automation

**Goal**: Preferences window for app config, auto-scan settings, mount notification alerts
**Depends on**: Phase 19
**Research**: Unlikely (standard macOS patterns)
**Plans**: TBD

Plans:
- [ ] 20-01: TBD

## Progress

| Milestone | Phases | Plans | Status | Completed |
|-----------|--------|-------|--------|-----------|
| v1.0 MVP | 1-11 | 14/14 | Complete | 2026-01-24 |
| v1.1 UI | 12-20 | 11/? | In progress | - |
