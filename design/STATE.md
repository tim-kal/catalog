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

### Samsung collision fix implemented 2026-04-08
- `recognize_drive()` hardened:
  - Same-path re-recognition now requires identifier overlap.
  - `fs_fingerprint` no longer auto-recognizes without corroborating identifiers.
- `POST /drives/resolve-ambiguous` now sanity-checks selected drive vs mounted volume and
  rejects identity overwrites with HTTP 409 when no overlap exists.
- Added migration v9 to clear stale non-unique `device_serial` placeholders (`% Media`,
  `Untitled`, empty string) from old rows.
- AddDriveSheet now allows resolving ambiguous drives directly and supports
  "None of these — register as new drive" (`force_new=true` path).
- Verification:
  - `uv run pytest -q tests/test_drive_recognition.py tests/test_api_drives.py tests/test_migrations.py` → 38 passed
  - `xcodebuild ... build` (DriveCatalog scheme) → success
- Release shipped:
  - `v1.4.2` (build `18`) published at
    `https://github.com/tim-kal/catalog/releases/tag/v1.4.2`
  - `updates/latest.json` updated to v1.4.2

### Post-release verification note (local machine) 2026-04-08
- Local DB at `~/.drivecatalog/catalog.db` still reports `schema_version = 6` and still
  contains stale product-name serials (`Samsung PSSD T7 Media`, `Lexar ES5 Media`,
  `LaCie Rugged Mini USB3 Media`) plus Samsung fingerprint collision.
- Interpretation: this local installation has not yet run the v9 migration path from
  release `v1.4.2` (or is still running an older app binary/backend).

## Open Design Threads

## Beta Bug Reporting — CONFIRMED INFRA ISSUE 2026-04-08

- `POST https://catalog-beta.vercel.app/api/bug-report` returns `HTTP 405` with
  `Content-Type: text/html` (Vercel-served website), not API JSON.
- Browser GET shows Russian flower catalog content on same host.
- Result: in-app bug reports do not reach GitHub issue creation backend from this domain.

### Mitigation implemented 2026-04-08
- App now falls back to opening a prefilled GitHub issue draft at
  `https://github.com/tim-kal/catalog/issues/new` when backend submission fails.
- Bug report UI now tells user whether it was submitted to backend, opened as GitHub draft,
  or failed entirely.
- Backend function now accepts both `log_snippet` and `backend_log` payload keys.
- Verification:
  - `uv run pytest -q tests/test_backend_endpoints.py` → 12 passed
  - `xcodebuild ... build` (DriveCatalog scheme) → success

### Phase 1 (DC-001..DC-007): synced to DB, ready for execution
See `phases/PHASE-01-CORE-IMPROVEMENTS.md` and `phases/PHASE-02-MANAGE-PAGE.md`
