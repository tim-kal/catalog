# Phase 3 — Safe Verified Transfers

Goal: Users can transfer files between drives with cryptographic verification that every file arrived intact, with proper metadata preservation, crash safety, and a clear completion report.

## Tasks

| ID | Title | Depends On |
|---|---|---|
| DC-012 | Harden copier: fsync, atomic write, 1MB buffer, metadata | — |
| DC-013 | Create planned_actions table (migration v10) | — |
| DC-014 | Batch transfer engine | DC-012, DC-013 |
| DC-015 | Transfer verification report | DC-014 |
| DC-016 | Frontend: Transfer UI with progress and report | DC-015 |

## Success Criteria
- Two mounted drives → user selects files/folders → transfer completes → verification report shows 100% integrity
- Interrupted transfer (app quit mid-copy) → relaunch → resumes from where it left off
- Metadata preserved: mtime, creation date, xattrs (Finder tags)
- Large files (50GB+) transfer at near-native USB speed (no 64KB bottleneck)
