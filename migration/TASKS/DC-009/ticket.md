# DC-009 — Safe Database Migration with Backup, Progress Indicator, and Rollback

## Goal
Make database migrations safe and visible: backup before migrating, show progress in the frontend, rollback on failure. Follows the Lightroom/Core Data pattern — the gold standard for desktop apps with local databases.

## Acceptance Criteria

### Backend: Backup before migration
- [ ] Before applying any pending migration, copy `catalog.db` to `catalog.db.backup-v{current_version}` (e.g. `catalog.db.backup-v3`) using `shutil.copy2` to preserve metadata
- [ ] Also copy `catalog.db-wal` and `catalog.db-shm` if they exist (WAL checkpoint first via `PRAGMA wal_checkpoint(TRUNCATE)` to flush WAL into main DB, then copy just the main file)
- [ ] Only create backup if there ARE pending migrations (don't backup on every startup)
- [ ] Keep at most 3 backup files — delete oldest if more exist
- [ ] Log backup path: `logger.info("Backup created: catalog.db.backup-v3")`

### Backend: Rollback on failure
- [ ] Wrap the entire migration loop in a try/except
- [ ] On ANY exception during migration: restore the backup file, log the error, re-raise with a clear message: `"Migration to v{target} failed: {error}. Database restored from backup."`
- [ ] The restored DB will be at the old schema version — the API server will start with the old schema, which means new features won't work but existing functionality is preserved
- [ ] Write failure status to migration_status.json: `{"migrating": false, "failed": true, "error": "...", "restored_from": "catalog.db.backup-v3"}`

### Backend: Migration progress reporting (file-based)
- [ ] During `apply_migrations()`, write progress to `~/.drivecatalog/migration_status.json`:
  - Start: `{"migrating": true, "current": 0, "total": N, "description": "Starting..."}`
  - Each step: `{"migrating": true, "current": 4, "total": 6, "description": "Add catalog_bundle column"}`
  - Complete: delete the file
- [ ] Write atomically (write to .tmp, then rename) — already implemented, keep it
- [ ] Clean up stale status file on startup before checking for pending migrations
- [ ] Keep the existing `GET /migration-status` endpoint (reads the file) — useful for debugging even though frontend won't use it during migration

### Frontend: DB version check before server start (no HTTP needed)
- [ ] New private method in `BackendService.swift`: `checkMigrationNeeded() -> Bool`
  - Open `~/.drivecatalog/catalog.db` directly via SQLite (import `SQLite3` framework)
  - Read `SELECT COALESCE(MAX(version), 0) FROM schema_version`
  - Compare against a constant `expectedSchemaVersion` (hardcoded in Swift, must match MIGRATIONS count in Python)
  - If version < expected → migration needed → return true
  - If DB doesn't exist → new install, migration will be fast → return false
  - If read fails → assume migration needed → return true
- [ ] In `start()`: call `checkMigrationNeeded()` BEFORE launching the backend process. If true, set `isMigrating = true` immediately so the overlay appears before the backend even starts.

### Frontend: Read migration_status.json directly (not via HTTP)
- [ ] Rewrite `pollMigrationStatus()` to read `~/.drivecatalog/migration_status.json` via `FileManager` instead of calling `GET /migration-status`
- [ ] Poll every 500ms while `isMigrating` is true
- [ ] Parse JSON: update `migrationCurrent`, `migrationTotal`, `migrationDescription`
- [ ] If file contains `"failed": true`: set `startupError` with the error message and backup path. Do NOT keep waiting for /health.
- [ ] When file is deleted (migration complete): continue waiting for /health as normal

### Frontend: Migration overlay (already exists — verify and adjust)
- [ ] MigrationOverlay in ContentView.swift already exists — verify it shows correctly
- [ ] Add failure state: if migration failed, show error message + "Your data has been restored from backup. Please contact support or use the previous app version."
- [ ] Existing overlay text "Your existing data is being updated for the new version. No rescanning needed." is good — keep it

### Schema version constant sync
- [ ] Add `SCHEMA_VERSION` constant to `migrations.py`: `SCHEMA_VERSION = len(MIGRATIONS)` 
- [ ] Add a Python CLI command or script that prints the current schema version, so build scripts can extract it: `python -c "from drivecatalog.migrations import SCHEMA_VERSION; print(SCHEMA_VERSION)"`
- [ ] Document in CLAUDE.md or a comment: when adding a new migration, also update `expectedSchemaVersion` in BackendService.swift

### Tests
- [ ] Test: backup is created before migration runs, with correct filename
- [ ] Test: if migration v5 fails, backup-v4 is restored and DB is at v4
- [ ] Test: migration_status.json is written during migration and cleaned up after
- [ ] Test: stale migration_status.json from crash is cleaned up on next start
- [ ] Test: no backup created when DB is already up to date

## Relevant Files
- `src/drivecatalog/migrations.py` — `apply_migrations()`: add backup, rollback, progress writing
- `src/drivecatalog/database.py` — `init_db()`, `get_db_path()`
- `src/drivecatalog/api/main.py` — existing `/migration-status` endpoint (keep for debugging)
- `DriveCatalog/Services/BackendService.swift` — `start()`, `waitForHealthy()`, `pollMigrationStatus()`: rewrite to file-based
- `DriveCatalog/ContentView.swift` — MigrationOverlay (exists, add failure state)

## Context
### The Problem
The backend runs DB migrations in the FastAPI lifespan (`init_db()` → `apply_migrations()`). This blocks uvicorn from accepting connections. The frontend polls `/migration-status` via HTTP, but that endpoint can't respond until migrations are done — chicken-and-egg problem. The MigrationOverlay UI exists but never appears.

### The Solution (informed by industry patterns)
**Lightroom pattern**: Lightroom detects catalog version mismatch, creates a backup, shows a modal progress dialog, runs migration, and rolls back on failure. We adapt this:

1. **Frontend detects migration need** by reading SQLite directly (no backend needed)
2. **Backend creates backup** before any migration runs
3. **Progress via file** — backend writes JSON, frontend reads it (no HTTP)
4. **Rollback on failure** — restore backup, inform user

### Why file-based, not HTTP?
uvicorn's lifespan blocks all request handling until complete. The `/migration-status` endpoint is registered but unreachable during migration. Alternatives considered:
- Background thread for migration → risk of API calls hitting incomplete schema
- Separate migration process → doubles Python startup time, complex process management
- File-based progress → zero coupling with server lifecycle, same-machine guarantee

### Why backup matters
Current code has no backup. If `_migrate_catalog_bundle_paths` crashes mid-way through 100k rows, the DB is in a partial state. Version tracking means the migration won't re-run, but the data is inconsistent. A pre-migration backup makes this recoverable.

### The expectedSchemaVersion sync problem
The frontend needs to know the expected schema version to detect if migration is needed. This creates a sync point between Python and Swift. The pragmatic solution: a hardcoded constant in both, with a comment reminding developers to keep them in sync. A build-time script could automate this but is overkill for now.
