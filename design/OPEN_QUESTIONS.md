# Open Questions

## Q1: Vercel backend status
Does `catalog-beta.vercel.app` actually exist and handle bug reports? If not, reports go nowhere.

## Q2: Sidebar restructure scope
Merging Insights + Backups into Manage — do we also absorb Consolidate and Action Queue, or keep those separate?

## Q3: Katalog-Bundle extension list
Need to compile definitive list of macOS bundle formats used by photo/video tools (Capture One, Photos, Lightroom, RED, ARRI, DaVinci Resolve). Which ones contain originals vs. just metadata?

## Q4: Parallel scan safety
Need to verify SQLite WAL concurrent writes actually work under load (two drives scanning simultaneously). Should we add a per-drive lock or let WAL handle it?
