# Requirements: DriveCatalog v2.0 — Drive Consolidation Optimizer

**Defined:** 2026-03-21
**Core Value:** Duplicate detection — knowing which files exist across multiple drives and identifying safe deletion candidates.

## v2.0 Requirements

Requirements for the Drive Consolidation Optimizer. Each maps to roadmap phases.

### Analysis

- [ ] **ANAL-01**: User can view cross-drive file distribution showing which files are unique vs duplicated and where
- [ ] **ANAL-02**: User can identify drives that could be freed (all unique files fit on other connected drives)
- [ ] **ANAL-03**: User can see per-drive breakdown: unique files, duplicated files, total space, reclaimable space
- [ ] **ANAL-04**: User can see which target drives have enough free space to absorb source files
- [ ] **ANAL-05**: System calculates optimal consolidation strategy minimizing total bytes transferred

### Migration Planning

- [ ] **MIGR-01**: User can generate a migration plan for consolidating a specific source drive
- [ ] **MIGR-02**: Migration plan shows: files to copy, target drive for each file, estimated transfer time/size
- [ ] **MIGR-03**: Migration plan validates that target drives have sufficient free space before execution
- [ ] **MIGR-04**: User can review and approve a migration plan before execution begins
- [ ] **MIGR-05**: Migration plan handles files that exist only on the source drive (must be copied) vs files already backed up elsewhere (can be deleted directly)

### Execution

- [ ] **EXEC-01**: User can execute an approved migration plan as a background operation
- [ ] **EXEC-02**: Each file copy is verified by comparing partial hash of source and destination
- [ ] **EXEC-03**: Source files are only deleted after successful copy verification
- [ ] **EXEC-04**: User can cancel a running migration (already-copied files are kept, remaining files are not deleted)
- [ ] **EXEC-05**: Migration tracks per-file status: pending, copying, verifying, verified, deleted, failed
- [ ] **EXEC-06**: Failed file copies are retried once, then skipped with error logged

### Progress Tracking

- [ ] **PROG-01**: User can poll migration progress showing files completed, bytes transferred, estimated time remaining
- [ ] **PROG-02**: User can see per-file status during active migration
- [ ] **PROG-03**: Migration operation persists across API restarts (plan saved to database, execution state recoverable)
- [ ] **PROG-04**: Completed migrations produce a summary: files moved, space freed, errors encountered

### UI — Migration Wizard

- [ ] **UI-01**: User can access consolidation analysis from the drives view showing which drives can be consolidated
- [ ] **UI-02**: User can select a source drive and see a migration plan with target drives and file breakdown
- [ ] **UI-03**: Migration wizard shows step-by-step flow: analyze → review plan → confirm → execute → done
- [ ] **UI-04**: User can see real-time progress during migration execution with file-level detail
- [ ] **UI-05**: Migration wizard shows completion summary with space freed and any errors

## Future Requirements

### Advanced Optimization

- **OPT-01**: User can consolidate multiple source drives in a single operation
- **OPT-02**: System suggests optimal drive arrangement across all drives (not just one source)
- **OPT-03**: User can set priority for which files to keep on which drives (e.g., keep recent projects local)

### Safety

- **SAFE-01**: User can do a dry-run migration that reports what would happen without copying/deleting
- **SAFE-02**: Migration creates undo log so user can reverse a completed migration

## Out of Scope

| Feature | Reason |
|---------|--------|
| Network drive consolidation | Local USB/Thunderbolt only for v2.0 |
| Scheduled/automated migrations | User-initiated only, too risky for automation |
| Full hash verification (SHA256) | Partial hash is sufficient; full hash too slow for large drives |
| Cross-platform support | macOS only |
| Cloud backup integration | Local drives only |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| ANAL-01 | Phase 21 | Pending |
| ANAL-02 | Phase 21 | Pending |
| ANAL-03 | Phase 21 | Pending |
| ANAL-04 | Phase 21 | Pending |
| ANAL-05 | Phase 21 | Pending |
| MIGR-01 | Phase 22 | Pending |
| MIGR-02 | Phase 22 | Pending |
| MIGR-03 | Phase 22 | Pending |
| MIGR-04 | Phase 22 | Pending |
| MIGR-05 | Phase 22 | Pending |
| EXEC-01 | Phase 22 | Pending |
| EXEC-02 | Phase 22 | Pending |
| EXEC-03 | Phase 22 | Pending |
| EXEC-04 | Phase 22 | Pending |
| EXEC-05 | Phase 22 | Pending |
| EXEC-06 | Phase 22 | Pending |
| PROG-01 | Phase 22 | Pending |
| PROG-02 | Phase 22 | Pending |
| PROG-03 | Phase 22 | Pending |
| PROG-04 | Phase 22 | Pending |
| UI-01 | Phase 23 | Pending |
| UI-02 | Phase 23 | Pending |
| UI-03 | Phase 23 | Pending |
| UI-04 | Phase 23 | Pending |
| UI-05 | Phase 23 | Pending |

**Coverage:**
- v2.0 requirements: 25 total
- Mapped to phases: 25
- Unmapped: 0

---
*Requirements defined: 2026-03-21*
*Last updated: 2026-03-21 after roadmap creation*
