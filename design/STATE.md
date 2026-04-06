# DriveSnapshots — State

## What It Is
**DriveCatalog** — macOS desktop app (SwiftUI + Python/FastAPI) for cataloging external drives, detecting duplicates, browsing files, managing consolidation/migration. v1.2.

## Architecture
- **Frontend**: SwiftUI macOS 14.0+, ~12k LOC, 43 Swift files. NavigationSplitView with sidebar.
- **Backend**: Python FastAPI, ~5.4k LOC, 30+ modules. Embedded subprocess via BackendService.swift.
- **Database**: SQLite WAL at `~/.drivecatalog/catalog.db`. Custom migrations.
- **Build**: XcodeGen. Embedded Python for release, uv for dev.
- **Comms**: HTTP localhost. APIService.swift ↔ FastAPI.

## Open Design Threads (from last session)

### 1. Manage Page (merge Backup + Insights)
Decision: merge into single "Manage" page with sections: Backup Status (per folder AND per drive), Duplikate & Platzgewinn, Empfohlene Aktionen. Replaces separate Insights + Backups sidebar items.

### 2. Ordner-Duplikat-Erkennung
Must be exact: full hash match on all files in both dirs = Ordner-Duplikat. Subset detection (A ⊂ B). No fuzzy thresholds — precision tool. Show on Manage page alongside file-level duplicates.

### 3. Katalog-Dateien (.cocatalog, .photoslibrary, .RDC)
Capture One + Photos.app bundles contain real originals (esp. tethered shooting). Scanner currently traverses into bundles and finds "duplicates". Need: detect known bundle extensions, mark files inside as "catalog-protected", warn before any delete action.

### 4. Parallel Scanning
Currently: one scan = one BackgroundTask thread. SQLite WAL should handle concurrent writes but never tested. No per-drive lock, no UI for parallel scan status. Feature to build.

### 5. Feedback/Ticket Pipeline
BugReportView exists, sends to `catalog-beta.vercel.app/api/bug-report`. Backend status unknown — may not exist yet. Goal: bug → GitHub Issue → notification to operator. Ambitious pipeline (auto-analyze, test, release) deferred.

### 6. Konsolidierungs-Reihenfolge
User wants: "where to move data, in what order, to maximize freed space". Needs Manage page + Ordner-Duplikat logic first.
