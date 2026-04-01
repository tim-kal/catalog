import SwiftUI

/// Shows all root-level folders and files across all drives in a unified, sortable list.
struct AllDrivesView: View {
    @State private var entries: [DriveEntry] = []
    @State private var isLoading = true
    @State private var sortMode: AllDriveSort = .size
    @State private var searchText = ""

    enum AllDriveSort: String, CaseIterable {
        case name = "Name"
        case size = "Size"
        case drive = "Drive"
        case files = "Files"
    }

    struct DriveEntry: Identifiable {
        let driveName: String
        let directory: DirectoryEntry
        var id: String { "\(driveName)/\(directory.path)" }
    }

    private var filteredEntries: [DriveEntry] {
        let filtered = searchText.isEmpty ? entries : entries.filter {
            $0.directory.name.localizedCaseInsensitiveContains(searchText) ||
            $0.driveName.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted { a, b in
            switch sortMode {
            case .name:
                return a.directory.name.localizedStandardCompare(b.directory.name) == .orderedAscending
            case .size:
                return a.directory.totalBytes > b.directory.totalBytes
            case .drive:
                if a.driveName == b.driveName {
                    return a.directory.name.localizedStandardCompare(b.directory.name) == .orderedAscending
                }
                return a.driveName.localizedStandardCompare(b.driveName) == .orderedAscending
            case .files:
                return a.directory.fileCount > b.directory.fileCount
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search and sort
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter folders...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)

                Picker("Sort", selection: $sortMode) {
                    ForEach(AllDriveSort.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Text("\(filteredEntries.count) folders")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Loading all drives...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No folders found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        entryRow(entry)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task { await loadAllDrives() }
    }

    private func entryRow(_ entry: DriveEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.directory.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(entry.driveName, systemImage: "externaldrive.fill")
                        .foregroundStyle(.secondary)
                    if entry.directory.childDirCount > 0 {
                        Text("\(entry.directory.childDirCount) folders")
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(entry.directory.fileCount) files")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }

            Spacer()

            Text(formattedSize(entry.directory.totalBytes))
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func loadAllDrives() async {
        isLoading = true
        do {
            let response = try await APIService.shared.fetchDrives()
            var allEntries: [DriveEntry] = []

            await withTaskGroup(of: [DriveEntry].self) { group in
                for drive in response.drives {
                    group.addTask {
                        guard let browse = try? await APIService.shared.browseDirectory(drive: drive.name, path: "") else {
                            return []
                        }
                        return browse.directories.map { dir in
                            DriveEntry(driveName: drive.name, directory: dir)
                        }
                    }
                }
                for await driveEntries in group {
                    allEntries.append(contentsOf: driveEntries)
                }
            }

            entries = allEntries
        } catch {
            // Non-critical
        }
        isLoading = false
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
