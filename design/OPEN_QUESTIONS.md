# Open Questions

## Q1: Vercel backend status — RESOLVED 2026-04-08
`catalog-beta.vercel.app` is live but currently serves unrelated website content.
`POST /api/bug-report` returns HTTP 405 HTML, so bug reports from app currently go nowhere.

## Q2: Sidebar restructure scope
Merging Insights + Backups into Manage — do we also absorb Consolidate and Action Queue, or keep those separate?

## Q3: Katalog-Bundle extension list
Need to compile definitive list of macOS bundle formats used by photo/video tools (Capture One, Photos, Lightroom, RED, ARRI, DaVinci Resolve). Which ones contain originals vs. just metadata?

## Q4: Parallel scan safety
Need to verify SQLite WAL concurrent writes actually work under load (two drives scanning simultaneously). Should we add a per-drive lock or let WAL handle it?

## Q5: Samsung T7 ioreg layout
Need to capture `ioreg -r -c IOBlockStorageDevice -l` output with a Samsung T7 plugged in.
Possibilities for why `_get_device_serial_from_ioreg` returns None:
(a) Serial Number appears >50 lines after BSD Name in the Samsung block
(b) Serial Number is in the parent IOUSBDevice, not IOBlockStorageDevice
(c) Serial Number string contains a double-quote that breaks the `[^"]+` regex
(d) Samsung firmware reports an empty "" for Serial Number
Must capture real output before fixing. No point guessing.

## Q6: Fix scope for fs_fingerprint collision — RESOLVED 2026-04-08
Implemented (a): fingerprint-only matches no longer auto-assign without corroboration.
Also added AddDriveSheet disambiguation + force-new path and resolve-ambiguous safety guard.

## Q7: Canonical beta API host
Which hostname should replace `catalog-beta.vercel.app` as the long-term beta backend endpoint?
Current app mitigation opens GitHub issue drafts, but proper API endpoint still needed for silent in-app submit.
