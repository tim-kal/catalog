# Roadmap: DriveCatalog

## Overview

Build a macOS CLI tool for cataloging external drives, detecting duplicates via partial hashing, and performing verified media transfers. Start with database foundation and core scanning, progress through duplicate detection and search, then add mount automation and media-specific features.

## Domain Expertise

None

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [x] **Phase 1: Foundation** - Database schema, CLI skeleton, Rich setup
- [x] **Phase 2: Drive Management** - Drive registration, list/add commands
- [x] **Phase 3: File Scanner** - Directory traversal, metadata collection, change detection
- [x] **Phase 4: Partial Hashing** - xxHash algorithm for duplicate candidates
- [x] **Phase 5: Duplicate Detection** - Clustering queries, space analysis
- [x] **Phase 6: Search** - Pattern matching, filtering, search command
- [x] **Phase 7: Verified Copy** - Streaming copy with SHA256 verification
- [x] **Phase 8: Mount Detection** - watchdog daemon for /Volumes monitoring
- [x] **Phase 9: Config & Auto-scan** - YAML config, auto-scan on mount
- [x] **Phase 10: Media Metadata** - ffprobe integration, codec/duration extraction
- [ ] **Phase 11: Integrity Verification** - Container integrity check via ffprobe

## Phase Details

### Phase 1: Foundation
**Goal**: Working database with schema, CLI entry point, Rich console setup
**Depends on**: Nothing (first phase)
**Research**: Unlikely (standard Python project setup, SQLite)
**Plans**: TBD

### Phase 2: Drive Management
**Goal**: Register drives, list known drives, basic drive commands
**Depends on**: Phase 1
**Research**: Unlikely (standard CLI patterns with Click)
**Plans**: TBD

### Phase 3: File Scanner
**Goal**: Scan drive directories, collect file metadata, detect changes since last scan
**Depends on**: Phase 2
**Research**: Unlikely (os.walk, pathlib, standard patterns)
**Plans**: TBD

### Phase 4: Partial Hashing
**Goal**: Compute xxHash of header+tail+size for fast duplicate detection
**Depends on**: Phase 3
**Research**: Unlikely (xxhash library is straightforward)
**Plans**: TBD

### Phase 5: Duplicate Detection
**Goal**: Cluster files by partial hash, identify duplicates across drives, calculate reclaimable space
**Depends on**: Phase 4
**Research**: Unlikely (SQL queries, grouping by hash)
**Plans**: TBD

### Phase 6: Search
**Goal**: Search files by name/pattern, filter by drive/date/size
**Depends on**: Phase 3
**Research**: Unlikely (SQL LIKE, fnmatch patterns)
**Plans**: TBD

### Phase 7: Verified Copy
**Goal**: Copy files with streaming SHA256, verify integrity, log copy operations
**Depends on**: Phase 1
**Research**: Unlikely (hashlib streaming, file operations)
**Plans**: TBD

### Phase 8: Mount Detection
**Goal**: Daemon monitoring /Volumes for drive mount/unmount events
**Depends on**: Phase 2
**Research**: Likely (watchdog FSEvents integration on macOS)
**Research topics**: watchdog library FSEvents backend, /Volumes monitoring patterns, daemon lifecycle
**Plans**: TBD

### Phase 9: Config & Auto-scan
**Goal**: YAML config file support, automatic scan when drive mounts
**Depends on**: Phase 3, Phase 8
**Research**: Unlikely (standard YAML config patterns)
**Plans**: TBD

### Phase 10: Media Metadata
**Goal**: Extract video metadata via ffprobe (duration, codec, resolution, framerate)
**Depends on**: Phase 3
**Research**: Likely (ffprobe JSON output parsing, ffmpeg-python library)
**Research topics**: ffprobe command options, JSON output format, handling codec variations
**Plans**: TBD

### Phase 11: Integrity Verification
**Goal**: Verify video container integrity via ffprobe, report corruption
**Depends on**: Phase 10
**Research**: Likely (ffprobe error stream parsing, container validation)
**Research topics**: ffprobe error detection, container integrity checks, corruption patterns
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 4/4 | Complete | 2026-01-23 |
| 2. Drive Management | 1/1 | Complete | 2026-01-23 |
| 3. File Scanner | 1/1 | Complete | 2026-01-24 |
| 4. Partial Hashing | 1/1 | Complete | 2026-01-24 |
| 5. Duplicate Detection | 1/1 | Complete | 2026-01-24 |
| 6. Search | 1/1 | Complete | 2026-01-24 |
| 7. Verified Copy | 1/1 | Complete | 2026-01-24 |
| 8. Mount Detection | 1/1 | Complete | 2026-01-24 |
| 9. Config & Auto-scan | 1/1 | Complete | 2026-01-24 |
| 10. Media Metadata | 1/1 | Complete | 2026-01-24 |
| 11. Integrity Verification | 0/? | Not started | - |
