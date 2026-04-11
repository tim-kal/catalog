# Decisions

## D1 — 2026-04-06: Ordner-Duplikate müssen exakt sein
Keine fuzzy Thresholds (>80% etc.). Ordner-Duplikat = 100% Hash-Match aller Dateien in beiden Richtungen. Subset = alle Hashes von A existieren in B. Begründung: Precision-Tool, Datenverlust vermeiden.

## D2 — 2026-04-06: Insights + Backups → Manage Page zusammenlegen
Eine "Manage"-Seite ersetzt beide. Drei Sections: Backup-Status (pro Drive UND pro Ordner), Duplikate & Platzgewinn, Empfohlene Aktionen. Insights als separater Sidebar-Item fällt weg.

## D3 — 2026-04-06: Katalog-Dateien scannen aber schützen
Bundles (.cocatalog, .photoslibrary, .RDC etc.) werden normal gescannt, aber Dateien darin als "catalog-protected" markiert. UI warnt vor Löschen. Nicht: Bundles überspringen.

## D4 — 2026-04-06: Task-Aufteilung für Executor
DC-001 bis DC-010 (DC-007 superseded by DC-008). Abhängigkeiten: DC-001 → DC-003, DC-004.

## D5 — 2026-04-06: Multi-Signal Drive-Erkennung statt nur VolumeUUID
Identifier-Kaskade: VolumeUUID → DiskUUID → Device Serial + Partition Index → FS-Fingerprint. Bei Ambiguität User fragen, niemals auto-assignen.

## D6 — 2026-04-06: Migration-Strategie = Lightroom-Pattern
Backup vor Migration, File-basierter Fortschritt (kein HTTP — Server blockiert im Lifespan), Rollback bei Fehler. Frontend prüft DB-Version per direktem SQLite-Zugriff, nicht per API. Begründung: uvicorn liefert keine Responses während Lifespan blockiert. Alternativen (Background-Thread, separater Prozess) einführen Race Conditions bzw. Komplexität ohne Nutzen.

## D7 — 2026-04-08: Bug-Report Fallback auf GitHub Draft
Wenn Beta-API fehlschlägt (Domain falsch/dead), öffnet die App einen vorbefüllten GitHub-Issue-Draft (`tim-kal/catalog`) statt Report still zu verlieren. UI zeigt explizit, ob Backend-Submit oder Fallback genutzt wurde.

## D8 — 2026-04-08: Samsung-Kollision fixen ohne Fingerprint-Autoassign
`fs_fingerprint` darf ohne corroborating identifier nicht mehr automatisch erkennen. Ambiguous wird explizit auflösbar (AddDriveSheet), `resolve-ambiguous` bekommt 409-Sicherheitscheck gegen falsches Überschreiben, und Migration v9 löscht alte Produktnamen-Serials (`% Media`, `Untitled`, leer).

## D9 — 2026-04-11: Dashboard UI nur in Debug
NordVPN-style Dashboard (icon-only sidebar, card panels) für Drive-Page und Manage-Page (drei Tabs: Backup-Status, Duplikate, Empfohlene Aktionen per D2). Entwicklung nur im Debug-Build hinter `#if DEBUG` Flag. Release-Build behält aktuelle UI bis Dashboard stabil. Rollback jederzeit möglich.

## D10 — 2026-04-11: Safe Transfer Architektur
Pattern: stream-hash source while writing + fsync + re-read dest hash (wie ChronoSync/CCC). Atomic temp-file (.dctmp) + rename. 1MB Buffer statt 64KB. Metadata via shutil.copystat + xattr. Batch-Engine über planned_actions Tabelle mit transfer_id Gruppierung. Sequentielle I/O (kein Parallel-Copy — schlechter auf HDD). SHA-256 für Verifikation, xxHash bleibt für Dedup.
