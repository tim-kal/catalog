# Handoff — Two Samsung T7 Drives Collide in Recognition Cascade

**Status:** Root-caused, not yet fixed. Blocked on real ioreg capture from a Samsung T7.
**Date:** 2026-04-08
**Author:** Claude (orient mode)
**Audience:** Next agent picking this up. Self-contained — assume no memory of prior chat.

---

## TL;DR

Two distinct Samsung T7 4TB drives cannot be distinguished by the current drive-recognition
cascade. When one is plugged in and the other is mounted-or-unmounted-with-stale-path, the
system identifies the new drive as the old one and either blocks `POST /drives` with
*"Drive already registered as X"* or shows an ambiguous dead-end in AddDriveSheet.

**Confirmed by live DB data** (see §2) — two rows with identical `fs_fingerprint` already
exist. The bug is not hypothetical.

Three independent causes stack:
1. `_get_device_serial_from_ioreg()` silently returns `None` for Samsung T7.
2. Migration v8 left product-name strings in `device_serial` for unmounted rows.
3. `recognize_drive()` step 4 treats `fs_fingerprint` as a "probable" single-signal match
   even though it is deterministic for same-model/same-format drives.

Plus two additional bugs found while investigating (see §5).

---

## 1. User-facing reproduction

1. User has Drive A (Samsung T7 4TB APFS, say registered as "B SSD") in the catalog.
2. User plugs in Drive B (different physical Samsung T7 4TB APFS).
3. AddDriveSheet → Drive B either:
   - (Variant A) never appears in the available list — internally recognized as "B SSD" via
     `status="recognized"`, filtered out at `AddDriveSheet.swift:174` by
     `availableVolumes = volumes.filter { $0.recognizedAs == nil && !$0.isAmbiguous }`, or
   - (Variant B) appears in the orange "Ambiguous Drives" section with caption
     *"These volumes match multiple registered drives. Connect them from the main view
     to identify"* — but the user has no way to reach the identification flow from
     AddDriveSheet, and the `NSWorkspace.didMountNotification` path (DriveListView.swift:1579)
     only fires once on mount, not retroactively.

Force-calling `POST /drives` directly yields
`HTTPException(400, detail="Drive already registered as 'B SSD'")`
from `routes/drives.py:130-134`.

---

## 2. Evidence — live DB state at time of investigation

Run this to reproduce:
```bash
sqlite3 ~/.drivecatalog/catalog.db \
  "SELECT fs_fingerprint, COUNT(*), GROUP_CONCAT(name) FROM drives
   WHERE fs_fingerprint IS NOT NULL GROUP BY fs_fingerprint;"
```

Output at time of investigation:
```
108d39cbc3e37770|1|1 HDD
1ccdaf19bfbee2ef|1|6 HDD
4468812b48a725b8|2|B SSD,C SSD          ← COLLISION
59903e01d7e3237d|1|LX 1TB
```

Full rows for the two colliding drives:
```
id=16 name="B SSD" uuid=A807... disk_uuid=597C... device_serial=NULL
       partition_index=2 fs_fp=4468812b48a725b8 total_bytes=4000685752320
id=17 name="C SSD" uuid=42A7... disk_uuid=1ACF... device_serial="Samsung PSSD T7 Media"
       partition_index=2 fs_fp=4468812b48a725b8 total_bytes=4000685752320
```

Key observations:
- `device_serial=NULL` on row 16 proves that `_get_device_serial_from_ioreg()` returned
  `None` when B SSD was last recognized under the current code.
- `device_serial="Samsung PSSD T7 Media"` on row 17 is a **product name** (not a hardware
  serial) left over from the pre-`576023a` code that used `diskutil info`'s `MediaName`
  field as the serial. Migration v8 didn't clean it because row 17 was unmounted when
  the migration ran.
- Stale product names also exist in other rows:
  - row 8 (6 HDD): `device_serial="LaCie Rugged Mini USB3 Media"`
  - row 15 (LX 1TB): `device_serial="Lexar ES5 Media"`

---

## 3. Code path walkthrough — how the collision turns into the user-facing error

### Relevant files and line numbers (verified by reading)

