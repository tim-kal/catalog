# DC-013 — Create planned_actions table (migration v10)

## Goal
The `actions.py` route module references a `planned_actions` table that was never created. Add it as migration v10 so the batch transfer engine (DC-014) and consolidation execution have a working action queue.

## Acceptance Criteria

### Migration v10
- [ ] Add a new migration (version 10) in `src/drivecatalog/migrations.py` that creates:
```sql
CREATE TABLE IF NOT EXISTS planned_actions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action_type TEXT NOT NULL CHECK(action_type IN ('delete', 'copy', 'move')),
    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'ready', 'in_progress', 'completed', 'failed', 'cancelled')),
    priority INTEGER NOT NULL DEFAULT 0,
    source_drive TEXT NOT NULL,
    source_path TEXT NOT NULL,
    target_drive TEXT,
    target_path TEXT,
    estimated_bytes INTEGER,
    transfer_id TEXT,
    depends_on INTEGER REFERENCES planned_actions(id),
    error TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    started_at TEXT,
    completed_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_planned_actions_status ON planned_actions(status);
CREATE INDEX IF NOT EXISTS idx_planned_actions_transfer_id ON planned_actions(transfer_id);
```
- [ ] The `transfer_id` column groups actions belonging to the same batch transfer (UUID string)
- [ ] `depends_on` allows action chains (e.g., copy must finish before delete)

### Schema version bump
- [ ] Update `SCHEMA_VERSION` in `migrations.py` (= `len(MIGRATIONS)`)
- [ ] Update `expectedSchemaVersion` in `DriveCatalog/Services/BackendService.swift` to match

### Verify actions.py compatibility
- [ ] Confirm the table schema matches what `actions.py` expects in its SQL queries. Read `src/drivecatalog/api/routes/actions.py` and verify column names align. Fix any mismatches in actions.py SQL.

### Tests
- [ ] Test that migration v10 creates the table and indexes
- [ ] Test that a row can be inserted and queried

## Relevant Files
- `src/drivecatalog/migrations.py`
- `src/drivecatalog/api/routes/actions.py` (read to verify compatibility, fix if needed)
- `DriveCatalog/Services/BackendService.swift` (version bump only)
- `tests/test_migrations.py`

## Context
`actions.py` was written as part of DC-010 but the table was never created in any migration. The route code has full CRUD for planned actions (create, list, filter by actionable, update status, delete with dependency check, verify). All of this is dead code until the table exists. This task ONLY creates the table — DC-014 builds the batch transfer engine on top of it.
