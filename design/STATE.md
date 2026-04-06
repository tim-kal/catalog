# DriveSnapshots — State

## What It Is
**DriveCatalog** — macOS desktop app (SwiftUI + Python/FastAPI) for cataloging external drives, detecting duplicates, browsing files, managing consolidation/migration. v1.2.

## Architecture
- **Frontend**: SwiftUI macOS 14.0+, ~12k LOC, 43 Swift files. NavigationSplitView with sidebar.
- **Backend**: Python FastAPI, ~5.4k LOC, 30+ modules. Embedded subprocess via BackendService.swift.
- **Database**: SQLite WAL at `~/.drivecatalog/catalog.db`. Custom migrations.
- **Build**: XcodeGen. Embedded Python for release, uv for dev.
- **Comms**: HTTP localhost. APIService.swift ↔ FastAPI.

## Drive Recognition Deep-Dive (researched 2026-04-06)

### How it works
- **Primary ID**: macOS VolumeUUID via `diskutil info -plist` → stored in `drives.uuid` (UNIQUE)
- **Registration**: AddDriveSheet lists /Volumes/, user picks volume, POST /drives stores UUID + mount_path
- **Recognition**: `recognize_drive()` — UUID lookup first, mount_path fallback. Auto-updates name/path on UUID match.
- **Mount detection**: watchdog on /Volumes (DirCreated/Deleted events) + polling via GET /drives/mounted

### Known weaknesses
1. UUID missing on FAT32/exFAT/network → falls back to mount_path which is fragile
2. macOS can append " 1" to mount path → path-based matching breaks
3. AddDriveSheet checks registered by path, not UUID → renamed drive shows as "new"
4. list_mounted_drives() doesn't call recognize → renamed drives show as unmounted
5. auto_scan_on_mount() uses path lookup, not UUID → misses renamed drives
6. No disk-identifier fallback (DeviceIdentifier, DiskUUID for partitions)

## Open Design Threads

### Phase 1 (DC-001..DC-007): synced to DB, ready for execution
See `phases/PHASE-01-CORE-IMPROVEMENTS.md` and `phases/PHASE-02-MANAGE-PAGE.md`

### Drive recognition robustness
Needs decision: fix the 6 weaknesses above as a new task, or fold into DC-007 (Drive-Rename Sync)?
