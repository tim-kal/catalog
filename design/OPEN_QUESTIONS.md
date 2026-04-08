# Open Questions

## Q1: Vercel backend status
Does `catalog-beta.vercel.app` actually exist and handle bug reports? If not, reports go nowhere.

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

## Q6: Fix scope for fs_fingerprint collision
Three possible fixes — which to pick?
(a) Demote step 4 to always-ambiguous when multiple candidates share a fingerprint OR
    when the only candidate has no confirming signal (null serial, stale product-name serial)
(b) Store a per-drive content-sampled hash (first N files' sizes+mtimes) as a stronger
    fingerprint. Costs an IO pass on every recognize.
(c) Require user to ALWAYS disambiguate when cascade reaches step 4. Safer but adds friction
    for legitimate re-recognitions on exFAT/FAT32 (which have no VolumeUUID).
Pick (a) as default, (c) for exFAT/FAT32 only?
