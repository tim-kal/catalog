# DC-015 — Transfer Verification Report

## Goal
After a transfer completes, the user needs a definitive report proving every file arrived intact. This endpoint re-verifies transferred files and produces a structured report.

## Acceptance Criteria

### Verification endpoint
- [ ] `POST /transfers/{transfer_id}/verify` — Re-verify all completed transfer actions
  - For each action with status='completed':
    1. Read the dest file from disk
    2. Compute full SHA-256 hash
    3. Compare against the `dest_hash` stored in `copy_operations`
    4. Record pass/fail
  - Returns a `TransferVerificationReport`:
    ```json
    {
      "transfer_id": "...",
      "verified_at": "2026-04-11T...",
      "total_files": 150,
      "verified_ok": 148,
      "verified_failed": 1,
      "skipped": 1,
      "failures": [
        {"path": "DCIM/IMG_001.CR3", "reason": "hash_mismatch", "expected": "abc...", "actual": "def..."},
        {"path": "DCIM/IMG_042.MOV", "reason": "file_missing"}
      ],
      "total_bytes_verified": 45000000000,
      "duration_seconds": 120
    }
    ```
  - Runs as background operation with progress tracking via operations.py
  - Returns `{operation_id, poll_url}` immediately

### Transfer summary endpoint
- [ ] `GET /transfers/{transfer_id}/report` — Return summary without re-verifying
  - Aggregates from planned_actions + copy_operations tables
  - Returns: file counts by status (completed/failed/pending/cancelled), total bytes, duration, list of failures with error messages
  - This is fast (DB query only, no disk I/O)

### Transfer history endpoint
- [ ] `GET /transfers` — List all transfers with summary stats
  - Returns: `[{transfer_id, source_drive, dest_drive, total_files, completed, failed, created_at, status}]`
  - Status derived from action counts: "completed" (all done), "partial" (some failed), "in_progress", "cancelled"

### Tests
- [ ] Test verify endpoint: mock file reads, assert report has correct pass/fail counts
- [ ] Test verify with missing file: assert it appears in failures with reason "file_missing"
- [ ] Test report endpoint: insert test data, assert correct aggregation
- [ ] Test transfers list: create 2 transfers, assert both appear with correct summaries

## Relevant Files
- `src/drivecatalog/api/routes/transfers.py` (extend from DC-014)
- `src/drivecatalog/transfer.py` (add verify function)
- `tests/test_transfers.py` (extend from DC-014)

## Context
The verification report is the user's proof that the transfer succeeded. Photographers moving originals between drives need to see "150/150 files verified, 0 failures" before they trust that the destination has everything. The re-verification pass reads every file from the destination drive and recomputes SHA-256 — this is the gold standard approach used by ChronoSync and Carbon Copy Cloner.

The report endpoint (no re-read) gives a quick summary. The verify endpoint (full re-read) is the paranoid "prove it to me" button.
