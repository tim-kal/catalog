# Phase 1: Core Improvements

Independent backend and infrastructure work that unblocks later UI tasks.

## Tasks

- [ ] DC-001 — Ordner-Duplikat-Erkennung: exakter Ordner-Match und Subset-Detection im Backend, neues Modul folder_duplicates.py, API-Endpoint GET /folder-duplicates
- [ ] DC-002 — Katalog-Dateien Bundle-Erkennung: Dateien in .cocatalog .photoslibrary .RDC als catalog-protected markieren, DB-Migration, Warnung in Duplikat-API
- [ ] DC-005 — Paralleles Scannen: Per-Drive-Lock, WAL concurrent writes verifizieren, Scan-All Button, 409 bei laufendem Scan derselben Drive
- [ ] DC-006 — Feedback-Pipeline: Vercel-Backend für bug-report Endpoint, erstellt GitHub Issues mit Labels und Rate-Limiting
- [ ] DC-007 — Drive-Rename Sync: macOS-Umbenennung automatisch in DB übernehmen via UUID-Match, Reverse via diskutil rename
