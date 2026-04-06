| 2026-04-06 13:01 UTC | DC-001 | verified | Implemented folder-level duplicate and subset detection with GET /folder-duplicates API endpoint |
| 2026-04-06 13:03 UTC | DC-001 | review:approved | All 9 acceptance criteria met; solid implementation with good test coverage (13 tests passing) |
| 2026-04-06 13:08 UTC | DC-002 | verified | Implemented catalog file bundle recognition: files inside .cocatalog, .photoslibrary, .RDC bundles are flagged as catalog-protected via a new catalog_bundle column, with data migration for existing files and warnings in the duplicate API. |
| 2026-04-06 13:09 UTC | DC-002 | review:changes_requested | 3 missing bundle extensions, column type is INTEGER/boolean instead of TEXT with bundle root path per AC, API field is group-level instead of per-file |
| 2026-04-06 13:15 UTC | DC-003 | verified | Implemented unified Manage page merging Insights + Backups into 3 sections: Backup Status, Duplikate & Platzgewinn, Empfohlene Aktionen. Sidebar updated: .insights/.backups removed, .manage added with rectangle.3.group icon. Folder-duplicate API integrated with graceful degradation. |
| 2026-04-06 13:16 UTC | DC-004 | verified | verified |
| 2026-04-06 13:16 UTC | DC-005 | verified | verified |
| 2026-04-06 13:17 UTC | DC-006 | verified | verified |
| 2026-04-06 13:17 UTC | DC-003 | review:changes_requested | Core structure solid (3 sections, sidebar, routing, graceful degradation), but Section 1 missing per-drive detail fields and drill-down, Section 2 missing per-drive duplicate breakdown. |
| 2026-04-06 13:17 UTC | DC-008 | verified | verified |
