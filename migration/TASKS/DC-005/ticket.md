# DC-005 — Paralleles Scannen mehrerer Drives

## Goal
Allow multiple drives to be scanned simultaneously with proper concurrency handling and UI feedback.

## Acceptance Criteria
- [ ] Backend: Multiple scan operations can run concurrently (one per drive). Add a per-drive lock so the same drive can't be scanned twice simultaneously.
- [ ] Backend: Each scan uses its own SQLite connection (already the case in `_run_scan`). Verify WAL mode handles concurrent writes correctly under load.
- [ ] API: `GET /operations` shows all running scans, each tagged with their drive_id
- [ ] API: `POST /drives/{name}/scan` returns 409 if that specific drive is already being scanned, but does NOT block if other drives are scanning
- [ ] Frontend: DrivesView shows per-drive scan progress (already has progress indicators — verify they work with multiple concurrent scans)
- [ ] Frontend: "Scan All" button that triggers scans for all mounted drives sequentially or in parallel (configurable in settings)
- [ ] Add integration test: start two scans concurrently, verify both complete without DB corruption
- [ ] Handle cancellation: cancelling one scan doesn't affect others

## Relevant Files
- `src/drivecatalog/api/routes/drives.py` — `trigger_scan()`, `_run_scan()` — currently uses BackgroundTasks
- `src/drivecatalog/api/operations.py` — operation tracking system
- `src/drivecatalog/scanner.py` — `scan_drive()` function
- `src/drivecatalog/database.py` — connection factory, WAL mode
- `DriveCatalog/Views/DrivesView.swift` — drive list with scan status

## Context
Currently each scan runs as a FastAPI BackgroundTask in its own thread with its own DB connection. SQLite WAL mode should support concurrent writes, but this has never been tested with parallel scans. The main risks are: DB lock timeouts (current timeout is 30s), progress tracking confusion (operations table may not handle concurrent updates cleanly), and frontend not updating correctly when multiple drives report progress.

The per-drive lock should be a simple in-memory dict (not DB-based) since the API server is single-process. Check `is_cancelled()` in operations.py for the existing cancellation pattern.
