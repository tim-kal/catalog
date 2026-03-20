# DriveCatalog

## What This Is

A macOS-native app (CLI + SwiftUI) for cataloging external drives, detecting duplicate files using partial hashing, and performing verified media transfers. Designed for video professionals managing multiple backup drives with overlapping content who need visibility into what's stored where and the ability to consolidate drives.

## Core Value

Duplicate detection — knowing which files exist across multiple drives and identifying safe deletion candidates. If everything else fails, this must work.

## Requirements

### Validated

- [x] SQLite database with drives/files schema and persistent catalog at `~/.drivecatalog/catalog.db` — v1.0
- [x] File scanner with change detection (size + mtime comparison) — v1.0
- [x] Partial hash algorithm (xxHash of header + tail + size) for fast duplicate detection — v1.0
- [x] Duplicate clustering queries and space analysis — v1.0
- [x] CLI interface with Click: `drives list`, `drives scan`, `search`, `duplicates`, `analyze` — v1.0
- [x] Verified copy with streaming SHA256 during transfer — v1.0
- [x] Progress display with Rich (progress bars, tables) — v1.0
- [x] Mount detection daemon monitoring `/Volumes` via watchdog — v1.0
- [x] Auto-scan on mount (configurable) — v1.0
- [x] Media metadata extraction via ffprobe (duration, codec, resolution, framerate) — v1.0
- [x] Container integrity verification via ffprobe — v1.0
- [x] FastAPI server with Pydantic models, background operations, progress polling — v1.1
- [x] SwiftUI macOS app with sidebar navigation, drive management, file browser — v1.1
- [x] Finder-style column browser with backup coverage, hover popovers — v1.1
- [x] Duplicate dashboard with reclaim analysis — v1.1
- [x] Verified copy wizard with progress tracking — v1.1
- [x] Incremental smart scan with folder_stats caching — v1.1
- [x] Drive recognition via UUID, disk usage persistence — v1.1
- [x] Integrity verification endpoint — v1.1

### Active

- [ ] Consolidation analysis: identify which drives can be freed by moving unique files elsewhere
- [ ] Migration planner: generate optimal copy plans to consolidate drives
- [ ] Verified migration executor: copy with hash verification, delete only after verified
- [ ] Progress tracking for long-running migration operations
- [ ] Migration wizard UI in SwiftUI

### Out of Scope

- Cross-platform support — macOS only, no Windows/Linux abstractions needed
- Cloud sync — local drives only, no remote storage integration
- Automated scheduling of migrations — user-initiated only for v2.0
- Network drive support — local USB/Thunderbolt drives only

## Context

Full technical specification exists in SilverBullet: `Projects/DriveCatalog/Specification`

The specification includes:
- Complete SQLite schema with drives, files, media_metadata, copy_operations tables
- Partial hash algorithm implementation (xxHash, 64KB chunks)
- Verified copy with streaming hash implementation
- macOS mount detection via watchdog
- Full CLI interface design with all commands
- Media metadata extraction via ffmpeg-python
- Video file extension list for professional formats (.mxf, .r3d, .braw, .ari, etc.)
- Testing strategy outline
- Configuration file format (YAML at `~/.drivecatalog/config.yaml`)

User context: Video professional with N external drives containing unknown/forgotten contents, redundant copies, and no efficient way to search or verify transfers.

## Constraints

- **Language**: Python 3.11+ — specified in project requirements
- **Platform**: macOS only — uses diskutil, FSEvents, /Volumes conventions
- **Database**: SQLite single file — no server dependencies, portable catalog
- **CLI Framework**: Click — standard Python CLI library
- **External dependency**: ffprobe must be installed (`brew install ffmpeg`) for media metadata

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Partial hash over full hash | Reading 128KB vs multi-GB files; collisions astronomically rare for practical use | ✓ Good — fast and reliable |
| xxHash over SHA256 for dedup | Speed for duplicate detection; SHA256 reserved for verified copy integrity | ✓ Good — clear separation of concerns |
| SQLite over filesystem JSON | Query flexibility, ACID guarantees, proven at scale | ✓ Good — simple and powerful |
| Python over Swift | Faster iteration, rich CLI ecosystem (Click, Rich), ffmpeg-python bindings | ✓ Good — 2 days to MVP |
| ffprobe subprocess over ffmpeg-python | Simpler, no additional dependency, reliable JSON parsing | ✓ Good — v1.0 |
| watchdog with FSEvents | Native macOS file system events, no polling overhead | ✓ Good — v1.0 |
| Foreground daemon design | Let launchd manage lifecycle, simpler implementation | ✓ Good — v1.0 |
| pyyaml over ruamel.yaml | Simpler, sufficient for config needs | ✓ Good — v1.0 |
| FastAPI for Python API | Standard, async, Pydantic validation, background tasks | ✓ Good — v1.1 |
| SwiftUI native for UI | macOS polish, user preference | ✓ Good — v1.1 |
| Actor-based APIService | Thread-safe networking from concurrent SwiftUI views | ✓ Good — v1.1 |
| used_bytes persistence | Store disk usage in DB so disconnected drives show storage info | ✓ Good — v1.1 |

## Current Milestone: v2.0 Drive Consolidation Optimizer

**Goal:** Analyze all drives to find which files can be moved to free entire drives, generate migration plans, execute with hash-verified transfers, and track progress through a SwiftUI migration wizard.

**Target features:**
- Consolidation analysis engine: cross-drive file distribution, identify freeable drives
- Migration planner: optimal copy plans minimizing total bytes transferred
- Verified migration executor: copy + hash verify + delete source
- Progress tracking for potentially long operations
- Migration wizard UI in SwiftUI

## Context

Shipped v1.0 MVP (2,359 LOC Python) + v1.1 UI (7,800 lines added).
Tech stack: Python 3.11+, FastAPI, Click, Rich, SQLite, xxhash, watchdog, pyyaml.
Frontend: SwiftUI macOS 14.0+, Actor-based APIService.
External dependencies: ffprobe (via brew install ffmpeg).

---
*Last updated: 2026-03-21 after v2.0 milestone start*
