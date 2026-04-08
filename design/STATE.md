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

## Open Design Threads

### Phase 1 (DC-001..DC-007): synced to DB, ready for execution
See `phases/PHASE-01-CORE-IMPROVEMENTS.md` and `phases/PHASE-02-MANAGE-PAGE.md`
