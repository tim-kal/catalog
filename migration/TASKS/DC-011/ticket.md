# DC-011 — Strukturierte Fehlercodes für User-Support

## Goal
Add a structured error code system so that when something goes wrong, users see a short, memorable code (e.g. `DC-E001`) they can report back. The developer can then immediately look up what happened without needing the full log file.

## Acceptance Criteria

### Backend: Error code registry
- [ ] New module `src/drivecatalog/errors.py` with an enum or dict of all known error codes:
  ```
  DC-E001: Database locked — another process is using the database
  DC-E002: Backend startup failed — port already in use
  DC-E003: Drive not accessible — mount path does not exist
  DC-E004: Scan failed — permission denied on directory
  DC-E005: Hash computation failed — file changed during read
  DC-E006: Migration failed — see backup file
  DC-E007: Copy operation failed — destination full
  DC-E008: Integrity verification failed — hash mismatch detected
  DC-E009: API request failed — internal server error
  DC-E010: Drive recognition ambiguous — multiple candidates
  ```
- [ ] Each error has: code, short title, description, severity (error|warning|info)
- [ ] New function `log_error(code, context=None)` that writes to a structured error log at `~/.drivecatalog/errors.jsonl` (one JSON line per error, with timestamp, code, context)
- [ ] Backend API error responses include the error code in the response body: `{"detail": "...", "error_code": "DC-E003"}`

### Backend: Error log endpoint
- [ ] New endpoint `GET /errors` — returns last 50 errors from the JSONL log
- [ ] New endpoint `GET /errors/summary` — returns count per error code (for diagnostics)

### Frontend: Error display
- [ ] When the UI receives an API error with an `error_code` field, display it prominently: "Error DC-E003: Drive not accessible"
- [ ] Settings page: new section "Error Log" showing recent errors with codes, timestamps, and descriptions
- [ ] Each error row has a "Copy" button that copies a support-friendly string: "DC-E003 at 2026-04-06 15:30 — Drive not accessible: /Volumes/MyDrive"
- [ ] Bug Report (BugReportView): auto-include the last 10 error codes in the report body

### Frontend: Startup errors
- [ ] If backend fails to start: show the most likely error code based on the log tail (e.g. port in use → DC-E002, Python not found → new code)
- [ ] If migration fails: show DC-E006 with the backup file path

### Integration with existing code
- [ ] Wrap existing try/except blocks in scanner.py, copier.py, drives.py with `log_error()` calls — don't change behavior, just add logging
- [ ] API route error handlers (HTTPException raises) include the matching error_code
- [ ] BackendService.swift startup error parsing: detect known patterns in backend.log tail and map to error codes

## Relevant Files
- `src/drivecatalog/errors.py` — new module
- `src/drivecatalog/scanner.py` — add log_error to scan failures
- `src/drivecatalog/copier.py` — add log_error to copy failures
- `src/drivecatalog/drives.py` — add log_error to recognition failures
- `src/drivecatalog/migrations.py` — add log_error to migration failures
- `src/drivecatalog/api/routes/*.py` — include error_code in HTTPException responses
- `DriveCatalog/Services/APIService.swift` — parse error_code from responses
- `DriveCatalog/Views/SettingsView.swift` — error log section
- `DriveCatalog/Views/BugReportView.swift` — auto-include error codes

## Context
Currently, when something goes wrong the user sees either a generic error message or a raw Python traceback in the log. Neither is useful for support. The error code system gives users a short code to report ("I'm getting DC-E003") and gives the developer an immediate lookup path.

The JSONL error log is separate from the backend.log (which contains everything including normal operations). The error log contains ONLY errors with structured data, making it easy to parse and include in bug reports.

Keep the initial code list at ~10-15 codes covering the most common failures. New codes can be added as new error patterns are discovered. The code format DC-ENNN is chosen to not conflict with task IDs (DC-NNN).
