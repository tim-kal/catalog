import SwiftUI

/// Drill-down view for a recommended action from the Insights page.
/// Loads and displays the actual file groups underlying the recommendation,
/// organized by folder for easy scanning.
struct ActionDrillDownView: View {
    let action: RecommendedAction
    var onBack: () -> Void

    @State private var groups: [FileGroup] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var totalReclaimable: Int64 = 0
    @State private var showByFolder = true
    @State private var sortMode: SortMode = .reclaimable
    @State private var queuedPaths: Set<String> = []
    @State private var queueMessage: String?

    enum SortMode: String, CaseIterable {
        case reclaimable = "Reclaimable"
        case size = "Total Size"
        case files = "File Count"
        case drive = "Drive Count"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with back button
            topBar
            Divider()

            if isLoading && groups.isEmpty {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Loading files — this may take a moment for large catalogs...")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, groups.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Button("Retry") { Task { await loadData() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("No files found")
                        .font(.headline)
                    Text("This recommendation may no longer apply.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    summaryHeader
                    Divider()
                    if showByFolder {
                        folderGroupedList
                    } else {
                        flatFileList
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = queueMessage {
                Text(msg)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: queueMessage)
            }
        }
        .task { await loadData() }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                onBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Insights")
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Spacer()

            Text(action.title)
                .font(.headline)

            Spacer()

            // Sort picker
            Picker("Sort", selection: $sortMode) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 140)

