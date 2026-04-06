import AppKit
import Foundation
import os

/// Checks for app updates via a JSON manifest on GitHub and handles self-replacement.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    /// URL to the update manifest JSON. Change this to your actual repo.
    static let manifestURL = "https://raw.githubusercontent.com/tim-kal/catalog/master/updates/latest.json"

    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var releaseNotes: String?
    @Published var downloadURL: URL?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var updateError: String?

    /// Interval for periodic background update checks (4 hours).
    private static let checkInterval: TimeInterval = 4 * 60 * 60

    private var periodicTimer: Timer?
    private let logger = Logger(subsystem: "com.drivecatalog", category: "UpdateService")

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    // MARK: - Periodic Check

    /// Start a repeating timer that checks for updates every 4 hours.
    func startPeriodicChecks() {
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.checkForUpdates()
            }
        }
    }

    func stopPeriodicChecks() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    // MARK: - Check for Updates

    func checkForUpdates() async {
        #if DEBUG
        return  // Never check for updates in debug builds
        #endif
        guard let url = URL(string: Self.manifestURL) else { return }

        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config)
            let (data, _) = try await session.data(from: url)
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)

            if manifest.build > currentBuild {
                latestVersion = manifest.version
                releaseNotes = manifest.notes
                downloadURL = URL(string: manifest.url)
                updateAvailable = true
                logger.info("Update available: \(manifest.version) (build \(manifest.build))")
            } else {
                updateAvailable = false
                logger.info("App is up to date (\(self.currentVersion))")
            }
        } catch {
            logger.warning("Update check failed: \(error.localizedDescription)")
            // Silent fail — don't bother the user
        }
    }

    // MARK: - Download and Install

    func downloadAndInstall() async {
        guard let url = downloadURL else { return }

        isDownloading = true
        downloadProgress = 0
        updateError = nil

        do {
            // 1. Download the ZIP to a temp file
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DriveCatalogUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let zipPath = tempDir.appendingPathComponent("DriveCatalog.zip")

            let (downloadedURL, response) = try await URLSession.shared.download(from: url)

            // Verify we got an actual ZIP, not an HTML error page
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: downloadedURL.path)[.size] as? Int64) ?? 0
            logger.info("Downloaded update: \(fileSize) bytes")

            if fileSize < 1_000_000 {
                // Suspiciously small — probably an error page, not a ZIP
                let content = (try? String(contentsOf: downloadedURL, encoding: .utf8)) ?? ""
                logger.error("Download too small (\(fileSize) bytes), content: \(content.prefix(200))")
                throw UpdateError.downloadCorrupt
            }

            try FileManager.default.moveItem(at: downloadedURL, to: zipPath)
            downloadProgress = 0.5

            // 2. Unzip using ditto (handles macOS ZIP format correctly)
            let unzipProc = Process()
            let unzipPipe = Pipe()
            unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzipProc.arguments = ["-x", "-k", zipPath.path, tempDir.path]
            unzipProc.standardError = unzipPipe
            try unzipProc.run()
            unzipProc.waitUntilExit()

            if unzipProc.terminationStatus != 0 {
                let stderr = String(data: unzipPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                logger.error("Unzip failed (exit \(unzipProc.terminationStatus)): \(stderr)")
                throw UpdateError.unzipFailed
            }
            downloadProgress = 0.8

            // 3. Find the .app in the unzipped contents
            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.noAppFound
            }

            // 4. Launch the replacer script and quit
            let currentAppPath = Bundle.main.bundlePath
            try launchReplacer(newApp: newApp.path, oldApp: currentAppPath)

            downloadProgress = 1.0

            // 5. Stop backend, then force quit — the script handles the rest
            BackendService.shared.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Use exit() as fallback if terminate is blocked by sheets/dialogs
                NSApplication.shared.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    exit(0)
                }
            }
        } catch {
            updateError = "Update failed: \(error.localizedDescription)"
            isDownloading = false
            logger.error("Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Self-Replacement Script

    private func launchReplacer(newApp: String, oldApp: String) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        # Wait for the old app to fully quit (poll by PID, max 30s)
        for i in $(seq 1 60); do
            if ! kill -0 \(pid) 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        # Replace old app with new (use cp+rm instead of mv for cross-volume safety)
        rm -rf "\(oldApp)"
        cp -R "\(newApp)" "\(oldApp)"
        rm -rf "\(newApp)"
        # Remove quarantine attribute
        xattr -cr "\(oldApp)" 2>/dev/null
        # Relaunch
        open "\(oldApp)"
        # Cleanup
        rm -f "$0"
        """

        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivecatalog_update_\(UUID().uuidString).sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath.path
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    enum UpdateError: LocalizedError {
        case unzipFailed
        case noAppFound
        case downloadCorrupt

        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "Failed to unzip the update. Try downloading manually from GitHub."
            case .noAppFound: return "No app found in the update package"
            case .downloadCorrupt: return "Download was corrupted or blocked. Try downloading manually from GitHub."
            }
        }
    }
}

// MARK: - Update Manifest

struct UpdateManifest: Codable {
    let version: String   // e.g. "1.3.0"
    let build: Int        // e.g. 3 — compared against CFBundleVersion
    let url: String       // download URL for the ZIP
    let notes: String?    // release notes (optional)
    let minOS: String?    // minimum macOS version (optional)

    enum CodingKeys: String, CodingKey {
        case version, build, url, notes
        case minOS = "min_os"
    }
}
