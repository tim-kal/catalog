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

## Q7: Canonical beta API host — RESOLVED 2026-04-11
Bypassed Vercel entirely. Bug reports now route through local FastAPI backend → GitHub API
directly. Vercel endpoint kept as legacy fallback but is not depended on.

## Q8: Is fixed release actually active on affected machine?
Local evidence shows `schema_version = 6` in `~/.drivecatalog/catalog.db`, which implies
the v9 migration from release `v1.4.2` has not been applied there yet. Need to confirm the
running app build and backend process version before judging dialog UX/fix effectiveness.

## Q9: Drives page UI direction priority
For the Drives list redesign, which should ship first:
(a) attention-first summary/command bar,
(b) row-level explicit CTA + risk badge,
or (c) state-grouped list sections?
All three improve triage speed, but implementing one first keeps risk and scope controlled.
