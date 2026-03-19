import SwiftUI

/// Finder-style file browser — navigate directories, not paginated lists.
struct BrowserView: View {
    @State private var drives: [DriveResponse] = []
    @State private var selectedDrive: DriveResponse?
    @State private var browseData: BrowseResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pathStack: [String] = []  // breadcrumb trail
    @State private var selectedFile: FileResponse?
    @State private var fileToCopy: FileResponse?
    @State private var showCopySheet = false

    var body: some View {
        NavigationStack {
            HSplitView {
                // Left: Drive list (like Finder sidebar)
                driveList
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 250)

                // Right: Directory contents
                VStack(spacing: 0) {
                    breadcrumbBar
                    Divider()
                    directoryContent
                }
            }
            .navigationTitle("Browser")
            .sheet(item: $selectedFile) { file in
                FileDetailSheet(file: file)
            }
            .sheet(isPresented: $showCopySheet) {
                if let file = fileToCopy {
                    CopySheet(sourceFile: file, onComplete: { await browse() })
                }
            }
            .task {
                await loadDrives()
            }
        }
    }

    // MARK: - Drive Sidebar

    private var driveList: some View {
        List(selection: Binding(
            get: { selectedDrive?.name },
            set: { name in
                selectedDrive = drives.first { $0.name == name }
                pathStack = []
                Task { await browse() }
            }
        )) {
            Section("Drives") {
                ForEach(drives) { drive in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drive.name)
                                .fontWeight(.medium)
                            Text("\(drive.fileCount) files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(.blue)
                    }
                    .tag(drive.name)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Breadcrumb Navigation

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            if let drive = selectedDrive {
                Button(drive.name) {
                    pathStack = []
                    Task { await browse() }
                }
                .buttonStyle(.plain)
                .fontWeight(.medium)

                ForEach(Array(pathStack.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Button(component) {
                        pathStack = Array(pathStack.prefix(index + 1))
                        Task { await browse() }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Select a drive")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let data = browseData {
                Text("\(data.directories.count) folders, \(data.files.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await browse() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .disabled(selectedDrive == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Directory Content

    @ViewBuilder
    private var directoryContent: some View {
        if selectedDrive == nil {
            VStack(spacing: 16) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Select a drive to browse")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await browse() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let data = browseData, data.directories.isEmpty && data.files.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "folder")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Empty folder")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let data = browseData {
            List {
                // Back button if not at root
                if !pathStack.isEmpty {
                    Button {
                        pathStack.removeLast()
                        Task { await browse() }
                    } label: {
                        Label {
                            Text("..")
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "arrow.turn.up.left")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Directories first (like Finder)
                ForEach(data.directories) { dir in
                    Button {
                        pathStack.append(dir.name)
                        Task { await browse() }
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                                .frame(width: 20)
                            Text(dir.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(dir.fileCount) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: dir.totalBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Then files
                ForEach(data.files) { file in
                    FileRow(file: file)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedFile = file
                        }
                        .contextMenu {
                            Button {
                                fileToCopy = file
                                showCopySheet = true
                            } label: {
                                Label("Copy to...", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadDrives() async {
        do {
            let response = try await APIService.shared.fetchDrives()
            drives = response.drives
            // Auto-select first drive
            if let first = drives.first {
                selectedDrive = first
                await browse()
            }
        } catch {
            // Non-critical
        }
    }

    private var currentPath: String {
        pathStack.joined(separator: "/")
    }

    private func browse() async {
        guard let drive = selectedDrive else { return }
        isLoading = true
        errorMessage = nil
        do {
            browseData = try await APIService.shared.browseDirectory(
                drive: drive.name,
                path: currentPath
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    BrowserView()
}
