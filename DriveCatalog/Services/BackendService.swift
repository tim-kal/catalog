import AppKit
import Foundation
import os

/// Manages the Python API server lifecycle.
/// Starts the server on init, stops it on deinit or app termination.
@MainActor
final class BackendService: ObservableObject {
    static let shared = BackendService()

    @Published var isRunning = false
    @Published var startupError: String?

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

    func start() {
        guard process == nil else { return }
        startupError = nil

        // Check if a server is already running on the port (e.g. from a previous app session)
        Task {
            if await checkExistingServer() {
                logger.info("API server already running on port — reusing")
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

        if let pythonBin = embeddedPythonPath, let pythonHome = embeddedPythonHome {
            logger.info("Using embedded Python: \(pythonBin)")
            proc.executableURL = URL(fileURLWithPath: pythonBin)
            proc.arguments = ["-m", "drivecatalog.api"]

            var env = ProcessInfo.processInfo.environment
            env["PYTHONHOME"] = pythonHome
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env.removeValue(forKey: "VIRTUAL_ENV")
            proc.environment = env
        } else if let uv = uvPath {
            logger.info("Using uv (development mode): \(uv)")
            proc.executableURL = URL(fileURLWithPath: uv)
            proc.arguments = ["run", "python", "-m", "drivecatalog.api"]
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

    /// Wait for the API to respond to /health, with retries.
    private func waitForHealthy() async {
        let url = URL(string: "\(APIService.baseURL)/health")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        let session = URLSession(configuration: config)
        for attempt in 1...30 {
            // Check first, then sleep — shaves off the initial delay
            do {
                let (_, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    isRunning = true
                    logger.info("API server healthy after \(attempt) attempts")
                    return
                }
            } catch {
                // Not ready yet
            }
            try? await Task.sleep(for: .milliseconds(attempt < 3 ? 100 : 300))
        }
        // Check if process is still alive — maybe it just needs more time
        if let proc = process, proc.isRunning {
            logger.warning("Health check failed but process still running — retrying...")
            // One more round of checks with longer intervals
            for _ in 1...10 {
                try? await Task.sleep(for: .seconds(1))
                do {
                    let (_, response) = try await session.data(from: url)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        isRunning = true
                        logger.info("API server healthy on extended retry")
                        return
                    }
                } catch { }
            }
        }

        // Read last lines from log for diagnostics
        let logPath = backendLogURL
        let logTail = (try? String(contentsOf: logPath, encoding: .utf8))
            .flatMap { log in
                let lines = log.components(separatedBy: .newlines).suffix(5)
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            } ?? "No log output"
        startupError = "Backend failed to start.\n\nLog: \(logPath.path)\n\n\(logTail)"
        logger.error("API server failed health check. Log: \(logPath.path)")
    }
}
