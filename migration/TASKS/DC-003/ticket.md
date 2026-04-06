# DC-003 — Manage Page (Backup + Insights + Aktionen zusammenführen)

## Goal
Replace the separate "Insights" and "Backups" sidebar items with a single "Manage" page that combines backup status, duplicate/space insights, and recommended actions into one actionable view.

## Acceptance Criteria
- [ ] New `ManageView.swift` replaces InsightsView and the Backups tab in the sidebar
- [ ] Sidebar changes: remove "Insights" and "Backups" items, add "Manage" item (icon: `rectangle.3.group`)
- [ ] Update `SidebarItem` enum in `NavigationModel.swift`: remove `.insights` and `.backups`, add `.manage`
- [ ] Update `ContentView.swift` to show `ManageView` for `.manage` selection
- [ ] ManageView has 3 sections (collapsible or tabs):

### Section 1: Backup Status
- Per-drive summary: drive name, total files, files with backup (exist on another drive), percentage backed up, unprotected size
- Per-folder drill-down: click a drive to see which top-level folders are backed up and which aren't
- Visual: progress bar per drive showing backup coverage

### Section 2: Duplikate & Platzgewinn
- Existing duplicate stats (from current InsightsView) 
- Plus: folder-level duplicates from DC-001 endpoint (if available — gracefully degrade if endpoint doesn't exist yet)
- Show total reclaimable space
- Per-drive breakdown of duplicate space

### Section 3: Empfohlene Aktionen
- Sorted list of recommended next actions, e.g.:
  - "Drive X has 40GB of duplicates — consolidate to free space"
  - "Drive Y has no backup — copy critical folders to Drive Z"
  - "Folder /Photos/2024 exists on 3 drives — keep one, reclaim 12GB"
- Each action links to the relevant view/action (e.g. opens duplicate view filtered to that drive)

## Relevant Files
- `DriveCatalog/Views/InsightsView.swift` — current insights implementation (reuse data fetching logic)
- `DriveCatalog/Views/AllDrivesView.swift` — might be the current Backups view, check
- `DriveCatalog/Navigation/NavigationModel.swift` — SidebarItem enum
- `DriveCatalog/Navigation/Sidebar.swift` — sidebar definition
- `DriveCatalog/ContentView.swift` — view switching
- `DriveCatalog/Services/APIService.swift` — API calls to backend

## Context
The app currently has separate pages for Insights (space analysis), Backups (which files have copies), and an Action Queue. The user finds this fragmented — they want one place that answers "what should I do next with my drives?" The Manage page is the answer.

Important nuances:
- Backup status should show BOTH per-drive ("78% of Drive X is backed up") AND per-folder ("folder Photos/2024 has no backup anywhere")
- "Backed up" means: at least one copy of the file exists on a different drive
- The recommendations section should be data-driven, not hardcoded. Calculate from actual duplicate/backup data.
- Keep it performant — don't fetch all file data upfront, use summary endpoints
