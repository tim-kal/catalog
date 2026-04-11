# DC-014 — Batch Transfer Engine

## Goal
Enable transferring many files between drives in one operation, with per-file tracking, resume on interrupt, and overall progress. This is the core engine that the frontend transfer UI (DC-016) will drive.

## Acceptance Criteria

### New module: src/drivecatalog/transfer.py
- [ ] `TransferManifest` dataclass:
  ```python
  @dataclass
  class TransferManifest:
      transfer_id: str        # UUID
      source_drive: str       # drive name
      dest_drive: str         # drive name
      files: list[dict]       # [{path, size_bytes, source_file_id}, ...]
      total_bytes: int
      total_files: int
  ```
- [ ] `create_transfer(conn, source_drive, dest_drive, paths)` function:
  - Takes a list of relative paths (or a folder path to expand)
  - Queries the files table for matching entries on source_drive
  - Creates a `TransferManifest` with a new UUID
  - Inserts one `planned_actions` row per file (action_type='copy', status='pending', transfer_id=UUID)
  - Returns the manifest
- [ ] `execute_transfer(conn, transfer_id, progress_callback)` function:
  - Queries all pending/failed actions for the transfer_id, ordered by source_path (directory-batched for HDD locality)
  - For each file:
    1. Update status to 'in_progress'
    2. Call `copy_file_verified()` (from DC-012 hardened copier)
    3. On success: update status to 'completed', log to copy_operations
    4. On failure: update status to 'failed', store error, continue to next file
    5. Call progress_callback with (files_done, files_total, bytes_done, bytes_total, current_file)
  - After all files: return a `TransferResult` with counts and any failures
- [ ] `resume_transfer(conn, transfer_id)` function:
  - Re-runs `execute_transfer` — it naturally skips 'completed' actions
  - Deletes any `.dctmp` files from previously failed/in-progress actions before retrying
- [ ] `get_transfer_status(conn, transfer_id)` function:
  - Returns: total/completed/failed/pending counts, total_bytes, bytes_copied, list of failed files

### API endpoints: src/drivecatalog/api/routes/transfers.py
- [ ] `POST /transfers` — Create and start a batch transfer
  - Request body: `{source_drive, dest_drive, paths: [str], dest_folder?: str}`
  - If `paths` contains a folder, expand to all files in that folder recursively
  - Validates both drives mounted
  - Creates manifest, starts `execute_transfer` as background task
  - Returns `{transfer_id, operation_id, total_files, total_bytes}`
- [ ] `GET /transfers/{transfer_id}` — Get transfer status
  - Returns manifest + progress + per-file status for failed items
- [ ] `POST /transfers/{transfer_id}/resume` — Resume a failed/interrupted transfer
  - Restarts execution for pending/failed items
- [ ] `POST /transfers/{transfer_id}/cancel` — Cancel a running transfer
  - Sets all pending actions to 'cancelled'
  - Does NOT delete already-copied files
- [ ] Register router in `src/drivecatalog/api/main.py`

### Directory-batched ordering
- [ ] When building the execution order, sort files by directory path (parent folder) then filename
- [ ] This matches the `directory_batched` strategy from `benchmarks/hash_ordering.py` which showed significant speedup on HDDs

### Folder transfer support
- [ ] When source path is a directory (not a file), recursively list all files
- [ ] Preserve directory structure on destination: `dest_folder/relative_path`
- [ ] Create all needed directories before starting file copies

### Tests
- [ ] Test create_transfer with 3 files → 3 planned_actions rows created
- [ ] Test execute_transfer: mock copy_file_verified, assert all actions reach 'completed'
- [ ] Test resume: set 2 of 3 to 'completed', resume copies only the remaining 1
- [ ] Test cancel: pending items become 'cancelled', completed items untouched
- [ ] Test folder expansion: pass a folder path, assert all files within are included
- [ ] Test directory-batched ordering: assert files are sorted by parent dir

## Relevant Files
- `src/drivecatalog/transfer.py` (NEW)
- `src/drivecatalog/api/routes/transfers.py` (NEW)
- `src/drivecatalog/api/main.py` (register router)
- `src/drivecatalog/copier.py` (depends on DC-012 hardening)
- `src/drivecatalog/api/routes/actions.py` (planned_actions table from DC-013)
- `tests/test_transfers.py` (NEW)

## Context
DriveCatalog currently has only a single-file `POST /copy` endpoint. Photographers need to transfer entire folders (thousands of RAW files, video clips) between drives. This task builds the batch engine. The frontend (DC-016) will call these endpoints.

The existing `POST /copy` endpoint in `copy.py` should remain as-is for single-file operations. The new `/transfers` endpoints are the batch interface.

The `planned_actions` table (from DC-013) stores per-file state. `transfer_id` groups all actions in one batch. The execution engine processes them sequentially (one file at a time — no parallel I/O, it's worse on HDDs).

Use `create_operation()` from `operations.py` for the overall transfer operation, and update progress via `update_progress()`. The frontend polls `GET /operations/{id}` for real-time progress.
