# Phase 12: Architecture & Python API - Research

**Researched:** 2026-01-24
**Domain:** Swift↔Python IPC for local desktop app (SwiftUI frontend + Python CLI backend)
**Confidence:** HIGH

<research_summary>
## Summary

Researched patterns for integrating the existing DriveCatalog Python CLI with a native SwiftUI macOS application. The standard approach is **local HTTP API** using FastAPI on the Python side and URLSession with async/await on the Swift side.

Key finding: Don't try to embed Python in Swift or use PythonKit for a complex backend. The cleanest architecture is a local REST API server managed by the Swift app, communicating over localhost. This provides clear separation, testability, and leverages the existing Python codebase with minimal changes.

**Primary recommendation:** Use FastAPI for the Python HTTP API server, SwiftUI with @Observable MVVM architecture, and URLSession for networking. Launch the Python server as a subprocess managed by the macOS app lifecycle.
</research_summary>

<standard_stack>
## Standard Stack

The established libraries/tools for Swift↔Python desktop app integration:

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| FastAPI | 0.115+ | Python HTTP API framework | Async-first, auto-docs, 38% Python dev adoption in 2025, type-safe |
| uvicorn | 0.32+ | ASGI server | Standard FastAPI server, async, fast |
| Pydantic | 2.x | Data validation & serialization | Built into FastAPI, type hints → JSON schema |
| URLSession | Built-in | Swift HTTP client | Native, async/await since Swift 5.5, no dependencies |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| swift-subprocess | 0.3+ | Process management | Swift 6.2+, cleaner than Process API |
| httpx | 0.27+ | Python HTTP client | Testing API from Python side |
| pydantic-settings | 2.x | Config management | Environment variables, settings |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| FastAPI | Flask | Flask simpler but no async, no auto-docs, 5-7x slower |
| HTTP API | PythonKit | PythonKit requires embedded Python, complex linking, no iOS |
| HTTP API | Subprocess/JSON | Subprocess per-request is slow, no streaming, hard to debug |
| URLSession | Alamofire | Alamofire adds dependency, URLSession async is now excellent |

**Installation:**
```bash
# Python backend
pip install "fastapi[standard]" pydantic-settings

# Swift (Package.swift) - optional, only if using swift-subprocess
.package(url: "https://github.com/swiftlang/swift-subprocess", from: "0.3.0")
```
</standard_stack>

<architecture_patterns>
## Architecture Patterns

### Recommended Project Structure
```
DriveSnapshots/
├── src/drivecatalog/        # Existing Python CLI (unchanged)
│   ├── cli.py
│   ├── database.py
│   ├── scanner.py
│   └── ...
├── src/drivecatalog/api/    # NEW: FastAPI layer
│   ├── __init__.py
│   ├── main.py              # FastAPI app entry point
│   ├── routes/
│   │   ├── drives.py
│   │   ├── files.py
│   │   ├── duplicates.py
│   │   └── search.py
│   └── models/              # Pydantic response models
│       ├── drive.py
│       ├── file.py
│       └── scan.py
├── DriveCatalog/            # NEW: SwiftUI Xcode project
│   ├── DriveCatalog.xcodeproj
│   ├── DriveCatalogApp.swift
│   ├── Services/
│   │   └── APIService.swift
│   ├── Models/
│   │   └── Drive.swift
│   └── Views/
│       └── DriveListView.swift
└── pyproject.toml
```

### Pattern 1: FastAPI Thin API Layer
**What:** FastAPI routes call existing domain modules directly
**When to use:** Always - preserves existing working code
**Example:**
```python
# src/drivecatalog/api/routes/drives.py
from fastapi import APIRouter, HTTPException
from drivecatalog.database import get_connection
from drivecatalog.drives import get_drive_info

router = APIRouter(prefix="/drives", tags=["drives"])

@router.get("/")
async def list_drives():
    """List all registered drives."""
    with get_connection() as conn:
        cursor = conn.execute("""
            SELECT id, name, uuid, mount_path, total_bytes, last_scan
            FROM drives ORDER BY name
        """)
        return [dict(row) for row in cursor.fetchall()]

@router.post("/")
async def add_drive(path: str, name: str | None = None):
    """Register a new drive."""
    info = get_drive_info(path)
    if not info:
        raise HTTPException(400, "Invalid drive path")
    # ... insert into database
    return {"status": "added", "drive": info}
```

