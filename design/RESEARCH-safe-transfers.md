# Research: Safe Verified Data Transfers

**Date:** 2026-04-11
**Purpose:** Design a transfer feature where photographer users can be 100% confident all files arrived intact.

---

## What We Already Have

### copier.py — single-file verified copy
- `copy_file_verified()`: streams source with SHA256 while writing, re-reads dest to verify
- 64KB chunks, progress callback, logs to `copy_operations` table
- **Gaps**: no fsync, no atomic write, no metadata preservation, small buffer

### copy.py route — POST /copy
- Single-file background copy with operation polling
- Validates drives mounted, source in catalog, dest doesn't exist

### consolidation.py — analysis only
- Distribution, candidates, strategy (bin-packing), recommendations
- All read-only — no execution engine

### actions.py — planned actions queue
- CRUD for delete/copy/move actions with dependency chains, priorities
- **TABLE NOT CREATED** — referenced in SQL but no migration creates `planned_actions`

### hasher.py — xxHash partial hashing
- `compute_partial_hash()`: first+last 64KB (for dedup)
- `compute_verification_hash()`: first+middle+last 64KB (for safe deletion)

---

## Research Findings

### Verification pattern (ChronoSync, CCC, rsync)
All three converge on: **copy, then re-read destination and hash**. ChronoSync explicitly does NOT stream-verify — re-reading from disk is the only way to confirm data landed on physical medium (not just OS cache). Our `copier.py` already does this correctly (stream-hash source + re-read dest). The critical missing piece is `fsync()`.

### Atomicity (ChronoSync, CCC)
Both write to temp files (`.filename.part`) then atomic rename. On APFS/HFS+, rename within same volume is atomic. Prevents partial files from appearing complete on crash.

### Metadata preservation
- `copyfile(3)` / `NSFileManager.copyItem` preserves: xattrs, resource forks, ACLs, creation dates, BSD flags
- `shutil.copy2()` preserves mtime but NOT xattrs, creation dates, resource forks
- Our `copier.py` raw open/write preserves NOTHING — not even mtime
- For photographers: creation date and Finder tags are critical

### Buffer size
- 64KB = ~780K syscalls for a 50GB video file
- 1MB = ~50K syscalls — significant reduction at USB 3.0+ speeds
- Disk I/O (100-400 MB/s) is bottleneck, not SHA-256 (~500 MB/s on Apple Silicon)

### Resume capability
ChronoSync uses a SQLite journal tracking per-file state. On resume, skips verified files, retries in-progress ones. Our `copy_operations` table has the right shape but needs a `status` column.

### Hash algorithm choice
SHA-256 for copy verification (full-file, trustworthy). xxHash for dedup (fast, partial). Keep them separate. If source already has `full_hash` in DB, can skip re-hashing source during copy.

---

## Concrete Gaps to Close

| Gap | Severity | Effort |
|---|---|---|
| No `fsync()` — data may be in OS cache not on disk | Critical | Trivial |
| No atomic write (temp + rename) | High | Small |
| 64KB buffer too small for video files | High | Trivial |
| No metadata preservation (mtime, xattrs, birthtime) | High | Medium |
| No batch transfer (only single-file POST /copy) | High | Large |
| `planned_actions` table missing from schema | High | Small |
| No transfer manifest / completion report | Medium | Medium |
| No resume on interrupt | Medium | Medium |
| Progress callback on every 64KB chunk (UI spam) | Low | Trivial |
