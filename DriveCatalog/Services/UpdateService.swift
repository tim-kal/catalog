import AppKit
import Foundation
import os

/// Checks for app updates via a JSON manifest on GitHub and handles self-replacement.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    /// URL to the update manifest JSON. Change this to your actual repo.
    static let manifestURL = "https://raw.githubusercontent.com/tim-kal/DriveCatalog/main/updates/latest.json"

    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var releaseNotes: String?
    @Published var downloadURL: URL?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var updateError: String?

    private let logger = Logger(subsystem: "com.drivecatalog", category: "UpdateService")

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    // MARK: - Check for Updates

    func checkForUpdates() async {
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

            let (downloadedURL, _) = try await URLSession.shared.download(from: url)
            try FileManager.default.moveItem(at: downloadedURL, to: zipPath)
            downloadProgress = 0.5

            // 2. Unzip
            let unzipProc = Process()
            unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProc.arguments = ["-o", "-q", zipPath.path, "-d", tempDir.path]
            try unzipProc.run()
            unzipProc.waitUntilExit()

            guard unzipProc.terminationStatus == 0 else {
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

            // 5. Quit the app — the script handles the rest
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            updateError = "Update failed: \(error.localizedDescription)"
            isDownloading = false
            logger.error("Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Self-Replacement Script

    private func launchReplacer(newApp: String, oldApp: String) throws {
        let script = """
        #!/bin/bash
        # Wait for the old app to quit
        sleep 2
        # Replace old app with new
        rm -rf "\(oldApp)"
        mv "\(newApp)" "\(oldApp)"
        # Remove quarantine attribute
        xattr -cr "\(oldApp)" 2>/dev/null
        # Relaunch
        open "\(oldApp)"
        # Cleanup
        rm -f "$0"
        """

        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivecatalog_update.sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath.path]
        try proc.run()
    }

    enum UpdateError: LocalizedError {
        case unzipFailed
        case noAppFound

        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "Failed to unzip the update"
            case .noAppFound: return "No app found in the update package"
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
