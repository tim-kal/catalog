# Decisions

## D1 — 2026-04-06: Ordner-Duplikate müssen exakt sein
Keine fuzzy Thresholds (>80% etc.). Ordner-Duplikat = 100% Hash-Match aller Dateien in beiden Richtungen. Subset = alle Hashes von A existieren in B. Begründung: Precision-Tool, Datenverlust vermeiden.

## D2 — 2026-04-06: Insights + Backups → Manage Page zusammenlegen
Eine "Manage"-Seite ersetzt beide. Drei Sections: Backup-Status (pro Drive UND pro Ordner), Duplikate & Platzgewinn, Empfohlene Aktionen. Insights als separater Sidebar-Item fällt weg.

## D3 — 2026-04-06: Katalog-Dateien scannen aber schützen
Bundles (.cocatalog, .photoslibrary, .RDC etc.) werden normal gescannt, aber Dateien darin als "catalog-protected" markiert. UI warnt vor Löschen. Nicht: Bundles überspringen.

## D4 — 2026-04-06: Task-Aufteilung für Executor
7 Tasks erstellt (DC-001 bis DC-007). Abhängigkeiten: DC-001 → DC-003, DC-004. DC-002 unabhängig. DC-005, DC-006, DC-007 unabhängig.
