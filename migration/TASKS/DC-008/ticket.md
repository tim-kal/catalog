# DC-008 — Robuste Drive-Erkennung: Multi-Signal Identifier-Kaskade

## Goal
Replace the fragile single-UUID drive identification with a multi-signal cascade that reliably recognizes drives even when VolumeUUID is missing (FAT32, exFAT, USB sticks). Fix all 6 known weaknesses in drive recognition systematically.

## Acceptance Criteria

### Backend: New identifier collection
- [ ] New function `collect_drive_identifiers(path: Path) -> DriveIdentifiers` that calls `diskutil info -plist` once and extracts ALL available identifiers:
  - `volume_uuid`: from VolumeUUID field (may be None)
  - `disk_uuid`: from DiskUUID field (may be None, available on GPT volumes)
  - `device_serial`: from ParentWholeDisk → `diskutil info -plist /dev/diskN` → IORegistryEntryName or MediaName (may be None)
  - `partition_index`: numeric index extracted from DeviceIdentifier (e.g. "disk2s1" → 1)
  - `fs_fingerprint`: deterministic hash of (TotalSize + FilesystemType + VolumeAllocationBlockSize) — stable across renames but NOT unique across identical drives
- [ ] DB migration adding columns to `drives` table: `disk_uuid TEXT`, `device_serial TEXT`, `partition_index INTEGER`, `fs_fingerprint TEXT`
- [ ] Migration populates new columns for existing drives by calling `collect_drive_identifiers` on any currently mounted drives (best-effort, skip unmounted)

### Backend: New recognition algorithm
- [ ] Rewrite `recognize_drive()` with priority cascade:
  1. VolumeUUID match → **certain** → auto-recognize, update all stored identifiers
  2. DiskUUID match → **certain** → auto-recognize, update all stored identifiers
  3. Device Serial + Partition Index match → **very likely** → auto-recognize, update identifiers
  4. FS Fingerprint match with ONLY ONE candidate → **probable** → auto-recognize but log a warning
  5. FS Fingerprint match with MULTIPLE candidates → **ambiguous** → return `ambiguous` status with candidate list, let frontend ask the user
  6. Only mount_path match, no identifier overlap → **unreliable** → return `weak_match` status, let frontend warn the user
- [ ] `recognize_drive()` returns a result object with: `drive` (if matched), `confidence` (certain|probable|ambiguous|weak|none), `candidates` (list for ambiguous case)
- [ ] On successful recognition: always update ALL stored identifiers to latest values (identifiers can change, e.g. device_serial after firmware update)

### Fix: list_mounted_drives() (weakness #4)
- [ ] `GET /drives/mounted` no longer just checks `Path(mount_path).exists()`. Instead: iterate `/Volumes/`, call `recognize_drive()` for each volume, return recognized drives with updated info. This means a renamed drive is correctly shown as mounted.

### Fix: auto_scan_on_mount() (weakness #5)  
- [ ] `watcher.py:auto_scan_on_mount()` uses `recognize_drive()` instead of `get_drive_by_mount_path()`. Renamed drives are now auto-scanned correctly.

### Fix: AddDriveSheet registered check (weakness #3)
- [ ] `POST /drives/recognize` endpoint returns enough info for the frontend to filter already-registered volumes. AddDriveSheet must call recognize for each discovered volume, not just compare mount_paths.
- [ ] Frontend: `AddDriveSheet.swift` calls recognize endpoint per volume instead of comparing against `registeredPaths` set

### Fix: Registration stores all identifiers (weakness #1, #6)
- [ ] `POST /drives` (create_drive) calls `collect_drive_identifiers()` and stores all fields, not just volume_uuid
- [ ] Duplicate check on registration uses the full cascade (not just UUID + mount_path)

### API changes
- [ ] `POST /drives/recognize` response adds `confidence` field (certain|probable|ambiguous|weak|none)
- [ ] `POST /drives/recognize` response adds `candidates` field (list of possible matches for ambiguous case)
- [ ] `GET /drives` response includes new identifier fields (disk_uuid, device_serial, fs_fingerprint) for debugging/display

### UX: Ambiguous match handling
- [ ] When recognition returns `ambiguous` (multiple FS fingerprint matches), frontend shows dialog: "Is this the same drive as 'Backup 2024'?" with candidate list
- [ ] When recognition returns `weak` (mount_path only), frontend shows warning: "This drive could not be reliably identified. It may be confused with other drives."

### Tests
- [ ] Unit test: `collect_drive_identifiers` with mocked diskutil output for APFS (all fields), FAT32 (no VolumeUUID), exFAT (no VolumeUUID, no DiskUUID)
- [ ] Unit test: cascade priority — when VolumeUUID matches drive A but mount_path matches drive B, drive A wins
- [ ] Unit test: ambiguous fingerprint — two drives with same TotalSize+FSType+BlockSize returns `ambiguous`
- [ ] Unit test: renamed drive (different mount_path, same UUID) is correctly recognized and DB updated

## Relevant Files
- `src/drivecatalog/drives.py` — `recognize_drive()`, `get_drive_uuid()`, `get_drive_info()`, `get_drive_by_uuid()`, `get_drive_by_mount_path()`
- `src/drivecatalog/api/routes/drives.py` — `create_drive()`, `recognize_mounted_drive()`, `list_mounted_drives()`
- `src/drivecatalog/watcher.py` — `auto_scan_on_mount()` uses `get_drive_by_mount_path()`, must switch to `recognize_drive()`
- `src/drivecatalog/migrations.py` — add migration for new columns
- `src/drivecatalog/api/models/drive.py` — update DriveResponse model with new fields
- `DriveCatalog/Views/Drives/AddDriveSheet.swift` — `loadVolumes()` and `registeredPaths` logic must use recognize
- `DriveCatalog/Services/APIService.swift` — `recognizeDrive()` must handle new response fields (confidence, candidates)

## Context
The app currently identifies drives by VolumeUUID only. When VolumeUUID is missing (FAT32, exFAT, some USB sticks), it falls back to mount_path — which is fragile and breaks when macOS appends " 1" to the path or when the drive is renamed.

This task replaces the single-identifier approach with a priority cascade: VolumeUUID → DiskUUID → Device Serial + Partition → FS Fingerprint. The cascade always tries the strongest available identifier first.

**Critical UX constraint**: When identification is ambiguous (e.g. two identical USB sticks with same fingerprint), NEVER auto-assign. Ask the user. Wrong auto-assignment could lead to scan data being attributed to the wrong drive, which is a data integrity issue.

**Device Serial**: Obtained by looking up the ParentWholeDisk (e.g. disk2) and reading its IORegistryEntryName/MediaName from `diskutil info -plist /dev/disk2`. For USB drives this often contains the manufacturer's serial. Combined with partition_index it uniquely identifies a volume on that device.

**FS Fingerprint**: `hashlib.sha256(f"{total_size}:{fs_type}:{block_size}".encode()).hexdigest()[:16]`. This is NOT unique (two identical drives will match) but combined with other signals it narrows candidates. When it's the only match and there are multiple candidates, the user must confirm.

The `recognize_drive()` function is called from 3 places and all must use the new cascade:
1. `POST /drives/recognize` API endpoint (explicit recognition)
2. `list_mounted_drives()` (implicit, on every drive list refresh)
3. `auto_scan_on_mount()` in watcher.py (on volume mount event)
