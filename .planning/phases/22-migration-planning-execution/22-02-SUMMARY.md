---
phase: 22-migration-planning-execution
plan: 02
subsystem: migration-engine
tags: [migration, executor, file-copy, hash-verify, background-task]

# Dependency graph
requires:
  - phase: 22-01
    provides: migration_plans and migration_files SQLite tables, generate_migration_plan, validate_plan
  - module: drivecatalog.hasher
    provides: compute_partial_hash for copy verification
  - module: drivecatalog.api.operations
    provides: is_cancelled, update_progress, update_operation, OperationStatus
provides:
  - execute_migration_plan function (runs validated plans as background operations)
  - _execute_migration internal implementation
  - _update_plan_progress helper for dual-tracked progress
affects: [22-03 migration API endpoints, 23 wizard UI]

# Tech tracking
tech-stack:
  added: []
  patterns: [background-thread executor, per-file-commit crash recovery, copy-verify-delete pipeline, retry-once-then-skip]

key-files:
  created: []
  modified:
    - src/drivecatalog/migration.py

key-decisions:
  - "Signature matches _run_hash pattern: execute_migration_plan(plan_id, operation_id) with internal get_connection()"
  - "shutil.copy2 for file copies (preserves metadata, simpler than streaming for migration use case)"
  - "Per-file conn.commit() for crash recovery (WAL mode handles write performance)"
  - "Unplaceable files (NULL target_drive_id) marked failed immediately with descriptive error"

patterns-established:
  - "Copy-verify-delete pipeline: copy first, hash verify, only then delete source"
  - "Retry once on copy failure, then skip and continue with remaining files"
  - "Dual progress tracking: SQLite migration_plans table + in-memory operation tracker"

# Metrics
duration: 3min
completed: 2026-03-21
---

# Phase 22 Plan 02: Migration Executor Summary

**Background-compatible migration executor with per-file copy, partial-hash verification, source deletion, cancellation support, and retry-once resilience**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-21T00:25:00Z
- **Completed:** 2026-03-21T00:27:56Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- Added `execute_migration_plan(plan_id, operation_id)` to migration.py following the existing `_run_hash` background task pattern
- Per-file status transitions: pending -> copying -> verifying -> verified -> deleted (with failed as error state)
- Hash verification using `compute_partial_hash` before any source file deletion (handles both pre-hashed and unhashed source files)
- Copy retry (max 2 attempts via `shutil.copy2`), then skip on failure
- Cancellation via `is_cancelled(operation_id)` checked between every file, preserves all completed work
- `delete_only` files skip copy/verify, go straight to source deletion (file already exists elsewhere)
- Progress tracked in both SQLite (`migration_plans` table) and in-memory operation tracker after every file
- All state persisted per-file via `conn.commit()` for crash recovery
- Top-level exception handler marks plan as failed and updates operation tracker

## Task Commits

Each task was committed atomically:

1. **Task 1: Migration executor function** - `8dc785c` (feat)

## Files Created/Modified

- `src/drivecatalog/migration.py` - Added execute_migration_plan, _execute_migration, _update_plan_progress (391 lines added)

## Decisions Made

- Function signature `(plan_id, operation_id)` with internal `get_connection()` matches `_run_hash` pattern (background threads need own connection)
- Used `shutil.copy2` instead of streaming copy (simpler, preserves metadata, adequate for migration file sizes)
- Per-file `conn.commit()` rather than batch commits -- WAL journal mode handles write performance, and this ensures crash recovery
- Unplaceable files (NULL target_drive_id from infeasible plans) are marked failed immediately rather than silently skipped

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Migration executor ready for 22-03 (API endpoints) to wire up as background task
- Function designed for `BackgroundTasks.add_task(execute_migration_plan, plan_id, operation_id)` pattern
- No blockers

---
*Phase: 22-migration-planning-execution*
*Completed: 2026-03-21*
