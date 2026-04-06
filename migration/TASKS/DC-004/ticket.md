# DC-004 — Konsolidierungs-Reihenfolge: Platzgewinn-Optimierung

## Goal
Add a backend endpoint and frontend section (on Manage page) that recommends the optimal order of data moves to maximize freed disk space across drives.

## Acceptance Criteria
- [ ] New API endpoint `GET /consolidation/recommendations` that returns an ordered list of recommended moves
- [ ] Each recommendation includes: source_drive, target_drive, folder_path, size_bytes, space_freed_after, reason (e.g. "duplicate folder", "subset consolidation")
- [ ] Recommendations are sorted by space_freed descending (biggest wins first)
- [ ] Algorithm considers: which drive has the most free space (best target), which folders are full duplicates (safe to remove after verify), which are subsets (can be deleted after confirming superset is complete)
- [ ] Frontend: section in ManageView (DC-003) showing the recommendation list with a "Start" button per item that navigates to the consolidation flow
- [ ] Do NOT auto-execute any moves — this is advisory only. User must confirm each action.
- [ ] Handle edge case: don't recommend moving data to a drive that would become full

## Relevant Files
- `src/drivecatalog/consolidation.py` — existing consolidation logic
- `src/drivecatalog/api/routes/consolidation.py` — existing routes
- `src/drivecatalog/drives.py` — drive info including total_bytes
- `DriveCatalog/Views/ConsolidatePageView.swift` — existing consolidation UI

## Context
Users have data scattered across multiple external drives and want to know: "in what order should I move/consolidate data to free up the most drives?" For example, if Drive A and Drive B share 80% of their files, consolidating to the larger drive and wiping the smaller one is the optimal move. The system should calculate this and present it as a ranked action list.

This depends on DC-001 (folder-duplicate detection) for accurate recommendations. If DC-001 isn't done yet, use file-level duplicate data as a fallback.