            // View mode toggle
            Picker("View", selection: $showByFolder) {
                Label("Folders", systemImage: "folder").tag(true)
                Label("Files", systemImage: "doc").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Summary Header

    private var summaryHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: action.icon)
                .font(.title2)
                .foregroundStyle(action.swiftColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(groups.count) file groups", systemImage: "doc.on.doc")
                    Label("\(folderSummaries.count) folders", systemImage: "folder")
                    if totalReclaimable > 0 {
                        Label("\(formattedSize(totalReclaimable)) reclaimable", systemImage: "arrow.uturn.backward")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
            Spacer()
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Folder-Grouped View

    /// Aggregated folder summaries, sorted by total reclaimable bytes.
    private var folderSummaries: [FolderSummary] {
        var folders: [String: FolderSummary] = [:]

        for group in groups {
            // Use the first location's directory as the folder key
            guard let firstLoc = group.locations.first else { continue }
            let dir = (firstLoc.path as NSString).deletingLastPathComponent
            let folderKey = dir.isEmpty ? "/" : dir

            if var existing = folders[folderKey] {
                existing.fileCount += 1
                existing.totalBytes += group.sizeBytes
                existing.reclaimableBytes += group.reclaimableBytes
                existing.maxDriveCount = max(existing.maxDriveCount, group.driveCount)
                // Collect unique drives
                for loc in group.locations {
                    existing.driveNames.insert(loc.driveName)
                }
                existing.files.append(group)
                folders[folderKey] = existing
            } else {
                var driveNames = Set<String>()
                for loc in group.locations {
                    driveNames.insert(loc.driveName)
                }
                folders[folderKey] = FolderSummary(
                    path: folderKey,
                    fileCount: 1,
                    totalBytes: group.sizeBytes,
                    reclaimableBytes: group.reclaimableBytes,
                    maxDriveCount: group.driveCount,
                    driveNames: driveNames,
                    files: [group]
                )
            }
        }

        return folders.values.sorted { a, b in
            switch sortMode {
            case .reclaimable: return a.reclaimableBytes > b.reclaimableBytes
            case .size: return a.totalBytes > b.totalBytes
            case .files: return a.fileCount > b.fileCount
            case .drive: return a.driveNames.count > b.driveNames.count
            }
        }
    }

    private var folderGroupedList: some View {
        List {
            ForEach(folderSummaries) { folder in
                DisclosureGroup {
                    ForEach(folder.files.sorted(by: { $0.sizeBytes > $1.sizeBytes })) { group in
                        fileGroupRow(group)
                    }
                } label: {
                    folderRow(folder)
                }
                .contextMenu {
                    if folder.driveNames.count > 1 {
                        ForEach(folder.driveNames.sorted(), id: \.self) { drive in
                            Button {
                                Task { await queueFolderDeletes(folder: folder, fromDrive: drive) }
                            } label: {
                                Label("Queue delete all from \(drive)", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: FolderSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.path)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text("\(folder.fileCount) files")
                    Text("on \(folder.driveNames.count) drives")
                    Text(folder.driveNames.sorted().joined(separator: ", "))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedSize(folder.totalBytes))
                    .font(.callout)
                    .fontWeight(.semibold)
                if folder.reclaimableBytes > 0 {
                    Text("\(formattedSize(folder.reclaimableBytes)) reclaimable")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Flat File List

    private var sortedGroups: [FileGroup] {
        groups.sorted { a, b in
            switch sortMode {
            case .reclaimable: return a.reclaimableBytes > b.reclaimableBytes
            case .size: return a.sizeBytes > b.sizeBytes
            case .files: return a.totalCopies > b.totalCopies
            case .drive: return a.driveCount > b.driveCount
            }
        }
    }

    private var flatFileList: some View {
        List {
            ForEach(sortedGroups) { group in
                fileGroupRow(group)
            }
        }
    }

    private func fileGroupRow(_ group: FileGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: iconForFile(group.filename))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(group.filename)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(formattedSize(group.sizeBytes))
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(action.swiftColor)
            }

            HStack(spacing: 10) {
                Label("\(group.totalCopies) copies", systemImage: "doc.on.doc")
                Label("\(group.driveCount) drives", systemImage: "externaldrive")
                if group.reclaimableBytes > 0 {
                    Text("\(formattedSize(group.reclaimableBytes)) reclaimable")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Location list with delete queue buttons
            HStack(spacing: 4) {
                ForEach(group.locations) { loc in
                    Text(loc.driveName)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Capsule())
                        .contextMenu {
                            if group.driveCount > 1 {
                                Button {
                                    Task { await queueDelete(drive: loc.driveName, path: loc.path, bytes: group.sizeBytes) }
                                } label: {
                                    Label("Queue delete from \(loc.driveName)", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        errorMessage = nil
        do {
            let response: ProtectionResponse
            switch action.actionType {
            case "backup":
                response = try await APIService.shared.fetchProtectionData(
                    limit: 10000,
                    status: "unprotected",
                    drive: action.target,
                    sortBy: "size"
                )
            case "cleanup":
                if action.id.contains("same_drive") {
                    response = try await APIService.shared.fetchProtectionData(
                        limit: 10000,
                        status: "same_drive_duplicate",
                        sortBy: "reclaimable"
                    )
                } else {
                    // "trim redundant" — files on 3+ drives
                    response = try await APIService.shared.fetchProtectionData(
                        limit: 10000,
                        status: "over_backed_up",
                        sortBy: "reclaimable"
                    )
                }
            default:
                response = try await APIService.shared.fetchProtectionData(
                    limit: 10000,
                    status: "over_backed_up",
                    sortBy: "size"
                )
            }
            groups = response.groups
            totalReclaimable = response.stats.reclaimableBytes
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Queue Actions

    private func queueDelete(drive: String, path: String, bytes: Int64) async {
        let key = "\(drive):\(path)"
        guard !queuedPaths.contains(key) else { return }
        do {
            let request = CreateActionRequest(
                actionType: "delete",
                sourceDrive: drive,
                sourcePath: path,
                targetDrive: nil,
                targetPath: nil,
                priority: 0,
                reason: "Redundant copy — on \(action.title)",
                estimatedBytes: bytes
            )
            _ = try await APIService.shared.createAction(request)
            queuedPaths.insert(key)
            queueMessage = "Queued deletion of \(path) from \(drive)"
        } catch {
            queueMessage = "Failed: \(error.localizedDescription)"
        }

        // Clear message after a few seconds
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        queueMessage = nil
    }

    private func queueFolderDeletes(folder: FolderSummary, fromDrive drive: String) async {
        var queued = 0
        for file in folder.files {
            guard let loc = file.locations.first(where: { $0.driveName == drive }) else { continue }
            let key = "\(drive):\(loc.path)"
            guard !queuedPaths.contains(key) else { continue }
            do {
                let request = CreateActionRequest(
                    actionType: "delete",
                    sourceDrive: drive,
                    sourcePath: loc.path,
                    targetDrive: nil,
                    targetPath: nil,
                    priority: 0,
                    reason: "Redundant copy — bulk from \(folder.path)",
                    estimatedBytes: file.sizeBytes
                )
                _ = try await APIService.shared.createAction(request)
                queuedPaths.insert(key)
                queued += 1
            } catch {
                // Continue with remaining files
            }
        }
        queueMessage = "Queued \(queued) deletions from \(drive)"
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        queueMessage = nil
    }

    // MARK: - Helpers

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func iconForFile(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mov", "mp4", "r3d", "braw", "mxf", "mkv", "avi", "m4v":
            return "film"
        case "jpg", "jpeg", "png", "tiff", "heic", "gif", "webp":
            return "photo"
        case "cr2", "arw", "dng", "nef", "raw", "cr3":
            return "camera"
        case "wav", "mp3", "aiff", "flac", "aac", "m4a":
            return "waveform"
        case "psd", "aep", "prproj", "drp", "fcpxml":
            return "doc.richtext"
        case "zip", "rar", "tar", "gz", "7z", "dmg":
            return "archivebox"
        default:
            return "doc"
        }
    }
}

// MARK: - Folder Summary Model

private struct FolderSummary: Identifiable {
    let path: String
    var fileCount: Int
    var totalBytes: Int64
    var reclaimableBytes: Int64
    var maxDriveCount: Int
    var driveNames: Set<String>
    var files: [FileGroup]

    var id: String { path }
}
