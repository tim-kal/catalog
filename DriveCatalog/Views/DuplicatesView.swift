import SwiftUI

/// Backups page showing hierarchical protection status: drives > directories > files.
struct BackupsView: View {
    @Environment(\.activeTab) private var activeTab
    @ObservedObject private var backend = BackendService.shared
    @State private var treeData: ProtectionTreeResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDrive: String? = nil
    @State private var expandedDrives: Set<String> = []
    @State private var expandedDirs: Set<String> = []  // "drive:path"
    @State private var directoryFiles: [String: [FileGroup]] = [:]  // "drive:path" -> groups
    @State private var loadingDirs: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text("Analyzing protection status...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Failed to load backup data")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadData() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if let tree = treeData {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ProtectionDashboard(stats: tree.stats)

                            Divider()

                            // Drive filter
                            HStack(spacing: 12) {
                                HStack(spacing: 4) {
                                    Image(systemName: "externaldrive.fill")
                                        .foregroundStyle(.secondary)
                                    Picker("Drive", selection: $selectedDrive) {
                                        Text("All Drives").tag(nil as String?)
                                        ForEach(tree.drives) { drive in
                                            Text(drive.driveName).tag(drive.driveName as String?)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }

                                Spacer()

                                Text("\(tree.drives.count) drives")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            // Drive > Directory tree
                            if tree.drives.isEmpty {
                                emptyState
                            } else {
                                VStack(spacing: 1) {
                                    ForEach(filteredDrives(from: tree)) { drive in
                                        driveSection(drive)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Backups")
            .onReceive(NotificationCenter.default.publisher(for: .refreshCurrentPage)) { _ in
                if activeTab == .backups { Task { await loadData() } }
            }
            .task(id: backend.isRunning) {
                if backend.isRunning { await loadData() }
            }
            .onChange(of: selectedDrive) {
                Task { await loadData() }
            }
        }
    }

    // MARK: - Drive Section

    private func driveSection(_ drive: DriveProtectionSummary) -> some View {
        VStack(spacing: 0) {
            // Drive header — always visible, clickable to expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedDrives.contains(drive.driveName) {
                        expandedDrives.remove(drive.driveName)
                    } else {
                        expandedDrives.insert(drive.driveName)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expandedDrives.contains(drive.driveName)
                          ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Image(systemName: "externaldrive.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(drive.driveName)
                            .font(.headline)
                        Text("\(drive.totalFiles) files  ·  \(formattedSize(drive.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Protection badges
                    protectionBadges(
                        unprotected: drive.unprotectedFiles,
                        backedUp: drive.backedUpFiles,
                        overBackedUp: drive.overBackedUpFiles
                    )
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)

            // Expanded directories
            if expandedDrives.contains(drive.driveName) {
                VStack(spacing: 1) {
                    ForEach(drive.directories) { dir in
                        directoryRow(dir, driveName: drive.driveName)
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Directory Row

    private func directoryRow(_ dir: DirectoryProtection, driveName: String) -> some View {
        let key = "\(driveName):\(dir.path)"
        let isExpanded = expandedDirs.contains(key)
        let isLoadingFiles = loadingDirs.contains(key)

        return VStack(spacing: 0) {
            // Directory header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedDirs.remove(key)
                    } else {
                        expandedDirs.insert(key)
                        if directoryFiles[key] == nil {
                            Task { await loadDirectoryFiles(drive: driveName, path: dir.path) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)

                    Text(dir.path == "." ? "(root files)" : dir.path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    // Compact stats
                    Text("\(dir.totalFiles) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(formattedSize(dir.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Mini protection badges
                    protectionBadges(
                        unprotected: dir.unprotectedFiles,
                        backedUp: dir.backedUpFiles,
                        overBackedUp: dir.overBackedUpFiles
                    )
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .cornerRadius(6)

            // Expanded file groups
            if isExpanded {
                VStack(spacing: 0) {
                    if isLoadingFiles {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading files...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else if let groups = directoryFiles[key] {
                        if groups.isEmpty {
                            Text("No file groups found for this directory")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(groups) { group in
                                FileGroupRow(group: group)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - Protection Badges

    private func protectionBadges(unprotected: Int, backedUp: Int, overBackedUp: Int) -> some View {
        HStack(spacing: 6) {
            if unprotected > 0 {
                badge(count: unprotected, icon: "exclamationmark.shield.fill", color: .red)
            }
            if backedUp > 0 {
                badge(count: backedUp, icon: "checkmark.shield.fill", color: .green)
            }
            if overBackedUp > 0 {
                badge(count: overBackedUp, icon: "shield.fill", color: .blue)
            }
        }
    }

    private func badge(count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(formatCount(count))
                .font(.system(.caption2, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("No file groups found")
                .font(.headline)
            Text("Scan and hash your drives to analyze protection status.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Data Loading

    private func filteredDrives(from tree: ProtectionTreeResponse) -> [DriveProtectionSummary] {
        if let drive = selectedDrive {
            return tree.drives.filter { $0.driveName == drive }
        }
        return tree.drives
    }

    private func loadData() async {
        isLoading = treeData == nil
        errorMessage = nil
        do {
            treeData = try await APIService.shared.fetchProtectionTree()
            // Auto-expand if single drive or filtered
            if let tree = treeData, tree.drives.count == 1 {
                expandedDrives.insert(tree.drives[0].driveName)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadDirectoryFiles(drive: String, path: String) async {
        let key = "\(drive):\(path)"
        loadingDirs.insert(key)
        do {
            // Fetch files in this directory; if empty (all files in subdirs), fetch recursively
            var groups = try await APIService.shared.fetchDirectoryFiles(drive: drive, path: path)
            if groups.isEmpty {
                // Fallback: get file groups filtered by this drive + path prefix from the main endpoint
                let response = try await APIService.shared.fetchProtectionData(
                    limit: 200, status: nil, drive: drive, sortBy: "size"
                )
                groups = response.groups.filter { group in
                    group.locations.contains { $0.driveName == drive && $0.path.hasPrefix(path + "/") }
                }
            }
            directoryFiles[key] = groups
        } catch {
            directoryFiles[key] = []
        }
        loadingDirs.remove(key)
    }

    // MARK: - Formatting

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000).\((n % 1_000_000) / 100_000)M" }
        if n >= 1_000 { return "\(n / 1_000).\((n % 1_000) / 100)K" }
        return "\(n)"
    }
}

#Preview {
    BackupsView()
}
