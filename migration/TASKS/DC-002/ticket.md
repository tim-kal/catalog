# DC-002 — Katalog-Dateien: Bundle-Erkennung und Schutz

## Goal
Detect known macOS application bundles (Capture One catalogs, Apple Photos libraries, RED camera folders) during scanning and mark files inside them as "catalog-protected" so users are warned before deleting duplicates that live inside a catalog.

## Acceptance Criteria
- [ ] New constant `CATALOG_BUNDLE_EXTENSIONS` in `scanner.py` or a new `bundles.py` module with at least: `.cocatalog`, `.photoslibrary`, `.fcpbundle`, `.RDC`, `.lrcat` (Lightroom), `.dvr` (DaVinci Resolve project bundles)
- [ ] During scan: when traversing into a directory whose name matches a known bundle extension, set a new column `catalog_bundle` (TEXT, nullable) on each file row with the bundle root path (e.g. `/Volumes/X/Photos.photoslibrary`)
- [ ] DB migration adds `catalog_bundle` column to `files` table
- [ ] API: `GET /duplicates` response includes `catalog_bundle` field on each file in a duplicate cluster (null if not in a bundle)
- [ ] API: `GET /folder-duplicates` (from DC-001) also includes catalog_bundle info
- [ ] Existing scan functionality is not broken — files inside bundles are still scanned and hashed normally, they just get the extra metadata
- [ ] Add test: scanning a directory structure with a `.photoslibrary` folder correctly tags contained files

## Relevant Files
- `src/drivecatalog/scanner.py` — `scan_drive()` function, `_should_skip_dir()`
- `src/drivecatalog/migrations.py` — add DB migration for new column
- `src/drivecatalog/api/routes/duplicates.py` — include catalog_bundle in response
- `src/drivecatalog/api/models/file.py` — update Pydantic model
- `src/drivecatalog/database.py` — schema reference

## Context
Photographers using Capture One or Apple Photos have catalogs (.cocatalog, .photoslibrary) that are macOS bundles — directories that look like files in Finder. These bundles contain the actual original RAW/image files, especially with tethered shooting. Our scanner traverses into these bundles and finds the files, which then show up as duplicates of the same files elsewhere (e.g. on the SD card).

This is technically correct — they ARE duplicates. But deleting the copy inside the catalog would corrupt the catalog. The user must be warned clearly. We do NOT skip scanning these bundles (the data is valuable for size reporting), we just tag the files so the UI can show appropriate warnings.

Capture One: originals in `CaptureOne/Originals/` inside the bundle
Photos.app: originals in `originals/` inside the bundle
RED: `.RDC` folders contain `.R3D` clip files
