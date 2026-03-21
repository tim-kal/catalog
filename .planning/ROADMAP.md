# Roadmap: DriveCatalog

## Overview

Build a macOS CLI tool for cataloging external drives, detecting duplicates via partial hashing, and performing verified media transfers. Start with database foundation and core scanning, progress through duplicate detection and search, then add mount automation and media-specific features.

## Milestones

- [v1.0 MVP](milestones/v1.0-ROADMAP.md) (Phases 1-11) — SHIPPED 2026-01-24
- **v1.1 UI** (Phases 12-20) — SHIPPED 2026-03-21
- **v2.0 Drive Consolidation Optimizer** — Phases 21-23 — SHIPPED 2026-03-21

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

<details>
<summary>v1.1 UI (Phases 12-20) — SHIPPED 2026-03-21</summary>

- [x] Phase 12: Architecture & Python API (5/5 plans) — completed 2026-01-25
- [x] Phase 13: SwiftUI Project Setup (2/2 plans) — completed 2026-01-25
- [x] Phase 14: Swift Data Models (1/1 plan) — completed 2026-01-25
- [x] Phase 15: Drive Management View (3/3 plans) — completed 2026-03-19
- [x] Phase 16: File Browser (1/1 plan) — completed 2026-03-19
- [x] Phase 17: Duplicate Dashboard (1/1 plan) — completed 2026-03-19
- [x] Phase 18: Search Interface (1/1 plan) — completed 2026-03-19
- [x] Phase 19: Copy & Verify UI (1/1 plan) — completed 2026-03-19
- [x] Phase 20: Settings & Mount Automation (1/1 plan) — completed 2026-03-19

</details>

## v2.0 Drive Consolidation Optimizer

**Milestone Goal:** Analyze all cataloged drives to find which files can be moved to free entire drives, generate optimal migration plans, execute with hash-verified transfers and safe deletion, and track the whole process through a SwiftUI migration wizard.

### Phase 21: Consolidation Analysis Engine

**Goal**: User can analyze their drive collection to understand file distribution and identify which drives can be consolidated
**Depends on**: v1.1 complete (existing duplicate detection, file catalog, API layer)
**Requirements**: ANAL-01, ANAL-02, ANAL-03, ANAL-04, ANAL-05
**Success Criteria** (what must be TRUE):
  1. User can hit an API endpoint and see a per-drive breakdown showing unique file count, duplicated file count, total size, and reclaimable space
  2. User can see which drives are candidates for consolidation (all unique files fit on other connected drives with sufficient free space)
  3. User can view target drive capacity information showing which drives can absorb files from a source drive
  4. System produces an optimal consolidation strategy that minimizes total bytes transferred when moving unique files off a source drive
**Plans:** 2 plans

Plans:
- [x] 21-01-PLAN.md — Consolidation analysis module — completed 2026-03-21
- [x] 21-02-PLAN.md — Consolidation analysis API — completed 2026-03-21

### Phase 22: Migration Planning & Execution

**Goal**: User can generate, review, and execute a verified migration plan that safely moves files off a source drive with hash verification and safe deletion
**Depends on**: Phase 21 (consolidation analysis provides the data for planning)
**Requirements**: MIGR-01, MIGR-02, MIGR-03, MIGR-04, MIGR-05, EXEC-01, EXEC-02, EXEC-03, EXEC-04, EXEC-05, EXEC-06, PROG-01, PROG-02, PROG-03, PROG-04
**Success Criteria** (what must be TRUE):
  1. User can generate a migration plan for a source drive that lists every file to copy, its target drive, and distinguishes files needing copy from files already backed up elsewhere
  2. User can review a plan showing files to copy, target drives, estimated transfer size, and confirm the plan validates sufficient free space on targets before allowing execution
  3. User can execute a migration as a background operation where each copied file is hash-verified before the source is deleted, with per-file status tracking (pending/copying/verifying/verified/deleted/failed)
  4. User can cancel a running migration safely (copied files kept, remaining untouched), and failed copies are retried once then skipped with error logged
  5. User can poll progress (files completed, bytes transferred, ETA), migration state persists across API restarts, and completed migrations produce a summary with files moved, space freed, and errors
**Plans:** 3 plans

Plans:
- [x] 22-01-PLAN.md — Migration schema + planner — completed 2026-03-21
- [x] 22-02-PLAN.md — Migration executor — completed 2026-03-21
- [x] 22-03-PLAN.md — Migration API endpoints — completed 2026-03-21

### Phase 23: Migration Wizard UI

**Goal**: User can drive the entire consolidation workflow from a SwiftUI wizard -- from analysis through execution to completion
**Depends on**: Phase 22 (all backend APIs must exist for the UI to consume)
**Requirements**: UI-01, UI-02, UI-03, UI-04, UI-05
**Success Criteria** (what must be TRUE):
  1. User can access consolidation analysis from the drives view and see which drives are consolidation candidates
  2. User can select a source drive and view a migration plan with target drive assignments and file breakdown before confirming
  3. User can step through the wizard flow (analyze, review plan, confirm, execute, done) with real-time progress showing file-level detail during execution
  4. User sees a completion summary with total space freed, files moved, and any errors encountered
**Plans:** 2 plans

Plans:
- [x] 23-01-PLAN.md — Swift models + APIService extensions — completed 2026-03-21
- [x] 23-02-PLAN.md — Migration wizard view — completed 2026-03-21

## Progress

| Milestone | Phases | Plans | Status | Completed |
|-----------|--------|-------|--------|-----------|
| v1.0 MVP | 1-11 | 14/14 | Complete | 2026-01-24 |
| v1.1 UI | 12-20 | 18/18 | Complete | 2026-03-21 |
| v2.0 Consolidation | 21-23 | 7/7 | Complete | 2026-03-21 |
