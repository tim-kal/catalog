# DriveCatalog

## What This Is

A macOS-native CLI tool for cataloging external drives, detecting duplicate files using partial hashing, and performing verified media transfers. Designed for video professionals managing multiple backup drives with overlapping content who need visibility into what's stored where.

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

### Active

(None currently — v1.0 shipped, gathering feedback)

### Out of Scope

- GUI (SwiftUI) — CLI-first approach, GUI is future phase after core is validated
- Cross-platform support — macOS only, no Windows/Linux abstractions needed
- Cloud sync — local drives only, no remote storage integration

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

## Context

Shipped v1.0 MVP with 2,359 LOC Python.
Tech stack: Python 3.11+, Click, Rich, SQLite, xxhash, watchdog, pyyaml.
External dependencies: ffprobe (via brew install ffmpeg).

CLI commands: `drives add`, `drives list`, `drives scan`, `drives hash`, `drives duplicates`, `drives search`, `drives copy`, `drives watch`, `drives media`, `drives verify`, `drives status`.

---
*Last updated: 2026-01-24 after v1.0 milestone*
