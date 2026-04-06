# DC-007 — Drive-Rename: macOS-Umbenennung automatisch übernehmen

## Goal
When a drive is renamed in macOS Finder (mount path changes), automatically update the drive name in the app's database on next mount detection.

## Acceptance Criteria
- [ ] When a known drive is mounted (matched by UUID), check if the volume name differs from the stored name
- [ ] If the name differs: automatically update the name in the `drives` table to match the current macOS volume name
- [ ] Log the rename in the audit/activity log: "Drive renamed: OldName → NewName (detected from macOS)"
- [ ] Reverse direction: when user renames a drive in the app (via right-click rename in DriveDetailView), also rename the volume on macOS using `diskutil rename`
- [ ] If macOS rename fails (e.g. read-only volume), show error to user and revert the name in the DB
- [ ] Add test: mock a drive with changed volume name, verify DB updates on recognition

## Relevant Files
- `src/drivecatalog/drives.py` — `recognize_drive()` function (uses UUID to match drives)
- `src/drivecatalog/api/routes/drives.py` — drive rename endpoint
- `src/drivecatalog/audit.py` — activity logging
- `DriveCatalog/Views/Drives/DriveDetailView.swift` — drive detail with rename UI

## Context
The app already identifies drives by UUID, not by name. So when a drive is renamed on macOS, the app still recognizes it on next mount — but the stored name becomes stale. The fix is simple: in the recognize_drive flow, compare the current volume name to the stored name and update if different.

For the reverse direction (app → macOS): `diskutil rename /Volumes/OldName NewName` works for HFS+ and APFS volumes. This may require elevated permissions for some volumes. Handle the error gracefully.