| File | Lines | Purpose |
|---|---|---|
| `src/drivecatalog/drives.py` | 54-90  | `collect_drive_identifiers()` — calls diskutil + ioreg |
| `src/drivecatalog/drives.py` | 93-129 | `_get_device_serial_from_ioreg()` — the flaky parser |
| `src/drivecatalog/drives.py` | 377-482 | `recognize_drive()` — full cascade |
| `src/drivecatalog/drives.py` | 438-468 | Step 4 (fs_fingerprint) — the collision site |
| `src/drivecatalog/drives.py` | 444-449 | Filter with the buggy `str(mount_path) == r["mount_path"]` clause |
| `src/drivecatalog/api/routes/drives.py` | 102-186 | `POST /drives` create_drive |
| `src/drivecatalog/api/routes/drives.py` | 130-140 | Rejection paths (already registered / ambiguous) |
| `src/drivecatalog/api/routes/drives.py` | 385-468 | `POST /drives/recognize` |
| `src/drivecatalog/api/routes/drives.py` | 471-504 | `POST /drives/resolve-ambiguous` |
| `src/drivecatalog/migrations.py` | (v8 block) | `_migrate_repopulate_drive_identifiers()` |
| `DriveCatalog/Views/Drives/AddDriveSheet.swift` | 173-180 | `availableVolumes`, `ambiguousVolumes` filters |
| `DriveCatalog/Views/Drives/AddDriveSheet.swift` | 218-228 | `loadVolumes()` calls `/recognize` per volume |
| `DriveCatalog/Views/Drives/DriveListView.swift` | 1579-1592 | `NSWorkspace.didMountNotification` → ambiguous sheet |
| `DriveCatalog/Views/Drives/DriveListView.swift` | 2576-2680 | `AmbiguousMatchSheet` view |

### The exact walk

1. User plugs in a new Samsung T7 at `/Volumes/Samsung T7` (or `/Volumes/Samsung T7 1`
   if another is already mounted with that label).
2. `collect_drive_identifiers()` runs. Gets new VolumeUUID + DiskUUID + partition_index=2
   + fs_fingerprint=`4468812b48a725b8`. `_get_device_serial_from_ioreg()` returns
   `None` (see §4 for why — unverified, needs real capture).
3. `recognize_drive()` cascade:
   - **Step 1 (`uuid`):** new VolumeUUID → no match.
   - **Step 2 (`disk_uuid`):** new DiskUUID → no match.
   - **Step 3 (`device_serial + partition_index`):** skipped because
     `ids.device_serial is None`.
   - **Step 4 (`fs_fingerprint`):** `WHERE fs_fingerprint = '4468812b48a725b8'` returns
     `[B SSD (row 16), C SSD (row 17)]`.
4. Step 4's filter (drives.py:444-449):
   ```python
   candidates_not_mounted = [
       r for r in rows
       if not r["mount_path"] or not Path(r["mount_path"]).exists()
       or str(mount_path) == r["mount_path"]
   ]
   ```
   - If **exactly one** of {B SSD, C SSD} is currently mounted →
     `candidates_not_mounted` has 1 entry (the unmounted one) →
     returns `RecognitionResult(drive=<the unmounted one>, confidence="probable")`.
   - If **both** are currently mounted → `candidates_not_mounted = []`,
     but `rows` is non-empty → falls to the "ambiguous" branch at line 462 →
     returns `RecognitionResult(drive=None, confidence="ambiguous", candidates=rows)`.
   - If **neither** is mounted → `candidates_not_mounted = [B, C]` (len=2) →
     falls to "ambiguous" branch → same as above.
5. AddDriveSheet flow (AddDriveSheet.swift:218-228):
   ```swift
   if let response = try? await APIService.shared.recognizeDrive(mountPath: discovered[i].path) {
       if (response.status == "recognized" || response.status == "weak_match"),
          let driveName = response.drive?.name {
           discovered[i].recognizedAs = driveName
       } else if response.status == "ambiguous" {
           discovered[i].isAmbiguous = true
       }
   }
   ```
   - `"probable"` is treated the same as `"certain"` by the backend —
     `/recognize` returns `status="recognized"` at `routes/drives.py:440`.
     So Variant A volumes get `recognizedAs = "<wrong drive>"` and disappear from
     `availableVolumes`.
   - `"ambiguous"` volumes land in `ambiguousVolumes`, shown as a dead-end orange list
     at AddDriveSheet.swift:98-123.