### Pattern 2: SwiftUI @Observable ViewModel
**What:** ViewModels as @Observable classes with async methods
**When to use:** Swift 17+ (iOS 17, macOS 14)
**Example:**
```swift
// Services/APIService.swift
import Foundation

actor APIService {
    private let baseURL = URL(string: "http://127.0.0.1:8100")!

    func fetchDrives() async throws -> [Drive] {
        let url = baseURL.appendingPathComponent("drives")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Drive].self, from: data)
    }
}

// ViewModels/DriveListViewModel.swift
@Observable
class DriveListViewModel {
    var drives: [Drive] = []
    var isLoading = false
    var error: Error?

    private let api = APIService()

    func loadDrives() async {
        isLoading = true
        defer { isLoading = false }

        do {
            drives = try await api.fetchDrives()
        } catch {
            self.error = error
        }
    }
}
```

### Pattern 3: App-Managed Server Lifecycle
**What:** Swift app launches/terminates Python server as subprocess
**When to use:** Always for local desktop app
**Example:**
```swift
// Managers/ServerManager.swift
import Foundation

@MainActor
class ServerManager: ObservableObject {
    private var serverProcess: Process?
    private let port = 8100

    func startServer() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python", "-m", "drivecatalog.api", "--port", "\(port)"]
        process.currentDirectoryURL = Bundle.main.resourceURL

        try process.run()
        serverProcess = process
    }

    func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
    }
}
```

### Anti-Patterns to Avoid
- **Embedding Python in Swift process:** Complex linking, version conflicts, threading issues
- **New subprocess per request:** Slow startup, no connection pooling, wasteful
- **Blocking UI on API calls:** Always use async/await, never sync network calls
- **Global state in FastAPI:** Use dependency injection, pass connections explicitly
</architecture_patterns>

<dont_hand_roll>
## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HTTP server | Custom socket listener | FastAPI + uvicorn | Request parsing, routing, async, error handling |
| JSON serialization | Manual dict building | Pydantic models | Validation, type safety, auto-documentation |
| Request validation | Manual checks | Pydantic/FastAPI | Type coercion, error messages, OpenAPI spec |
| Swift networking | Manual URLRequest building | async URLSession | Cleaner code, proper error handling, cancellation |
| Process management | fork/exec directly | Process/swift-subprocess | Lifecycle, pipes, signals handled correctly |
| CORS handling | Manual headers | CORSMiddleware | Preflight requests, credentials, all edge cases |
| API documentation | Manual Markdown | FastAPI auto-docs | /docs and /redoc for free, stays in sync |

**Key insight:** The HTTP API pattern has been solved many times. FastAPI handles 90% of what you need out of the box. The existing DriveCatalog domain modules (scanner.py, duplicates.py, etc.) are the valuable code - just wrap them with thin FastAPI routes.
</dont_hand_roll>

<common_pitfalls>
## Common Pitfalls

### Pitfall 1: CORS Blocking Localhost Requests
**What goes wrong:** Swift app can't reach localhost API, requests blocked
**Why it happens:** Browser/WebView CORS policies apply even on localhost with different ports
**How to avoid:** Add CORSMiddleware allowing localhost origins
```python
from fastapi.middleware.cors import CORSMiddleware

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # For local desktop app, "*" is fine
    allow_methods=["*"],
    allow_headers=["*"],
)
```
**Warning signs:** Network errors mentioning "Access-Control-Allow-Origin"

