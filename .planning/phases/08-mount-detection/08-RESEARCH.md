# Phase 8: Mount Detection - Research

**Researched:** 2026-01-24
**Domain:** macOS filesystem monitoring with Python watchdog
**Confidence:** HIGH

<research_summary>
## Summary

Researched Python watchdog library for monitoring `/Volumes` on macOS to detect drive mount/unmount events. The standard approach uses watchdog with its FSEvents backend (default on macOS), watching `/Volumes` directory for `DirCreatedEvent` (mount) and `DirDeletedEvent` (unmount) events. For daemon lifecycle, macOS uses launchd with plist files, not systemd.

Key finding: watchdog is well-maintained (v6.0.0, Nov 2024) and handles FSEvents integration transparently. The main complexity is daemon lifecycle - on macOS this should use launchd for proper service management rather than Python-based daemonization.

**Primary recommendation:** Use watchdog Observer with FSEvents backend to monitor /Volumes. For daemon mode, provide a foreground CLI command that launchd can manage via plist configuration.
</research_summary>

<standard_stack>
## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| watchdog | 6.0.0 | Filesystem event monitoring | De facto standard for Python fs events, FSEvents/kqueue on macOS |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| (none required) | - | - | Existing project deps sufficient |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| watchdog | PyObjC DiskArbitration | Lower-level, more complex, less portable |
| watchdog | Simple polling | CPU-intensive, higher latency, misses rapid mount/unmount |
| launchd | python-daemon | python-daemon is Linux-focused, launchd is macOS-native |

**Installation:**
```bash
pip install watchdog
# or
uv add watchdog
```
</standard_stack>

<architecture_patterns>
## Architecture Patterns

### Recommended Project Structure
```
src/drivecatalog/
├── watcher.py          # Mount detection logic (Observer, EventHandler)
├── cli.py              # Add 'watch' command for foreground daemon
└── (existing modules)
```

### Pattern 1: Directory Event Handler for /Volumes
**What:** Watch /Volumes for new subdirectories (mounts) and removed subdirectories (unmounts)
**When to use:** Detecting external drive connections
**Example:**
```python
# Source: watchdog official docs + macOS /Volumes behavior
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler, DirCreatedEvent, DirDeletedEvent

class VolumeEventHandler(FileSystemEventHandler):
    def __init__(self, on_mount, on_unmount):
        self.on_mount = on_mount
        self.on_unmount = on_unmount

    def on_created(self, event):
        if isinstance(event, DirCreatedEvent):
            volume_path = event.src_path
            self.on_mount(volume_path)

    def on_deleted(self, event):
        if isinstance(event, DirDeletedEvent):
            volume_path = event.src_path
            self.on_unmount(volume_path)
```

### Pattern 2: Observer Setup for /Volumes
**What:** Configure Observer for non-recursive monitoring of /Volumes
**When to use:** Always - we only care about direct children of /Volumes
**Example:**
```python
# Source: watchdog quickstart
from watchdog.observers import Observer

def start_volume_watcher(handler):
    observer = Observer()
    observer.schedule(handler, "/Volumes", recursive=False)
    observer.start()
    return observer
```

### Pattern 3: Foreground Daemon for launchd
**What:** Run as foreground process (no daemonization) - let launchd manage lifecycle
**When to use:** macOS service deployment
**Example:**
```python
# Source: launchd best practices
import signal
import sys

def run_watcher():
    observer = start_volume_watcher(handler)

    def shutdown(signum, frame):
        observer.stop()
        observer.join()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        while observer.is_alive():
            observer.join(timeout=1)
    finally:
        observer.stop()
        observer.join()
```

### Anti-Patterns to Avoid
- **Using recursive=True on /Volumes:** Unnecessary, wastes resources monitoring volume contents
- **Daemonizing in Python on macOS:** Let launchd handle process lifecycle
- **Ignoring FSEvents coalescing:** May need os.path.exists() check for ambiguous events
</architecture_patterns>

<dont_hand_roll>
## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| FSEvents integration | Custom C bindings | watchdog | Handles platform differences, well-tested |
| Daemon process management | python-daemon / double-fork | launchd plist | macOS native, handles restarts/logging |
| Polling /Volumes | Loop with os.listdir() | watchdog Observer | CPU efficient, lower latency |
| Signal handling for graceful shutdown | Complex signal logic | Simple SIGTERM handler + launchd | launchd sends SIGTERM on stop |

**Key insight:** The complexity in mount detection isn't the monitoring itself (watchdog handles it well) - it's the daemon lifecycle. On macOS, don't fight launchd; let it manage the process and just write a foreground watcher.
</dont_hand_roll>

<common_pitfalls>
## Common Pitfalls

### Pitfall 1: FSEvents Temporal Coalescing
**What goes wrong:** Both `is_created` and `is_removed` flags can be True for same event
**Why it happens:** FSEvents coalesces events within ~30 seconds
**How to avoid:** If event flags are ambiguous, check `os.path.exists(event.src_path)` to determine actual state
**Warning signs:** Mount events not triggering callbacks, or both mount and unmount callbacks firing

### Pitfall 2: FSEvents Historical Events
**What goes wrong:** Events from up to 30 seconds before watch started are delivered
**Why it happens:** FSEvents API behavior
**How to avoid:** Use snapshot on startup to establish baseline, or ignore events for first few seconds
**Warning signs:** "Ghost" mount events on watcher startup for volumes already mounted

