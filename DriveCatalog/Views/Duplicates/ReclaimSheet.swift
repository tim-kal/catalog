import AppKit
import SwiftUI

/// Guided sheet for safely reclaiming space from over-backed-up files.
/// Verifies files are true duplicates before recommending deletion.
struct ReclaimSheet: View {
    let group: FileGroup

    @Environment(\.dismiss) private var dismiss
    @State private var driveMap: [String: DriveResponse] = [:]
    @State private var fileExists: [Int: Bool] = [:]
    @State private var isLoading = true
    @State private var syncingDrives: Set<String> = []
    @State private var syncComplete = false
    // Verification
    @State private var verification: VerificationResponse?
    @State private var isVerifying = false
    @State private var verificationError: String?

    private var removableCount: Int {
        max(0, group.driveCount - 2)
    }

    private var deletedCount: Int {
        group.locations.filter { !(fileExists[$0.fileId] ?? true) }.count
    }

    private var allCopiesOnDisk: Int {
        group.locations.filter { fileExists[$0.fileId] ?? false }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            verificationBanner
            guidance
            Divider()

            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking file locations...")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(group.locations) { loc in
                    locationRow(loc)
                }
            }

            Divider()

            bottomBar
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600)
        .task { await loadAndCheck() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.3.trianglepath")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaim Space")
                    .font(.headline)
                Text(group.filename)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedSize(group.sizeBytes))
                    .font(.title3)
                    .fontWeight(.medium)
                Text("per copy")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Verification Banner

    @ViewBuilder
    private var verificationBanner: some View {
        if isVerifying {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying files are true duplicates...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
        } else if let error = verificationError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Verification failed: \(error)")
                    .font(.callout)
            }
            .padding(10)
            .background(Color.red.opacity(0.08))
            .cornerRadius(8)
        } else if let v = verification {
            if v.verified {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Verified — all accessible copies are confirmed identical (deep hash match).")
                        .font(.callout)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .cornerRadius(8)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.seal.fill")
                        .foregroundStyle(.red)
                    Text("Warning — verification hashes do NOT match. These files may differ despite having the same partial hash. Do not delete.")
                        .font(.callout)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Guidance

    @ViewBuilder
    private var guidance: some View {
        if deletedCount > 0 && allCopiesOnDisk >= 2 {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(deletedCount) redundant copy/copies removed. \(allCopiesOnDisk) copies remain on \(allCopiesOnDisk) drive(s) — your file is safely backed up.")
                    .font(.callout)
            }
            .padding(10)
            .background(Color.green.opacity(0.08))
            .cornerRadius(8)
        } else if deletedCount > 0 && allCopiesOnDisk < 2 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Only \(allCopiesOnDisk) copy remains. Keep at least 2 copies on separate drives for safe backup.")
                    .font(.callout)
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(8)
        } else if removableCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text("This file exists on \(group.driveCount) drives (\(group.totalCopies) total copies). You can safely remove \(removableCount) drive copy/copies while keeping backups on 2 drives.")
                    .font(.callout)
            }
            .padding(10)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(8)
        }
    }

    // MARK: - Location Row

    private func locationRow(_ loc: FileLocation) -> some View {
        let drive = driveMap[loc.driveName]
        let mounted = isMounted(drive: drive)
        let exists = fileExists[loc.fileId] ?? true
        let isSyncing = syncingDrives.contains(loc.driveName)
        let verResult = verification?.results.first { $0.fileId == loc.fileId }

        return HStack(spacing: 10) {
            // Drive icon
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(mounted ? .blue : .secondary)
                .frame(width: 20)

            // Drive + path info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(loc.driveName)
                        .fontWeight(.medium)
                    // Verification indicator
                    if let vr = verResult {
                        if vr.accessible && vr.verificationHash != nil {
                            Image(systemName: verification?.verified == true
                                  ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .font(.caption2)
                                .foregroundStyle(verification?.verified == true ? .green : .red)
                        } else if !vr.accessible {
                            Image(systemName: "eye.slash.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Text(loc.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Status + actions
            if !mounted {
                Label("Not mounted", systemImage: "eject.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
            } else if !exists {
                Label("Removed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)
            } else if isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    openInFinder(loc)
                } label: {
                    Label("Open in Finder", systemImage: "folder.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            !exists ? Color.green.opacity(0.04) :
                !mounted ? Color.orange.opacity(0.04) : Color.clear
        )
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if deletedCount > 0 && !syncComplete {
                Button {
                    Task { await syncDeletedDrives() }
                } label: {
                    Label("Sync Database", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(!syncingDrives.isEmpty)
                .help("Run a quick scan to update the database after deletions")
            }

            if syncComplete {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Database synced")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Button {
                Task { await checkAll() }
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
            .help("Re-check if files still exist on disk")

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Data

    private func loadAndCheck() async {
        isLoading = true
        do {
            let response = try await APIService.shared.fetchDrives()
            for drive in response.drives {
                driveMap[drive.name] = drive
            }
        } catch {}
        await checkAll()
        isLoading = false

        // Run verification in background after initial load
        await runVerification()
    }

    private func checkAll() async {
        for loc in group.locations {
            if let drive = driveMap[loc.driveName] {
                let fullPath = "\(drive.mountPath)/\(loc.path)"
                fileExists[loc.fileId] = FileManager.default.fileExists(atPath: fullPath)
            } else {
                fileExists[loc.fileId] = false
            }
        }
    }

    private func runVerification() async {
        let fileIds = group.locations.map(\.fileId)
        guard fileIds.count >= 2 else { return }

        isVerifying = true
        verificationError = nil
        do {
            verification = try await APIService.shared.verifyFiles(fileIds: fileIds)
        } catch {
            verificationError = error.localizedDescription
        }
        isVerifying = false
    }

    private func openInFinder(_ loc: FileLocation) {
        guard let drive = driveMap[loc.driveName] else { return }
        let fullPath = "\(drive.mountPath)/\(loc.path)"
        let url = URL(fileURLWithPath: fullPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func syncDeletedDrives() async {
        // Auto-scan drives where files were deleted to update DB
        let drivesToSync = Set(
            group.locations
                .filter { !(fileExists[$0.fileId] ?? true) }
                .map(\.driveName)
        )
        for driveName in drivesToSync {
            syncingDrives.insert(driveName)
            _ = try? await APIService.shared.triggerAutoScan(driveName: driveName)
            syncingDrives.remove(driveName)
        }
        syncComplete = true
    }

    private func isMounted(drive: DriveResponse?) -> Bool {
        guard let drive else { return false }
        return FileManager.default.fileExists(atPath: drive.mountPath)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