### Pitfall 2: Server Not Ready at App Launch
**What goes wrong:** Swift app makes API call before Python server is listening
**Why it happens:** Server startup takes time (Python import, uvicorn bind)
**How to avoid:** Health check endpoint + retry with exponential backoff
```swift
func waitForServer() async throws {
    for attempt in 1...10 {
        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            if (response as? HTTPURLResponse)?.statusCode == 200 { return }
        } catch { }
        try await Task.sleep(for: .milliseconds(100 * attempt))
    }
    throw ServerError.notReady
}
```
**Warning signs:** First API call fails, subsequent ones work

### Pitfall 3: Blocking UI During Long Operations
**What goes wrong:** Scanning drive freezes the entire SwiftUI app
**Why it happens:** Scan is synchronous, blocks FastAPI worker, Swift awaits
**How to avoid:** Background tasks with progress streaming
```python
from fastapi import BackgroundTasks

@router.post("/drives/{name}/scan")
async def scan_drive(name: str, background_tasks: BackgroundTasks):
    background_tasks.add_task(do_scan, name)
    return {"status": "scan_started", "poll_url": f"/drives/{name}/scan/status"}
```
**Warning signs:** UI unresponsive during scan/hash operations

### Pitfall 4: Server Process Orphaned on Crash
**What goes wrong:** Python server keeps running after Swift app crashes
**Why it happens:** Crash bypasses normal termination cleanup
**How to avoid:** PID file + cleanup on launch, or use launchd KeepAlive
```swift
// On app launch, check for stale server
if let existingPID = readPIDFile() {
    kill(existingPID, SIGTERM)
}
```
**Warning signs:** "Address already in use" on restart

### Pitfall 5: Swift 6 Sendable Requirements
**What goes wrong:** Compiler errors about non-Sendable types crossing actor boundaries
**Why it happens:** Swift 6 enforces data race safety via Sendable
**How to avoid:** Make API response models Codable + Sendable (usually free)
```swift
struct Drive: Codable, Sendable {
    let id: Int
    let name: String
    // ... Codable structs are automatically Sendable if all fields are
}
```
**Warning signs:** "cannot transfer value of non-Sendable type"
</common_pitfalls>

<code_examples>
## Code Examples

Verified patterns from official sources:

### FastAPI App Entry Point
```python
# src/drivecatalog/api/main.py
# Source: FastAPI official docs

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager

from .routes import drives, files, duplicates, search

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: initialize database
    from drivecatalog.database import init_db
    init_db()
    yield
    # Shutdown: cleanup if needed

app = FastAPI(
    title="DriveCatalog API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(drives.router)
app.include_router(files.router)
app.include_router(duplicates.router)
app.include_router(search.router)

@app.get("/health")
async def health():
    return {"status": "ok"}
```

### Swift URLSession with async/await
```swift
// Source: Apple WWDC21 "Use async/await with URLSession"

import Foundation

struct APIClient {
    private let baseURL: URL
    private let decoder = JSONDecoder()

    init(baseURL: URL = URL(string: "http://127.0.0.1:8100")!) {
        self.baseURL = baseURL
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw APIError.invalidResponse
        }

        return try decoder.decode(T.self, from: data)
    }

    func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try decoder.decode(T.self, from: data)
    }
}
```

### Pydantic Response Models
```python
# src/drivecatalog/api/models/drive.py
# Source: Pydantic v2 docs

from pydantic import BaseModel
from datetime import datetime

class DriveResponse(BaseModel):
    id: int
    name: str
    uuid: str | None
    mount_path: str
    total_bytes: int
    last_scan: datetime | None
    file_count: int = 0

    class Config:
        from_attributes = True  # Allow ORM-style creation from Row

class DriveListResponse(BaseModel):
    drives: list[DriveResponse]
    total: int
```

### Running Server with Uvicorn
```python
# src/drivecatalog/api/__main__.py
# Source: Uvicorn docs

import uvicorn
import argparse

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8100)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    uvicorn.run(
        "drivecatalog.api.main:app",
        host=args.host,
        port=args.port,
        reload=False,  # No reload in production
        log_level="info",
    )

if __name__ == "__main__":
    main()
```
</code_examples>

<sota_updates>
## State of the Art (2025-2026)