### Pitfall 3: Thread Safety on FSEvents
**What goes wrong:** Race conditions in event handling
**Why it happens:** FSEvents interface not fully thread-safety audited in watchdog
**How to avoid:** Keep event handlers simple, queue work to main thread if complex processing needed
**Warning signs:** Intermittent crashes, missed events under load

### Pitfall 4: File Descriptor Limits (kqueue fallback)
**What goes wrong:** Observer fails to start or misses events
**Why it happens:** kqueue uses file descriptors per watched path
**How to avoid:** Use FSEvents (default on macOS), ensure ulimit >= 1024 if kqueue needed
**Warning signs:** "Too many open files" errors, observer.start() fails

### Pitfall 5: Not Handling Watcher Startup Race
**What goes wrong:** Drive mounted between app start and watcher start is missed
**Why it happens:** No event fired for already-mounted volumes
**How to avoid:** List /Volumes contents on startup, process existing mounts before starting watcher
**Warning signs:** Known registered drives not detected until re-plugged
</common_pitfalls>

<code_examples>
## Code Examples

Verified patterns from official sources:

### Basic Observer Pattern
```python
# Source: watchdog PyPI quickstart
import time
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

class MyHandler(FileSystemEventHandler):
    def on_any_event(self, event):
        print(event)

handler = MyHandler()
observer = Observer()
observer.schedule(handler, ".", recursive=True)
observer.start()
try:
    while True:
        time.sleep(1)
finally:
    observer.stop()
    observer.join()
```

### Volume-Specific Handler
```python
# Source: Derived from watchdog docs for /Volumes use case
from pathlib import Path
from watchdog.events import FileSystemEventHandler, DirCreatedEvent, DirDeletedEvent

class VolumeHandler(FileSystemEventHandler):
    def __init__(self, callback):
        self.callback = callback

    def on_created(self, event):
        if isinstance(event, DirCreatedEvent):
            path = Path(event.src_path)
            # Filter out .Trashes and other system dirs
            if not path.name.startswith('.'):
                self.callback('mount', path)

    def on_deleted(self, event):
        if isinstance(event, DirDeletedEvent):
            path = Path(event.src_path)
            if not path.name.startswith('.'):
                self.callback('unmount', path)
```

### launchd plist for Python Daemon
```xml
<!-- Source: Apple developer docs, launchd.info -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.drivecatalog.watcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/python</string>
        <string>-m</string>
        <string>drivecatalog</string>
        <string>watch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/drivecatalog.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/drivecatalog.err.log</string>
</dict>
</plist>
```
</code_examples>

<sota_updates>
## State of the Art (2025-2026)

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Polling /Volumes | watchdog FSEvents | Stable since 2015+ | Much lower CPU, faster detection |
| python-daemon for daemonizing | launchd plist | macOS native approach | Proper restart handling, logging |
| Manual FSEvents C bindings | watchdog 6.0.0 | Nov 2024 | Python 3.9+, maintained |

**New tools/patterns to consider:**
- **watchdog 6.0.0**: Latest stable, Python 3.9+ required, well-maintained
- **launchd KeepAlive**: Auto-restart on crash, preferred over manual recovery logic

**Deprecated/outdated:**
- **systemd on macOS**: Not available, use launchd
- **python-daemon library**: Linux-focused, doesn't integrate with macOS service management
- **Custom FSEvents bindings**: Unnecessary complexity, watchdog handles it
</sota_updates>

<open_questions>
## Open Questions

Things that couldn't be fully resolved:

1. **Volume name vs path handling**
   - What we know: watchdog reports /Volumes/DriveName as src_path
   - What's unclear: How to handle drives with same name (macOS appends " 2" etc.)
   - Recommendation: Use path, not name, for identification; rely on UUID from drives.py

2. **Behavior with network volumes**
   - What we know: Network mounts also appear in /Volumes
   - What's unclear: Whether to treat them differently
   - Recommendation: Filter by checking if volume is local disk (diskutil info) during mount callback
</open_questions>

<sources>
## Sources

### Primary (HIGH confidence)
- [watchdog PyPI](https://pypi.org/project/watchdog/) - v6.0.0, Python 3.9+, Nov 2024
- [watchdog GitHub](https://github.com/gorakhargosh/watchdog) - FSEvents backend details
- [watchdog quickstart](https://python-watchdog.readthedocs.io/en/stable/quickstart.html) - Official example patterns
- [Apple launchd docs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) - plist format

### Secondary (MEDIUM confidence)
- [launchd.info](https://launchd.info/) - Comprehensive tutorial, verified against Apple docs
- [AndyPi launchd guide](https://andypi.co.uk/2023/02/14/how-to-run-a-python-script-as-a-service-on-mac-os/) - Python-specific examples

### Tertiary (LOW confidence - needs validation)
- FSEvents coalescing behavior - from GitHub issues, may need testing
</sources>

<metadata>
## Metadata

**Research scope:**
- Core technology: watchdog FSEvents integration on macOS
- Ecosystem: launchd for daemon management
- Patterns: /Volumes monitoring, foreground daemon pattern
- Pitfalls: FSEvents coalescing, thread safety, startup race

**Confidence breakdown:**
- Standard stack: HIGH - watchdog is well-documented, widely used
- Architecture: HIGH - patterns from official docs and established macOS practices
- Pitfalls: MEDIUM - some from GitHub issues, needs validation during implementation
- Code examples: HIGH - from official watchdog documentation

**Research date:** 2026-01-24
**Valid until:** 2026-02-24 (30 days - watchdog ecosystem stable)
</metadata>

---

*Phase: 08-mount-detection*
*Research completed: 2026-01-24*
*Ready for planning: yes*