6. `POST /drives` direct call (e.g. via CLI or a retry path) goes through
   `routes/drives.py:128-134`:
   ```python
   result = recognize_drive(conn, path_obj)
   if result.drive is not None:
       raise HTTPException(400, f"Drive already registered as '{result.drive['name']}'")
   ```
   → "Drive already registered as 'B SSD'".

---

## 4. Why the previous fix attempts did not work

`git log --all --oneline` shows three relevant commits, all failed to actually fix
the Samsung T7 case:

### Commit `576023a` — "use real hardware serial from ioreg"
Added `_get_device_serial_from_ioreg()`. Logic at `drives.py:93-129`:
```python
result = subprocess.run(["ioreg", "-r", "-c", "IOBlockStorageDevice", "-l"], ...)
lines = result.stdout.splitlines()
for i, line in enumerate(lines):
    serial_m = re.search(r'"Serial Number"\s*=\s*"([^"]+)"', line)
    if not serial_m:
        continue
    context = lines[max(0, i - 10): i + 50]
    for cl in context:
        bsd_m = re.search(r'"BSD Name"\s*=\s*"' + re.escape(disk_name) + r'"', cl)
        if bsd_m:
            return serial_m.group(1).strip()
return None
```

Verified empirically on the test machine (boot disk):
- Serial Number at line 53 in `"Device Characteristics"`.
- BSD Name "disk0" at line 90.
- Gap = 37 lines → inside the +50 window → returns serial `0ba028596108dc17` correctly.

**But for Samsung T7 it returns `None` (row 16 proves this).** Hypotheses (unverified —
need real ioreg capture):
- (a) "Serial Number" appears in the parent `IOUSBDevice`, not `IOBlockStorageDevice`,
  so `ioreg -r -c IOBlockStorageDevice -l` doesn't include it at all.
- (b) Samsung T7 firmware reports an empty string `""` — the regex `[^"]+` requires
  ≥1 char so it doesn't match.
- (c) The gap between Serial Number and BSD Name exceeds 50 lines for the Samsung layout
  (many properties between them).
- (d) The serial contains a `"` character that breaks the regex early.

**This is the blocker.** Cannot write a correct fix without seeing the actual ioreg output.
See §6 for what the user needs to do.

### Commit `48c5faa` — "migration v8 replaces product names with real hardware serials"
Added `_migrate_repopulate_drive_identifiers()` in `migrations.py`. It iterates all rows,
clears `device_serial`, then re-runs `collect_drive_identifiers()`. BUT:
```python
for row in rows:
    mount_path = row[1]
    if not mount_path or not Path(mount_path).exists():
        continue
    ...
```
**If the drive is unmounted at migration time, it is skipped entirely.** The product-name
strings survive forever. Row 17 (`"Samsung PSSD T7 Media"`), row 8 (`"LaCie Rugged Mini..."`),
row 15 (`"Lexar ES5 Media"`) are all evidence of this.

### Commit `a023648` — "ambiguous drive dialog now works"
Wired up `POST /drives/resolve-ambiguous` and the `AmbiguousMatchSheet` in DriveListView.
BUT the sheet is only presented from DriveListView.swift:1585 inside the
`NSWorkspace.didMountNotification` handler. There is no entry point from:
- AddDriveSheet (the caption tells the user to "connect from the main view" — no-op once
  already connected)
- App startup (if the drive was mounted before the app launched, the notification has
  already fired)
- A manual "refresh" button (no such button exists)

So in practice, the ambiguous sheet is only visible in the narrow window between
"Claude started and is running" AND "user plugs in the drive now".

---

## 5. Additional bugs found while investigating (do NOT skip)

### 5a. `str(mount_path) == r["mount_path"]` re-include clause (drives.py:448)

```python
candidates_not_mounted = [
    r for r in rows
    if not r["mount_path"] or not Path(r["mount_path"]).exists()
    or str(mount_path) == r["mount_path"]
]
```

The third clause is meant to let a legitimate re-recognition succeed (same drive
re-plugged at the same path). But in the **swap scenario** it is catastrophically wrong:

Scenario: User unplugs Drive A (row 16, stored mount_path `/Volumes/B SSD`). Then plugs
in Drive B (physical new drive), which mounts at `/Volumes/B SSD` because the label is now
free. `recognize_drive()` step 4 matches row 16 via fs_fingerprint. Filter:
- `not r["mount_path"]` → False (row 16 has a path)
- `not Path("/Volumes/B SSD").exists()` → False (Drive B is there now)
- `"/Volumes/B SSD" == "/Volumes/B SSD"` → **True** → include row 16.

→ `len(candidates_not_mounted) == 1` → returns row 16 as "probable" → `POST /drives` says
"Drive already registered as B SSD" → or worse, if `/recognize` is called in an
auto-recognition path that then calls `_update_drive_identifiers()`, **Drive B's
VolumeUUID/DiskUUID overwrite row 16's identifiers, silently merging Drive B's future
scans into Drive A's catalog row.** Data loss by identity collapse.

The same bug exists in step 3 (drives.py:425-429) — identical filter.

**Fix direction:** The re-include clause must require a stronger corroborating signal
than "same path". E.g., require the candidate's `uuid` OR `disk_uuid` OR
`device_serial` to also match the newly-scanned identifiers.

### 5b. `resolve-ambiguous` has no sanity check (routes/drives.py:471-504)

```python
ids = collect_drive_identifiers(path_obj)
_update_drive_identifiers(conn, drive_id, path_obj, ids)
```

Blindly overwrites `drive_id`'s identifiers with whatever is at `path_obj`. No
verification the user picked correctly. If the user mis-clicks Drive A in the picker
when the mounted volume is actually Drive B, **Drive A's UUID and disk_uuid get
replaced with Drive B's values**, and Drive A's catalog is now mislabeled permanently.
Drive A's real file history is attached to a row whose identifiers point at Drive B.

**Fix direction:** Add a confirmation that the new identifiers have some overlap with
the stored identifiers (e.g. at least `fs_fingerprint` matches). If zero overlap,
either refuse or show a scary warning.

### 5c. Ambiguous sheet only reachable via mount notification (DriveListView.swift:1579)

Already covered in §4 under commit `a023648`. Mitigation should be:
- Add a button on ambiguous items in AddDriveSheet that presents `AmbiguousMatchSheet`
  directly with the `candidates` already fetched from `/recognize`.
- Add a "Re-scan mounted drives" or "Identify drive" control somewhere persistent.

---

## 6. BLOCKER — capture Samsung T7 ioreg output

**This is the only thing preventing a correct fix.** Without real data, any fix to
`_get_device_serial_from_ioreg()` is a guess.

### What the user needs to do

Plug in exactly ONE Samsung T7 (not two — start with one to see the layout clean),
then run:

```bash
ioreg -r -c IOBlockStorageDevice -l > /tmp/ioreg_samsung_1.txt
ioreg -l > /tmp/ioreg_full_samsung_1.txt
diskutil list external
diskutil info -plist /Volumes/<samsung-name> > /tmp/samsung_diskutil.plist
```

Then plug in the SECOND Samsung T7 alongside the first and run:

```bash
ioreg -r -c IOBlockStorageDevice -l > /tmp/ioreg_samsung_2.txt
ioreg -l > /tmp/ioreg_full_samsung_2.txt
diskutil list external
```

Save these files somewhere in the repo (or paste them in the chat). The next agent
should look for:
- Where does `"Serial Number"` appear for each drive? (line number relative to the
  drive's block start)
- Where does `"BSD Name" = "diskN"` appear? (line number — we want the whole-disk one,
  not partitions)
- Gap between the two. If >50 lines → window is too narrow.
- Is `"Serial Number"` inside `"Device Characteristics"` (correct), inside
  `"Protocol Characteristics"`, or absent entirely in the `IOBlockStorageDevice`
  subtree and only present in the parent `IOUSBDevice`?
- Is the serial value a plausible hex/alphanumeric string, or is it empty/zeros?
- Are the two drives' serial strings actually distinct? (sanity check — some firmware
  reuses serials)

### If ioreg genuinely has no serial for Samsung T7

Fallback options in priority order:
1. **Query `IOUSBDevice` directly**: `ioreg -r -c IOUSBDevice -l` and walk the device
   tree looking for `"USB Serial Number"`. Correlate by `"BSD Name"` via the child tree.
2. **Use `system_profiler SPUSBDataType -json`**: gives JSON output with USB device
   serial numbers and mount point mappings. Slower but robust.
