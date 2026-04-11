# DC-016 — Frontend: Transfer UI with Progress and Verification Report

## Goal
SwiftUI interface for initiating transfers, watching progress, and viewing the final verification report.

## Acceptance Criteria

### Transfer initiation
- [ ] New "Transfer" button in the drive detail view (or file browser context menu)
  - When clicked, shows a sheet with:
    - Source drive (pre-filled from current drive context)
    - Destination drive picker (dropdown of mounted drives, excluding source)
    - Path selection: "Entire drive" or specific folders (from the file tree)
    - Destination folder field (optional, defaults to preserving source structure)
    - "Start Transfer" button
- [ ] Calls `POST /transfers` with selected parameters
- [ ] Shows error if dest drive not mounted or not enough space

### Transfer progress view
- [ ] After starting, navigate to a TransferProgressView that shows:
  - Overall progress bar (bytes transferred / total bytes)
  - File counter: "47 / 150 files"
  - Current file name being copied
  - Transfer speed (MB/s, computed from bytes/time)
  - ETA (from operations.py ETA calculation)
  - "Cancel" button
- [ ] Polls `GET /operations/{operation_id}` every 500ms for progress updates
- [ ] On completion, automatically transitions to the report view

### Transfer report view
- [ ] Shows after transfer completes:
  - Big green checkmark if all files verified, red warning if failures
  - Summary: "150 files, 45.2 GB transferred, all verified"
  - Duration (human-readable, e.g. "12 minutes 34 seconds")
  - If failures: expandable list of failed files with error reason
  - "Verify Again" button that calls `POST /transfers/{id}/verify` and shows progress
  - "Done" button to dismiss
- [ ] Data comes from `GET /transfers/{transfer_id}/report`

### Transfer history
- [ ] Add "Transfer History" to the sidebar or settings area
  - Lists past transfers from `GET /transfers`
  - Tapping a transfer shows its report view
  - Shows status badge: green (all verified), orange (partial), red (failed)

### APIService extension
- [ ] Add methods to APIService.swift:
  - `createTransfer(sourceDrive:destDrive:paths:destFolder:)` → POST /transfers
  - `getTransferStatus(transferId:)` → GET /transfers/{id}
  - `getTransferReport(transferId:)` → GET /transfers/{id}/report
  - `verifyTransfer(transferId:)` → POST /transfers/{id}/verify
  - `cancelTransfer(transferId:)` → POST /transfers/{id}/cancel
  - `listTransfers()` → GET /transfers

## Relevant Files
- `DriveCatalog/Views/Transfers/TransferSheet.swift` (NEW — initiation)
- `DriveCatalog/Views/Transfers/TransferProgressView.swift` (NEW — progress)
- `DriveCatalog/Views/Transfers/TransferReportView.swift` (NEW — report)
- `DriveCatalog/Views/Transfers/TransferHistoryView.swift` (NEW — history list)
- `DriveCatalog/Services/APIService.swift` (extend)
- `DriveCatalog/Views/Drives/DriveListView.swift` (add transfer button entry point)

## Context
This is the user-facing part of the safe transfer feature. The backend (DC-014, DC-015) handles the actual copying and verification. The frontend provides the UI.

The photographer workflow: plug in two drives → select folders on source → pick destination → watch progress → see green checkmark → confidence that all files are safe on the new drive.

Key UX principles:
- Never make the user wonder if it worked. Show definitive pass/fail.
- Progress must feel responsive (update frequently, show speed + ETA).
- The "Verify Again" button is for paranoid users who want to re-read every file from disk after the transfer. It's the equivalent of ChronoSync's "Verify Bootable Backup" feature.
- Transfer history lets users go back and check past transfers.

The file tree selection can be simplified for v1: just offer "entire drive" or let user type/paste a folder path. Fancy tree-selection UI can come later.
