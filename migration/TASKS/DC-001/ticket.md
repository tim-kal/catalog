# DC-001 — Ordner-Duplikat-Erkennung (Backend)

## Goal
Add folder-level duplicate detection to the Python backend. The system must identify when two folders on the same or different drives contain exactly the same files (by hash), and when one folder is an exact subset of another.

## Acceptance Criteria
- [ ] New module `src/drivecatalog/folder_duplicates.py` with detection logic
- [ ] **Exact match**: Two folders are duplicates iff they contain the same number of files AND every file hash in folder A exists in folder B and vice versa. No fuzzy thresholds — this is a precision tool.
- [ ] **Subset detection**: Folder A is a subset of folder B iff every file hash in A exists in B, but B has additional files. Report A as "contained in B".
- [ ] Detection works across drives (folder on Drive X = folder on Drive Y) and within a single drive
- [ ] New API endpoint `GET /folder-duplicates` that returns grouped results: list of folder-duplicate clusters, each with folder paths, drive names, file counts, total sizes, and relationship type (exact_match | subset)
- [ ] API endpoint `GET /folder-duplicates?drive_id=X` to filter by drive
- [ ] Results are computed from existing `files` table data (hashes must already exist) — do NOT re-scan or re-hash
- [ ] Add route to `api/routes/` and model to `api/models/`
- [ ] Performance: must handle 100k+ files across 10+ drives without hanging. Use SQL aggregation where possible, not Python loops over all files.

## Relevant Files
- `src/drivecatalog/duplicates.py` — existing file-level duplicate detection, follow this pattern
- `src/drivecatalog/api/routes/duplicates.py` — existing duplicate routes
- `src/drivecatalog/api/models/` — Pydantic models
- `src/drivecatalog/database.py` — DB connection helpers
- `src/drivecatalog/api/main.py` — router registration

## Context
The app currently detects duplicates at the file level (same hash = same file). Users think in folders though — they want to know "this whole folder is a copy of that whole folder". This is especially important for backup folders that were copied wholesale.

**Critical constraint**: No approximate matching. A folder-duplicate means 100% of files match by hash. Anything less is NOT a folder duplicate — it's just individual file duplicates that happen to be in related folders. The user explicitly rejected fuzzy thresholds because this tool must be precise to prevent data loss.

For subset detection: if Folder A has 500 files and all 500 hashes also exist in Folder B (which has 800 files), then A is a subset of B. This is common with incremental backups.
