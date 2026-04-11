# DC-012 — Harden copier: fsync, atomic write, 1MB buffer, metadata preservation

## Goal
Make `copy_file_verified()` crash-safe, performant with large files, and metadata-preserving. This is the foundation for all transfer features.

## Acceptance Criteria

### Critical: fsync before close
- [ ] After writing all chunks and before closing the dest file, call `dest_file.flush()` followed by `os.fsync(dest_file.fileno())`. This ensures data is on the physical medium, not just in OS cache. Without this, a power loss after "verified" copy can produce a corrupt file.

### Critical: atomic temp-file write
- [ ] Write to `dest_path.with_suffix(dest_path.suffix + ".dctmp")` (e.g. `photo.CR3.dctmp`)
- [ ] After successful verification (hashes match), `os.rename()` the .dctmp to the final path
- [ ] On failure or hash mismatch, delete the .dctmp file and return error
- [ ] On crash recovery, any `.dctmp` files in the destination are known-incomplete and safe to delete

### High: increase buffer to 1MB
- [ ] Change `CHUNK_SIZE` in `copier.py` to `1 * 1024 * 1024` (1MB)
- [ ] Do NOT change `CHUNK_SIZE` in `hasher.py` — that one stays at 64KB (it only reads 128KB total per file)
- [ ] Rationale: 64KB = ~780K syscalls for a 50GB video file. 1MB = ~50K. USB 3.0+ throughput improves significantly.

### High: preserve metadata after copy
- [ ] After successful data copy + verification, preserve file metadata:
  - `shutil.copystat(source, dest)` — preserves mtime, atime, mode
  - Copy creation date (birthtime): use `os.stat(source).st_birthtime` and set it on dest via a macOS-specific approach. Simplest: `subprocess.run(["SetFile", "-d", formatted_date, str(dest)])` if Xcode CLI tools are available, OR use `ctypes` to call `setattrlist`. If neither works, log a warning but don't fail.
  - Copy extended attributes (Finder tags, color labels): iterate `os.listxattr(source)` and call `os.setxattr(dest, name, os.getxattr(source, name))` for each. Catch and log errors per-xattr (some may be system-only).
- [ ] Add a `metadata_preserved: bool` field to `CopyResult` dataclass

### Medium: throttle progress callbacks
- [ ] Only call `progress_callback` at most every 250ms (check `time.monotonic()` against last call)
- [ ] Always call on the final chunk (100% progress)

### Tests
- [ ] Test that fsync is called (mock `os.fsync`, assert called once)
- [ ] Test atomic write: on hash mismatch, assert .dctmp is deleted and final path does not exist
- [ ] Test atomic write: on success, assert final path exists and .dctmp does not
- [ ] Test metadata: after copy, assert dest mtime matches source mtime (within 1s tolerance)
- [ ] Test 1MB chunks: mock file read, assert chunk size is 1MB

## Relevant Files
- `src/drivecatalog/copier.py` — main target
- `tests/test_copier.py` (create if not exists, or add tests to existing)

## Context
The current copier works but has three safety gaps:
1. No fsync — data may be in OS write cache, not on disk. A power failure after "verified" copy corrupts the file silently.
2. No atomic write — if the app crashes mid-copy, a partial file sits at the destination looking like a real file.
3. No metadata — photographers lose creation dates and Finder tags, breaking their sort-by-date workflows.

Buffer size (64KB) causes unnecessary syscall overhead for large media files (10-100GB ProRes, RAW sequences).

Do NOT touch `hasher.py` or its CHUNK_SIZE. The hasher intentionally reads small amounts for fast partial hashing. Only `copier.py`'s CHUNK_SIZE changes.