What's changed recently:

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| ObservableObject + @Published | @Observable macro | Swift 5.9 (2023) | Simpler ViewModels, less boilerplate |
| Process API | swift-subprocess | Swift 6.2 (2025) | Async-first subprocess, better pipes |
| Flask sync | FastAPI async | 2020+ | 38% adoption, de facto standard for new Python APIs |
| Combine for networking | async/await URLSession | Swift 5.5 (2021) | Simpler, no third-party needed |
| Manual OpenAPI | FastAPI auto-docs | 2020+ | /docs endpoint for free |

**New tools/patterns to consider:**
- **Swift 6 strict concurrency:** Plan for Sendable requirements, @MainActor for UI
- **FastAPI lifespan context:** Replaces deprecated @app.on_event for startup/shutdown
- **Structured concurrency:** Use TaskGroup for parallel API calls in Swift

**Deprecated/outdated:**
- **Flask for new APIs:** Flask works but FastAPI is now standard for typed APIs
- **Alamofire:** URLSession async/await is now just as clean
- **@Published + ObservableObject:** Use @Observable for iOS 17+/macOS 14+
</sota_updates>

<open_questions>
## Open Questions

Things that couldn't be fully resolved:

1. **Embedded vs External Python Runtime**
   - What we know: External (subprocess) is cleaner, works with system Python
   - What's unclear: Whether to bundle Python in .app for distribution
   - Recommendation: Start with system Python, consider PyInstaller bundling for App Store distribution later

2. **Port Selection Strategy**
   - What we know: Need a port for localhost HTTP (e.g., 8100)
   - What's unclear: Best approach for avoiding port conflicts
   - Recommendation: Try preferred port, fallback to random available port, communicate via file

3. **Long-Running Operations Pattern**
   - What we know: Scanning can take minutes, need progress updates
   - What's unclear: WebSocket vs Server-Sent Events vs polling for progress
   - Recommendation: Start with polling (simple), add SSE if needed for better UX
</open_questions>

<sources>
## Sources

### Primary (HIGH confidence)
- [FastAPI Official Documentation](https://fastapi.tiangolo.com/) - Features, setup, middleware
- [Apple WWDC21 - Use async/await with URLSession](https://developer.apple.com/videos/play/wwdc2021/10095/) - Swift networking
- [swift-subprocess GitHub](https://github.com/swiftlang/swift-subprocess) - Swift 6.2 process API

### Secondary (MEDIUM confidence)
- [SwiftLee - URLSession with Async/Await](https://www.avanderlee.com/concurrency/urlsession-async-await-network-requests-in-swift/) - Modern patterns
- [Strapi - FastAPI vs Flask 2025](https://strapi.io/blog/fastapi-vs-flask-python-framework-comparison) - Framework comparison
- [Apple Developer Forums - Python Backend with macOS Swift](https://developer.apple.com/forums/thread/766464) - Architecture advice

### Tertiary (LOW confidence - needs validation)
- [Medium - Modern MVVM in SwiftUI 2025](https://medium.com/@minalkewat/modern-mvvm-in-swiftui-2025-the-clean-architecture-youve-been-waiting-for-72a7d576648e) - Architecture patterns
</sources>

<metadata>
## Metadata

**Research scope:**
- Core technology: Swift↔Python IPC via local HTTP API
- Ecosystem: FastAPI, uvicorn, Pydantic, URLSession, swift-subprocess
- Patterns: MVVM, service layer, subprocess lifecycle
- Pitfalls: CORS, server readiness, blocking operations, orphaned processes

**Confidence breakdown:**
- Standard stack: HIGH - FastAPI and URLSession are widely documented, production-proven
- Architecture: HIGH - Local HTTP API is the established pattern for this use case
- Pitfalls: HIGH - Well-documented issues in community resources
- Code examples: HIGH - From official documentation

**Research date:** 2026-01-24
**Valid until:** 2026-02-24 (30 days - stable technologies)
</metadata>

---

*Phase: 12-architecture-python-api*
*Research completed: 2026-01-24*
*Ready for planning: yes*
