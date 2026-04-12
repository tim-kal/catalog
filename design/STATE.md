# DriveSnapshots — State

## What It Is
**DriveCatalog** — macOS desktop app (SwiftUI + Python/FastAPI) for cataloging external drives, detecting duplicates, browsing files, managing consolidation/migration. v1.2.

## Architecture
- **Frontend**: SwiftUI macOS 14.0+, ~12k LOC, 43 Swift files. NavigationSplitView with sidebar.
- **Backend**: Python FastAPI, ~5.4k LOC, 30+ modules. Embedded subprocess via BackendService.swift.
- **Database**: SQLite WAL at `~/.drivecatalog/catalog.db`. Custom migrations.
- **Build**: XcodeGen. Embedded Python for release, uv for dev.
- **Comms**: HTTP localhost. APIService.swift ↔ FastAPI.

## Drive Recognition — CONFIRMED BUG 2026-04-08

**Two same-model Samsung T7 drives collide via fs_fingerprint.** Real data proves it:
DB row 16 (B SSD) and row 17 (C SSD) both have `fs_fingerprint=4468812b48a725b8`, same
total_bytes and partition_index. Row 17 still has `device_serial="Samsung PSSD T7 Media"`
(product name, not real serial) — migration v8 didn't fix it because it only re-runs
on currently-mounted drives. Row 16 has `device_serial=NULL` — ioreg extractor silently
returned None on Samsung T7.

### Bug mechanism
`recognize_drive()` cascade steps 1–3 fail for Samsung T7 siblings (no UUID/disk_uuid
match, serial is NULL or stale product name). Step 4 (fs_fingerprint) matches any other
4TB Samsung T7 row. The filter (`mount_path doesn't exist OR same path`) leaves 1 candidate
when the other Samsung is currently unmounted → returns "probable" → `POST /drives` raises
"Drive already registered as X". AddDriveSheet never shows the drive as available.

Also: the `str(mount_path) == r["mount_path"]` re-inclusion clause in steps 3+4 makes the
swap scenario catastrophically wrong (Drive A unplugged, Drive B mounts at same path →
returns Drive A as probable match).

### Additional issues found
- **Migration v8 gap**: `_migrate_repopulate_drive_identifiers` skips unmounted drives,
  leaving product-name "serials" in ~12 HDDs + one Samsung T7 in current DB.
- **ioreg window fragility**: ±10/+50 line proximity match works on boot disk but is not
  robust. Samsung T7 specifically returns None (confirmed by NULL in row 16).
- **resolve-ambiguous data loss risk**: blindly overwrites selected drive's identifiers
  with new volume's. If user picks wrong, Drive A's identity gets corrupted.
- **Ambiguous dialog only triggers via NSWorkspace.didMountNotification** — race condition:
  if drive is already mounted when app starts, ambiguous dialog never appears, and
  AddDriveSheet shows a dead-end message.

### Samsung collision — FULLY FIXED 2026-04-11
- **v1.4.2** (build 18): corroboration requirement, ambiguous UI, migration v9, resolve-ambiguous guard
- **7992542** (2026-04-11): ioreg parser rewritten with structured plist parsing (no more regex
  sliding window). Falls back to IOUSBHostDevice. Auto-resolve: step 4 now excludes fingerprint
  candidates that are provably different (both sides have UUIDs and they differ → new drive,
  not ambiguous). No user click needed when identifiers prove it's a different drive.
- **Remaining**: needs release build + rollout (v1.4.3). Local DB still at schema v8.

## Open Design Threads

## Beta Bug Reporting — CONFIRMED INFRA ISSUE 2026-04-08

- `POST https://catalog-beta.vercel.app/api/bug-report` returns `HTTP 405` with
  `Content-Type: text/html` (Vercel-served website), not API JSON.
- Browser GET shows Russian flower catalog content on same host.
- Result: in-app bug reports do not reach GitHub issue creation backend from this domain.

### Fix implemented 2026-04-11: local backend → GitHub API directly
- New `POST /bug-report` endpoint in local FastAPI backend (`src/drivecatalog/api/routes/bug_report.py`)
- Reads `github_token` and `github_repo` from `~/.drivecatalog/config.yaml`
- BetaService.swift now tries: (1) local backend → GitHub API, (2) Vercel (legacy), (3) browser draft
- Rate limited to 5 reports/hour per device in-process
- Tests: `uv run pytest -q tests/test_api_bug_report.py` → 3 passed
- **Setup required**: user must add `github_token` and `github_repo` to `~/.drivecatalog/config.yaml`

### Phase 1 (DC-001..DC-011): core improvements, mostly complete
See `phases/PHASE-01-CORE-IMPROVEMENTS.md` and `phases/PHASE-02-MANAGE-PAGE.md`

### Phase 3 (DC-012..DC-016): Safe Verified Transfers — designed 2026-04-11
See `phases/PHASE-03-SAFE-TRANSFERS.md` and `design/RESEARCH-safe-transfers.md`
- DC-012: Harden copier (fsync, atomic write, 1MB buffer, metadata)
- DC-013: Create planned_actions table (migration v10)
- DC-014: Batch transfer engine (depends on DC-012, DC-013)
- DC-015: Transfer verification report (depends on DC-014)
- DC-016: Frontend transfer UI (depends on DC-015)
- All task tickets written to `migration/TASKS/DC-01{2..6}/ticket.md`

## UI Review — Drives List Page (2026-04-12)

Source reviewed: screenshot from operator + `DriveCatalog/Views/Drives/DriveListView.swift`.

Intent inferred:
- Single-screen operational triage for many drives: identify risk quickly, then run the next action (scan/hash/transfer/unmount).

Findings:
- Summary bar is metric-dense but action-poor; it hides mounted count when all are mounted and does not surface "critical drives" count.
- Row header packs capacity, usage, scan status, and recency into low-contrast micro-elements; risk is visible only after parsing text.
- Next actions are mostly hidden behind expand/context-menu, increasing clicks for common workflows.

Proposed UI directions (mocked):
- Attention-first command bar (critical count + one-click actions).
- Row-level risk/status badges with explicit CTA in-row.
- Grouping long lists into state buckets (Needs Attention / Healthy / Offline).

## UI Review — Expanded Drive Card (2026-04-12)

Source reviewed: screenshot of expanded row + `expandedContent` in
`DriveCatalog/Views/Drives/DriveListView.swift`.

Intent inferred:
- Expanded state should answer three questions immediately:
  (1) Is this drive healthy and up to date?
  (2) What exactly is on it (inventory/hash state)?
  (3) What is the safest next action?

Findings:
- Expanded content is comprehensive but visually flat; mount path, UUID, capacity, inventory, and actions all compete at similar weight.
- Action row gives destructive and non-destructive operations similar prominence.
- Detail density is high even when user only needs "overview + next step".

Proposed UI directions (mocked):
- Compact info-card hierarchy (identity/mount/catalog split).
- Strong action hierarchy with separated danger zone.
- Progressive detail tabs (Overview/Catalog Health/Operations).

Implementation note (2026-04-12):
- Added a debug-only expanded-card Swift mockup path behind
  `@AppStorage("debugExpandedDriveCardMockup")`.
- Toggle exposed in Settings → Features as
  "Use expanded drive card mockup (debug)".
- Files changed:
  - `DriveCatalog/Views/Drives/DriveListView.swift`
  - `DriveCatalog/Views/SettingsView.swift`