3. **Fall back to combining `IORegistryEntryName` + a file-content hash** (sample N files'
   names+sizes+mtimes). This is a stronger fingerprint than `fs_fingerprint` because it
   depends on actual content, not just format.
4. **Last resort:** Require user to choose from ambiguous list every time; never
   auto-match on fingerprint alone.

---

## 7. Proposed fix phases (for planning once ioreg data is captured)

### Phase A: ioreg extractor hardening
- Replace the sliding-window regex with a deterministic IOKit property path walker.
- Capture serial from `IOUSBDevice` if `IOBlockStorageDevice` doesn't have it.
- Add unit tests with fixture ioreg outputs (one Samsung, two Samsung, no Samsung).
- Log at WARN level when extraction returns None, with device path for debugging.

### Phase B: Step 4 safety
- In `recognize_drive()`, require a corroborating signal before returning "probable" from
  fs_fingerprint alone. Corroboration = non-null matching `uuid`, `disk_uuid`, OR
  `device_serial` (where "matching" means both sides have it and they're equal).
- If only fs_fingerprint matches and no corroboration → always return "ambiguous"
  with all fingerprint-matching rows.
- Remove the `str(mount_path) == r["mount_path"]` re-include clause from steps 3 and 4.
  Replace with a separate explicit "re-recognition" path that requires UUID or serial
  match plus same path.

### Phase C: Migration v9 — unconditional cleanup of stale product-name serials
- Detect rows where `device_serial LIKE '% Media'` OR
  `device_serial = 'Untitled'` OR
  `device_serial = ''`.
- Set those to `NULL` (unconditionally, no mount_path check).
- On next recognition, they'll either get a real serial or stay null — either is fine.
- Do NOT delete the row or touch other columns. Non-destructive.

### Phase D: AddDriveSheet can resolve ambiguous
- `/recognize` already returns the candidate list for ambiguous status.
- Make ambiguous items in AddDriveSheet tappable → present `AmbiguousMatchSheet`
  with the candidates.
- Add a "None of these — register as new drive" option that bypasses the ambiguous
  check (forces a new row insert with the current identifiers).

### Phase E: `resolve-ambiguous` sanity check
- Before overwriting, compare incoming identifiers against the selected drive's row.
- If `fs_fingerprint` and `total_bytes` and `partition_index` all match → proceed.
- If any mismatch → 409 with details, force user to re-confirm via a more aggressive
  warning dialog.

### Phase F: Diagnostic endpoint
- Add `GET /drives/diagnose?mount_path=...` that returns:
  - All collected identifiers (`collect_drive_identifiers` output)
  - The full cascade trace (which steps matched/skipped/why)
  - The current DB rows that would be candidates at each step
- This makes future bugs 10x faster to debug. Also useful for the user to run and paste
  the output when they hit recognition edge cases.

---

## 8. How to verify the fix once implemented

### Test 1: stale product names cleaned
```bash
sqlite3 ~/.drivecatalog/catalog.db \
  "SELECT id, name, device_serial FROM drives WHERE device_serial LIKE '% Media';"
```
Should return zero rows after Phase C migration runs.

### Test 2: two Samsung T7s both registrable
1. Register Drive A → catalog row has a non-null, plausible `device_serial`.
2. Unplug A. Plug in Drive B at any mount path.
3. `POST /drives/recognize?mount_path=/Volumes/<B>` → `status="ambiguous"` OR `"not_found"`,
   NOT `"recognized"`.
4. `POST /drives` for Drive B → succeeds with HTTP 201, new row created.
5. `sqlite3 ... "SELECT fs_fingerprint, COUNT(*) FROM drives GROUP BY fs_fingerprint HAVING COUNT(*) > 1;"`
   → may still show collisions on fs_fingerprint, but `device_serial` column should
   distinguish them.

### Test 3: swap scenario no longer corrupts identity
1. Register Drive A at `/Volumes/X`.
2. Unplug A.
3. Plug in Drive B which macOS mounts at `/Volumes/X`.
4. `POST /drives/recognize?mount_path=/Volumes/X` → must NOT return `confidence="probable"`
   pointing at Drive A unless device_serial or disk_uuid match.
5. Check Drive A's DB row — its `uuid` and `disk_uuid` must NOT have been overwritten.

### Test 4: Ambiguous path reachable from AddDriveSheet
1. Set up two fingerprint-colliding drives both mounted.
2. Open Add Drive sheet → one drive appears in the ambiguous list.
3. Tap the ambiguous entry → `AmbiguousMatchSheet` appears with candidates.
4. Select "None of these — register as new drive" → drive is added with HTTP 201.

### Test 5: resolve-ambiguous rejects nonsense
1. Create two non-colliding drives A and B in the catalog with different fingerprints.
2. Mount drive B, call
   `POST /drives/resolve-ambiguous?mount_path=/Volumes/<B>&drive_id=<A's id>`.
3. Expect HTTP 409 because B's fingerprint ≠ A's fingerprint.
4. A's stored identifiers must be unchanged.

---

## 9. Files the next agent will almost certainly touch

- `src/drivecatalog/drives.py` (extractor + recognize_drive)
- `src/drivecatalog/api/routes/drives.py` (cascade consumer, resolve-ambiguous)
- `src/drivecatalog/migrations.py` (Phase C migration v9)
- `DriveCatalog/Views/Drives/AddDriveSheet.swift` (ambiguous entry point)
- `DriveCatalog/Views/Drives/DriveListView.swift` (AmbiguousMatchSheet already exists at 2576+)
- Tests under `tests/` if any — check for `test_drives.py` and follow the pattern there.

---

## 10. Things the next agent should NOT do

- Do not treat `fs_fingerprint` as a strong identifier. It is a collision-prone hash by
  design (same model + same format = same hash).
- Do not "fix" the sliding-window regex by widening the window to 100/200 lines — that
  just trades false negatives for false positives when two Samsung drives are adjacent
  in the ioreg tree.
- Do not remove the re-recognition path entirely — there are legitimate cases where a
  drive re-mounts at the same path with the same UUID and should be recognized
  automatically. The fix is to require matching identifiers, not to remove the path.
- Do not run `_migrate_repopulate_drive_identifiers` unconditionally on unmounted drives
  by calling `collect_drive_identifiers(Path(mount_path))` — that will fail when the path
  doesn't exist. Phase C is about clearing garbage (`device_serial = NULL` unconditionally),
  not about extracting fresh identifiers for unmounted drives.
- Do not delete or alter rows 16 and 17 manually. They are valuable evidence. If you
  need to test, use a scratch DB.

---

## 11. Related design context

- `design/DECISIONS.md` D5 (2026-04-06): "Multi-Signal Drive-Erkennung statt nur VolumeUUID.
  Identifier-Kaskade: VolumeUUID → DiskUUID → Device Serial + Partition Index →
  FS-Fingerprint. Bei Ambiguität User fragen, niemals auto-assignen." → This decision
  is **correct** but the implementation at step 4 violates the "niemals auto-assignen"
  part by returning "probable" for single-candidate fingerprint matches.
- `design/STATE.md`: updated with the live DB collision evidence.
- `design/OPEN_QUESTIONS.md` Q5: tracks the ioreg capture request.
- `design/OPEN_QUESTIONS.md` Q6: tracks the fix-scope decision.

---

## 12. Checklist for the next agent

- [ ] Read this entire handoff.
- [ ] Ask the user for the ioreg captures described in §6 (or proceed with fallback
      system_profiler approach if user can't get the captures quickly).
- [ ] Verify the DB collision still exists: `sqlite3 ~/.drivecatalog/catalog.db
      "SELECT fs_fingerprint, COUNT(*), GROUP_CONCAT(name) FROM drives WHERE
      fs_fingerprint IS NOT NULL GROUP BY fs_fingerprint HAVING COUNT(*) > 1;"`
- [ ] Read `drives.py:93-129`, `drives.py:377-482`, `routes/drives.py:102-186`,
      `routes/drives.py:471-504` to confirm the code hasn't changed since this handoff.
- [ ] Run the `git log --oneline -25 -- src/drivecatalog/drives.py` to see if anything
      new landed since commit `a023648`.
- [ ] Design Phase A (extractor) concretely once ioreg data is in hand.
- [ ] Write a `/plan` (sparring partner pattern) or create executor tasks — do NOT start
      coding until the user has reviewed and confirmed the fix direction.
- [ ] Update this handoff file when picking up (append a "Pickup notes" section at the
      bottom) so the trail stays clear.
