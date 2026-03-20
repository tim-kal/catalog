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

    /// Path to the DriveSnapshots project root (where pyproject.toml lives).
    private var projectPath: String {
        // The Xcode project is inside DriveSnapshots, so go up from the app bundle
        // For development: use the known project path
        // In production, this would be bundled differently
        let knownPath = "\(NSHomeDirectory())/code/DriveSnapshots"
        if FileManager.default.fileExists(atPath: "\(knownPath)/pyproject.toml") {
            return knownPath
        }
        // Fallback: derive from the app bundle location
        if let bundlePath = Bundle.main.bundlePath.components(separatedBy: "/DriveCatalog.app").first,
           FileManager.default.fileExists(atPath: "\(bundlePath)/pyproject.toml") {
            return bundlePath
        }
        return knownPath
    }

    /// Possible locations for the uv binary.
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

        guard let uv = uvPath else {
            startupError = "Cannot find uv. Install it: curl -LsSf https://astral.sh/uv/install.sh | sh"
            logger.error("uv binary not found")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uv)
        proc.arguments = ["run", "python", "-m", "drivecatalog.api"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        // Suppress Xcode VIRTUAL_ENV warning
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "VIRTUAL_ENV")
        proc.environment = env

        // Pipe stdout/stderr to /dev/null (or a log file if debugging)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.isRunning = false
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
        for attempt in 1...30 {
            try? await Task.sleep(for: .milliseconds(attempt < 5 ? 200 : 500))
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    isRunning = true
                    logger.info("API server healthy after \(attempt) attempts")
                    return
                }
            } catch {
                // Not ready yet
            }
        }
        startupError = "API server started but failed health check after 15 seconds"
        logger.error("API server failed health check")
    }
}
