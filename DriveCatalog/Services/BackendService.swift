import AppKit
import Foundation
import SQLite3
import os

/// Manages the Python API server lifecycle.
/// Starts the server on init, stops it on deinit or app termination.
@MainActor
final class BackendService: ObservableObject {
    static let shared = BackendService()

    @Published var isRunning = false
    @Published var startupError: String?
    @Published var isMigrating = false
    @Published var migrationCurrent = 0
    @Published var migrationTotal = 0
    @Published var migrationDescription = ""
    @Published var migrationFailed = false
    @Published var migrationError = ""

    /// Must match SCHEMA_VERSION (= len(MIGRATIONS)) in migrations.py.
    /// Update this whenever a new migration is added.
    private let expectedSchemaVersion = 11

    private var process: Process?
    /// PID stored separately so forceStop can kill it from any isolation context.
    private nonisolated(unsafe) var backendPID: Int32 = 0
    private let logger = Logger(subsystem: "com.drivecatalog", category: "BackendService")
    private var terminationObserver: Any?

    private init() {
        // Stop the API server when the app quits
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceStop()
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        forceStop()
    }

    /// Path to embedded Python inside the app bundle (Contents/Resources/python/bin/python3).
    private var embeddedPythonPath: String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let path = resourceURL.appendingPathComponent("python/bin/python3").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Root of the embedded Python installation (Contents/Resources/python).
    private var embeddedPythonHome: String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let path = resourceURL.appendingPathComponent("python").path
        return FileManager.default.isReadableFile(atPath: path) ? path : nil
    }

    /// Path to the DriveSnapshots project root (where pyproject.toml lives).
    /// Used only for development (uv-based launch).
    private var projectPath: String {
        let knownPath = "\(NSHomeDirectory())/code/DriveSnapshots"
        if FileManager.default.fileExists(atPath: "\(knownPath)/pyproject.toml") {
            return knownPath
        }
        if let bundlePath = Bundle.main.bundlePath.components(separatedBy: "/DriveCatalog.app").first,
           FileManager.default.fileExists(atPath: "\(bundlePath)/pyproject.toml") {
            return bundlePath
        }
        return knownPath
    }

    /// Possible locations for the uv binary (development fallback).
    private var uvPath: String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/uv",
            "/usr/local/bin/uv",
            "/opt/homebrew/bin/uv",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Path to ~/.drivecatalog/migration_status.json.
    private var migrationStatusFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".drivecatalog/migration_status.json")
    }

    /// Path to ~/.drivecatalog/catalog.db.
    private var catalogDBURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".drivecatalog/catalog.db")
    }

    /// Open catalog.db directly via SQLite and check if migration is needed.
    /// Returns true if schema version < expectedSchemaVersion.
    private func checkMigrationNeeded() -> Bool {
        let path = catalogDBURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            return false  // New install — migration will be fast
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return true  // Can't read → assume migration needed
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT COALESCE(MAX(version), 0) FROM schema_version"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return true  // Table may not exist yet → migration needed
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
        let version = Int(sqlite3_column_int(stmt, 0))
        return version < expectedSchemaVersion
    }

    func start() {
        guard process == nil else { return }
        startupError = nil
        migrationFailed = false
        migrationError = ""

        // Detect migration need BEFORE launching server (direct SQLite read)
        if checkMigrationNeeded() {
            isMigrating = true
        }

        // Check if a server is already running on the port (e.g. from a previous app session)
        Task {
            if await checkExistingServer() {
                logger.info("API server already running on port — reusing")
                isMigrating = false
                isRunning = true
                return
            }
            launchServer()
        }
    }

    /// Check if a server is already healthy on the expected port (with short timeout).
    private func checkExistingServer() async -> Bool {
        let url = URL(string: "\(APIService.baseURL)/health")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1  // 1 second max — don't block startup
        config.timeoutIntervalForResource = 1
        let session = URLSession(configuration: config)
        do {
            let (_, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
        } catch {
            // No server running
        }
        return false
    }

    /// Log file for backend output — helps diagnose startup failures.
    private var backendLogURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("DriveCatalog")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backend.log")
    }

    private func launchServer() {
        let proc = Process()

        // Extract port from APIService.baseURL so debug/release use different ports
        let serverPort = URLComponents(string: APIService.baseURL)?.port ?? 8100

        if let pythonBin = embeddedPythonPath, let pythonHome = embeddedPythonHome {
            logger.info("Using embedded Python: \(pythonBin)")
            proc.executableURL = URL(fileURLWithPath: pythonBin)
            proc.arguments = ["-m", "drivecatalog.api", "--port", "\(serverPort)"]

            var env = ProcessInfo.processInfo.environment
            env["PYTHONHOME"] = pythonHome
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["PYTHONNOUSERSITE"] = "1"
            env.removeValue(forKey: "VIRTUAL_ENV")
            proc.environment = env
        } else if let uv = uvPath {
            logger.info("Using uv (development mode): \(uv)")
            proc.executableURL = URL(fileURLWithPath: uv)
            proc.arguments = ["run", "python", "-m", "drivecatalog.api", "--port", "\(serverPort)"]
            proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)

            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "VIRTUAL_ENV")
            proc.environment = env
        } else {
            startupError = "No Python backend found. Embedded Python missing and uv not installed."
            logger.error("No Python backend available")
            return
        }

        // Log backend output to file for diagnostics
        let logFile = backendLogURL
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logFile.path)
        proc.standardOutput = logHandle ?? FileHandle.nullDevice
        proc.standardError = logHandle ?? FileHandle.nullDevice

        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                // Only clear isRunning if we set it from this process (not from an external server)
                if self?.process === proc {
                    self?.isRunning = false
                    self?.process = nil
                }
                if proc.terminationStatus != 0 && proc.terminationStatus != 15 {
                    self?.logger.warning("API server exited with code \(proc.terminationStatus)")
                }
            }
        }

        do {
            try proc.run()
            process = proc
            backendPID = proc.processIdentifier
            logger.info("API server started (PID \(proc.processIdentifier))")

            // Poll until the server is ready
            Task {
                await waitForHealthy()
            }
        } catch {
            startupError = "Failed to start API server: \(error.localizedDescription)"
            logger.error("Failed to launch API server: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            isRunning = false
            return
        }
        logger.info("Stopping API server (PID \(proc.processIdentifier))")
        proc.interrupt()  // SIGINT for graceful shutdown
        proc.waitUntilExit()
        process = nil
        backendPID = 0
        isRunning = false
    }

    /// Force-kill the backend process and its children (used during app termination).
    private nonisolated func forceStop() {
        let pid = backendPID
        guard pid > 0 else { return }
        // Kill the process group (catches child python process spawned by uv)
        kill(-pid, SIGKILL)
        // Also kill the specific PID in case process group didn't work
        kill(pid, SIGKILL)
        backendPID = 0
    }

    /// Read migration_status.json directly via FileManager and update published properties.
    /// Returns true if migration failed (caller should stop waiting for /health).
    private func pollMigrationStatus() -> Bool {
        let path = migrationStatusFileURL.path
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // File deleted → migration complete (or never started)
            if isMigrating {
                isMigrating = false
            }
            return false
        }

        // Check for failure
        if json["failed"] as? Bool == true {
            let errorMsg = json["error"] as? String ?? "Unknown error"
            let restoredFrom = json["restored_from"] as? String ?? ""
            isMigrating = false
            migrationFailed = true
            migrationError = "DC-E006: \(errorMsg)"
            startupError = "DC-E006 Migration Failed: \(errorMsg)\n\nRestored from: \(restoredFrom)"
            return true
        }

        let migrating = json["migrating"] as? Bool ?? false
        isMigrating = migrating
        if migrating {
            migrationCurrent = json["current"] as? Int ?? 0
            migrationTotal = json["total"] as? Int ?? 0
            migrationDescription = json["description"] as? String ?? ""
        }
        return false
    }

    /// Wait for the API to respond to /health, with retries.
    /// While waiting, reads migration_status.json to show progress.
    private func waitForHealthy() async {
        let healthURL = URL(string: "\(APIService.baseURL)/health")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        let session = URLSession(configuration: config)
        for attempt in 1...30 {
            // Poll migration status via file while waiting
            if pollMigrationStatus() {
                // Migration failed — don't keep waiting for /health
                return
            }

            // Check health
            do {
                let (_, response) = try await session.data(from: healthURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    isMigrating = false
                    isRunning = true
                    logger.info("API server healthy after \(attempt) attempts")
                    return
                }
            } catch {
                // Not ready yet
            }
            try? await Task.sleep(for: .milliseconds(isMigrating ? 500 : (attempt < 3 ? 100 : 300)))
        }
        // Check if process is still alive — maybe it just needs more time
        if let proc = process, proc.isRunning {
            logger.warning("Health check failed but process still running — retrying...")
            for _ in 1...10 {
                try? await Task.sleep(for: .seconds(1))
                if pollMigrationStatus() { return }
                do {
                    let (_, response) = try await session.data(from: healthURL)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        isMigrating = false
                        isRunning = true
                        logger.info("API server healthy on extended retry")
                        return
                    }
                } catch { }
            }
        }

        isMigrating = false
        // Read last lines from log for diagnostics
        let logPath = backendLogURL
        let logTail = (try? String(contentsOf: logPath, encoding: .utf8))
            .flatMap { log in
                let lines = log.components(separatedBy: .newlines).suffix(10)
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            } ?? "No log output"

        // Detect structured error codes in log tail
        let errorCodePattern = try? NSRegularExpression(pattern: "DC-E\\d{3,4}")
        let detectedCodes: [String] = {
            guard let pattern = errorCodePattern else { return [] }
            let matches = pattern.matches(in: logTail, range: NSRange(logTail.startIndex..., in: logTail))
            return Array(Set(matches.compactMap { match in
                Range(match.range, in: logTail).map { String(logTail[$0]) }
            }))
        }()
        let codePrefix = detectedCodes.isEmpty ? "" : "[\(detectedCodes.joined(separator: ", "))] "

        startupError = "\(codePrefix)Backend failed to start.\n\nLog: \(logPath.path)\n\n\(logTail)"
        logger.error("API server failed health check. Log: \(logPath.path)")
    }
}
