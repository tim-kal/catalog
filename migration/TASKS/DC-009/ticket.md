# DC-009 — Migrations-Ladeindikator beim App-Start

## Goal
Show a visible progress indicator in the frontend when the backend is running database migrations on startup, so the user understands why the app takes longer to load and that their data is being updated (not lost).

## Acceptance Criteria

### Backend: Migration progress reporting
- [ ] New file-based progress mechanism: during `apply_migrations()`, write current progress to a JSON file at `~/.drivecatalog/migration_status.json` with structure: `{"migrating": true, "current": 4, "total": 6, "description": "Add catalog_bundle column"}`
- [ ] On migration start: write `{"migrating": true, "current": 0, "total": N}`
- [ ] After each migration step: update `current` and `description`
- [ ] On migration complete: write `{"migrating": false}` then delete the file
- [ ] If no migrations needed (DB already up to date): don't create the file at all
- [ ] New endpoint `GET /migration-status` that reads and returns this file's contents, or `{"migrating": false}` if file doesn't exist. This endpoint must work BEFORE `init_db()` completes (register it outside the lifespan context).

### Frontend: Startup migration screen
- [ ] `BackendService.swift`: after launching the backend process, poll `GET /migration-status` every 500ms until backend is fully ready
- [ ] When `migrating: true`: show a migration overlay/sheet in ContentView with:
  - Progress bar (current/total)
  - Current step description: "Updating database... (Step 4 of 6)"
  - Subtitle: "Your existing data is being updated for the new version. No rescanning needed."
  - No cancel button — migrations must complete
- [ ] When `migrating: false` and `/health` returns 200: dismiss overlay, show normal UI
- [ ] If migration_status endpoint is not available (old backend): fall back to current behavior (wait for /health)

### Edge cases
- [ ] If the app crashes during migration: on next start, migrations resume from where they left off (already handled by `apply_migrations` version tracking — just verify this works)
- [ ] If migration_status.json is stale (app crashed before cleanup): backend cleans it up on next start before running migrations
- [ ] Large data migrations (v4 catalog_bundle on 100k+ files): progress within a single migration step is NOT required — just show which step we're on

## Relevant Files
- `src/drivecatalog/migrations.py` — `apply_migrations()` function, write progress here
- `src/drivecatalog/database.py` — `init_db()` calls apply_migrations
- `src/drivecatalog/api/main.py` — lifespan context where init_db runs; new endpoint must work outside lifespan
- `DriveCatalog/Services/BackendService.swift` — `start()`, `checkExistingServer()`, server health polling
- `DriveCatalog/ContentView.swift` — overlay placement

## Context
When a user receives an app update, the backend runs database migrations on first start. Currently this happens invisibly — the frontend just waits for `/health` to respond. For small migrations this is instant, but `_migrate_catalog_bundle_paths` (v4) iterates all files in the DB which can take seconds on large catalogs.

The user needs to see that something is happening and that their data is safe. The migration status is communicated via a JSON file (not the API) because the API may not be fully started yet when migrations run. However, a lightweight `/migration-status` endpoint should be registered early (before lifespan/init_db) so the frontend can poll it.

File-based approach: `apply_migrations()` runs synchronously during `init_db()` which runs in the FastAPI lifespan. The migration_status.json file is the simplest way to communicate progress without restructuring the startup sequence.
