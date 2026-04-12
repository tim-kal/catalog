import AppKit
import SwiftUI

// MARK: - Sort Options

enum SortField: String, CaseIterable {
    case name = "Name"
    case size = "Size"
    case date = "Date"
    case type = "Type"
}

enum SortDirection {
    case ascending, descending
    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

// MARK: - Column Data

/// One column in the browser — the browse response at a specific depth.
private struct ColumnData: Identifiable {
    let id = UUID()
    let depth: Int
    let path: String       // relative path for this column
    let response: BrowseResponse
    var selectedDir: String?  // which directory is selected (highlighted) in this column
}

// MARK: - Browser View

struct BrowserView: View {
    @ObservedObject private var backend = BackendService.shared
    @Environment(\.activeTab) private var activeTab
    @State private var drives: [DriveResponse] = []
    @State private var selectedDrive: DriveResponse?
    @State private var columns: [ColumnData] = []
    @State private var isLoading = false
    @State private var showAllDrives = false
    @State private var errorMessage: String?
    @State private var selectedFile: FileResponse?
    @State private var fileToCopy: FileResponse?
    @State private var expandedFileId: Int?
    @State private var showCopySheet = false
    @State private var backupCache: [String: BackupStatusResponse] = [:]

    // Sort
    @State private var sortField: SortField = .name
    @State private var sortDirection: SortDirection = .ascending

    // Search
    @State private var searchQuery: String = ""
    @State private var searchResults: [SearchFile] = []
    @State private var searchTotal = 0
    @State private var isSearching = false
    @State private var hasSearched = false

    // Keyboard navigation
    @FocusState private var browserFocused: Bool
    @State private var kbColumn: Int = 0
    @State private var kbRow: Int = -1

    var body: some View {
        NavigationStack {
            HSplitView {
                driveList
                    .frame(minWidth: 120, idealWidth: 140, maxWidth: 180)

                VStack(spacing: 0) {
                    if showAllDrives && !hasSearched {
                        searchBar
                        Divider()
                        AllDrivesView()
                    } else {
                        toolBar
                        if hasSearched {
                            searchContent
                        } else {
                            columnContent
                        }
                    }
                }
            }
    
            .sheet(item: $selectedFile) { file in
                FileDetailSheet(file: file)
            }
            .sheet(isPresented: $showCopySheet) {
                if let file = fileToCopy {
                    CopySheet(sourceFile: file, onComplete: {
                        if let last = columns.last {
                            await loadColumn(path: last.path, depth: last.depth)
                        }
                    })
                }
            }
            .task(id: backend.isRunning) {
                if backend.isRunning {
                    await loadDrives()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshCurrentPage)) { _ in
                if activeTab == .browser {
                    Task {
                        await loadDrives()
                        columns = []
                        if selectedDrive != nil {
                            await loadColumn(path: "", depth: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Drive Sidebar

    private var driveList: some View {
        List(selection: Binding(
            get: { showAllDrives ? "__all__" : selectedDrive?.name },
            set: { name in
                if name == "__all__" {
                    showAllDrives = true
                    selectedDrive = nil
                } else {
                    showAllDrives = false
                    selectedDrive = drives.first { $0.name == name }
                    UserDefaults.standard.set(name, forKey: "browserSelectedDrive")
                    columns = []  // Clear stale columns immediately
                    expandedFileId = nil
                    kbColumn = 0
                    kbRow = -1
                    clearSearch()
                    Task { await loadColumn(path: "", depth: 0) }
                }
            }
        )) {
            Label {
                Text("All Drives")
                    .fontWeight(.medium)
            } icon: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .tag("__all__")

            Section("Drives") {
                ForEach(drives) { drive in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(drive.name)
                                    .fontWeight(.medium)
                                if FileManager.default.fileExists(atPath: drive.mountPath) {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 6, height: 6)
                                }
                            }
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

    // MARK: - Toolbar (search + sort + breadcrumb)

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                showAllDrives ? "Search all drives..." : (selectedDrive.map { "Search \($0.name)..." } ?? "Search..."),
                text: $searchQuery
            )
            .textFieldStyle(.plain)
            .onSubmit { Task { await performSearch() } }

            if !searchQuery.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var toolBar: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            // Breadcrumb + sort
            HStack(spacing: 4) {
                if hasSearched {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(searchTotal) results")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    breadcrumbs
                }

                Spacer()

                // Sort picker
                if !hasSearched {
                    sortControls
                }

                Button {
                    Task {
                        columns = []
                        await loadColumn(path: "", depth: 0)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .disabled(selectedDrive == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var breadcrumbs: some View {
        if let drive = selectedDrive {
            Button(drive.name) {
                columns = []
                Task { await loadColumn(path: "", depth: 0) }
            }
            .buttonStyle(.plain)
            .fontWeight(.medium)
            .font(.callout)

            ForEach(columns.dropFirst(), id: \.id) { col in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                let name = col.path.components(separatedBy: "/").last ?? col.path
                Button(name) {
                    // Trim columns to this depth
                    columns = Array(columns.prefix(col.depth + 1))
                    // Clear selection on the last column
                    if !columns.isEmpty {
                        columns[columns.count - 1].selectedDir = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
            }
        } else {
            Text("Select a drive")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var sortControls: some View {
        HStack(spacing: 2) {
            ForEach(SortField.allCases, id: \.self) { field in
                Button {
                    if sortField == field {
                        sortDirection.toggle()
                    } else {
                        sortField = field
                        sortDirection = .ascending
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(field.rawValue)
                            .lineLimit(1)
                            .fixedSize()
                        if sortField == field {
                            Image(systemName: sortDirection == .ascending
                                  ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(sortField == field
                                ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Column Content

    @ViewBuilder
    private var columnContent: some View {
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
        } else if isLoading && columns.isEmpty {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Loading...").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, columns.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await loadColumn(path: "", depth: 0) }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { index, col in
                            let columnWidth: CGFloat = columns.count == 1
                                ? max(geo.size.width, 300)
                                : max(300, min(geo.size.width / CGFloat(columns.count), 500))
                            columnView(col: col, index: index)
                                .frame(width: columnWidth)
                                .id(col.id)

                            if index < columns.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .onChange(of: columns.count) { _, _ in
                    if let lastId = columns.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollProxy.scrollTo(lastId, anchor: .trailing)
                        }
                    }
                }
                .focusable()
                .focused($browserFocused)
                .onKeyPress(.downArrow) { navigateKeyboard(.down) }
                .onKeyPress(.upArrow) { navigateKeyboard(.up) }
                .onKeyPress(.leftArrow) { navigateKeyboard(.left) }
                .onKeyPress(.rightArrow) { navigateKeyboard(.right) }
                .onKeyPress(.return) { navigateKeyboard(.activate) }
            }
            } // GeometryReader
        }
    }

    private func columnView(col: ColumnData, index: Int) -> some View {
        let dirs = sortedDirectories(col.response.directories)
        let files = sortedFiles(col.response.files)

        return List {
            ForEach(Array(dirs.enumerated()), id: \.element.id) { dirIdx, dir in
                dirRow(dir: dir, col: col, index: index)
                    .listRowBackground(
                        kbRow >= 0 && kbColumn == index && kbRow == dirIdx
                            ? Color.accentColor.opacity(0.15) : nil
                    )
            }
            ForEach(Array(files.enumerated()), id: \.element.id) { fileIdx, file in
                fileRow(file: file)
                    .listRowBackground(
                        kbRow >= 0 && kbColumn == index && kbRow == (dirs.count + fileIdx)
                            ? Color.accentColor.opacity(0.15) : nil
                    )
            }
        }
        .listStyle(.plain)
    }

    private func dirRow(dir: DirectoryEntry, col: ColumnData, index: Int) -> some View {
        let isSelected = col.selectedDir == dir.name

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 18)
                    .onTapGesture {
                        revealInFinder(relativePath: dir.path, isDirectory: true)
                    }
                    .help("Open in Finder")
                Text(dir.name)
                    .lineLimit(1)

                if let backup = backupCache[dir.path] {
                    let otherDriveCount = backup.backupDrives.filter { $0.driveName != selectedDrive?.name }.count
                    if backup.hashedFiles > 0 {
                        // Consistent badge: green checkmark for full backups, orange for partial, red for none
                        HStack(spacing: 3) {
                            Image(systemName: otherDriveCount == 0 ? "exclamationmark.shield" :
                                  backup.backupDrives.filter({ $0.driveName != selectedDrive?.name }).allSatisfy({ $0.percentCoverage >= 100 }) ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                                .font(.caption2)
                            Text("\(otherDriveCount)")
                                .font(.caption2)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(otherDriveCount == 0 ? Color.red.opacity(0.15) :
                                    backup.backupDrives.filter({ $0.driveName != selectedDrive?.name }).allSatisfy({ $0.percentCoverage >= 100 }) ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .foregroundStyle(otherDriveCount == 0 ? .red :
                                         backup.backupDrives.filter({ $0.driveName != selectedDrive?.name }).allSatisfy({ $0.percentCoverage >= 100 }) ? .green : .orange)
                        .clipShape(Capsule())
                    }
                }

                Spacer()
                Text("\(dir.fileCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)

            // Expanded folder info when selected
            if isSelected {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Label(formattedBrowseSize(dir.totalBytes), systemImage: "internaldisk.fill")
                        if dir.childDirCount > 0 {
                            Label("\(dir.childDirCount) folders", systemImage: "folder.fill")
                        }
                        Label("\(dir.fileCount) files", systemImage: "doc.fill")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    // Backup info
                    if let backup = backupCache[dir.path] {
                        let currentDriveName = selectedDrive?.name ?? ""
                        let otherDrives = backup.backupDrives.filter { $0.driveName != currentDriveName }
                        let currentDriveBackup = backup.backupDrives.first { $0.driveName == currentDriveName }

                        if backup.hashedFiles == 0 {
                            Label("Not hashed yet — run a scan to detect copies", systemImage: "questionmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else if otherDrives.isEmpty {
                            Label("No copies on other drives — at risk", systemImage: "exclamationmark.shield.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        } else {
                            Text("Also exists on \(otherDrives.count) other drive\(otherDrives.count == 1 ? "" : "s"):")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            ForEach(otherDrives, id: \.driveName) { bd in
                                HStack(spacing: 4) {
                                    Image(systemName: bd.percentCoverage >= 100
                                          ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                                        .foregroundStyle(bd.percentCoverage >= 100 ? .green : .orange)
                                    Text(bd.driveName)
                                        .fontWeight(.medium)
                                    Text("–")
                                    Text("\(bd.fileCount) of \(backup.totalFiles) files (\(String(format: "%.1f", bd.percentCoverage))%)")
                                        .foregroundStyle(bd.percentCoverage >= 100 ? .green : .orange)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }

                        // Current drive as last item in grey
                        if backup.hashedFiles > 0 {
                            let pct = backup.totalFiles > 0
                                ? Double(currentDriveBackup?.fileCount ?? backup.totalFiles) / Double(backup.totalFiles) * 100
                                : 0
                            HStack(spacing: 4) {
                                Image(systemName: "externaldrive.fill.badge.checkmark")
                                    .foregroundStyle(.tertiary)
                                Text("\(currentDriveName) (selected)")
                                    .fontWeight(.medium)
                                Text("–")
                                Text("\(backup.totalFiles) of \(backup.totalFiles) files (\(String(format: "%.1f", pct))%)")
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.leading, 22)
                .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .onTapGesture {
            selectDirectory(dir.name, atColumn: index)
        }
        .contextMenu {
            Button {
                revealInFinder(relativePath: dir.path, isDirectory: true)
            } label: {
                Label("Reveal in Finder", systemImage: "arrow.right.circle")
            }
        }
    }

    private func fileRow(file: FileResponse) -> some View {
        let isExpanded = expandedFileId == file.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.isMedia ? "film.fill" : "doc.fill")
                    .foregroundStyle(file.isMedia ? .orange : .secondary)
                    .frame(width: 18)
                    .onTapGesture {
                        revealInFinder(relativePath: file.path, isDirectory: false)
                    }
                    .help("Open in Finder")
                Text(file.filename)
                    .lineLimit(1)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let copies = file.copyCount, copies > 1 {
                    HStack(spacing: 2) {
                        Image(systemName: "externaldrive.fill")
                            .font(.caption2)
                        Text("\(copies)")
                            .font(.caption2)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(copies >= 3 ? Color.blue.opacity(0.15) : Color.green.opacity(0.15))
                    .foregroundStyle(copies >= 3 ? .blue : .green)
                    .clipShape(Capsule())
                    .help("Exists on \(copies) drives (click to expand)")
                } else if file.copyCount == 1 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .help("Only on this drive — no backup")
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedFileId = isExpanded ? nil : file.id
                }
            }

            // Expanded file detail — shows which drives have this file
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let copies = file.copyCount, copies > 1 {
                        let drives = file.copyDrives ?? []
                        let currentDrive = selectedDrive?.name ?? ""
                        Text("This file exists on \(copies) drive\(copies == 1 ? "" : "s")\(drives.isEmpty ? "" : ":"):")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        ForEach(drives, id: \.self) { driveName in
                            HStack(spacing: 6) {
                                Image(systemName: driveName == currentDrive ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                                    .font(.caption2)
                                    .foregroundStyle(driveName == currentDrive ? .blue : .secondary)
                                Text(driveName)
                                    .font(.caption)
                                    .fontWeight(driveName == currentDrive ? .semibold : .regular)
                                if driveName == currentDrive {
                                    Text("(this drive)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if driveName != currentDrive && copies > 2 {
                                    Button {
                                        queueDeleteFromDrive(file: file, driveName: driveName)
                                    } label: {
                                        Text("Queue delete")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                        }
                    } else if file.copyCount == 1 {
                        Label("Only exists on this drive — consider backing up", systemImage: "exclamationmark.shield")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        Label("Not hashed yet — run a scan to detect copies", systemImage: "questionmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 8) {
                        Button {
                            selectedFile = file
                        } label: {
                            Label("Details", systemImage: "info.circle")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button {
                            fileToCopy = file
                            showCopySheet = true
                        } label: {
                            Label("Copy to...", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.top, 2)
                }
                .padding(.leading, 26)
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isExpanded ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(4)
        .contextMenu {
            Button {
                revealInFinder(relativePath: file.path, isDirectory: false)
            } label: {
                Label("Reveal in Finder", systemImage: "arrow.right.circle")
            }
            Button {
                fileToCopy = file
                showCopySheet = true
            } label: {
                Label("Copy to...", systemImage: "doc.on.doc")
            }
            if let copies = file.copyCount, copies > 2, let drives = file.copyDrives, !drives.isEmpty {
                Divider()
                let currentDrive = selectedDrive?.name ?? ""
                ForEach(drives.filter { $0 != currentDrive }, id: \.self) { driveName in
                    Button {
                        queueDeleteFromDrive(file: file, driveName: driveName)
                    } label: {
                        Label("Queue delete from \(driveName)", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func queueDeleteFromDrive(file: FileResponse, driveName: String) {
        Task {
            let req = CreateActionRequest(
                actionType: "delete",
                sourceDrive: driveName,
                sourcePath: file.path,
                targetDrive: nil,
                targetPath: nil,
                priority: 0,
                reason: "Redundant copy — file exists on \(file.copyCount ?? 1) drives",
                estimatedBytes: file.sizeBytes
            )
            _ = try? await APIService.shared.createAction(req)
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchContent: some View {
        if isSearching {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Searching...").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No files matching '\(searchQuery)'")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(searchResults) { file in
                    SearchResultRow(file: file)
                        .contextMenu {
                            if let drive = drives.first(where: { $0.name == file.driveName }) {
                                Button {
                                    let fullPath = "\(drive.mountPath)/\(file.path)"
                                    let url = URL(fileURLWithPath: fullPath)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } label: {
                                    Label("Reveal in Finder", systemImage: "arrow.right.circle")
                                }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Keyboard Navigation

    private enum KeyDirection {
        case up, down, left, right, activate
    }

    private func navigateKeyboard(_ direction: KeyDirection) -> KeyPress.Result {
        guard !columns.isEmpty else { return .ignored }
        let colIdx = min(kbColumn, columns.count - 1)
        kbColumn = colIdx

        let col = columns[colIdx]
        let dirs = sortedDirectories(col.response.directories)
        let files = sortedFiles(col.response.files)
        let total = dirs.count + files.count

        guard total > 0 else { return .ignored }

        switch direction {
        case .down:
            if kbRow < total - 1 { kbRow += 1 }
            else if kbRow < 0 { kbRow = 0 }

        case .up:
            if kbRow > 0 { kbRow -= 1 }
            else if kbRow < 0 { kbRow = 0 }

        case .right:
            if kbRow >= 0 && kbRow < dirs.count {
                selectDirectory(dirs[kbRow].name, atColumn: colIdx)
            } else if colIdx < columns.count - 1 {
                kbColumn = colIdx + 1
                kbRow = 0
            }

        case .left:
            if colIdx > 0 {
                kbColumn = colIdx - 1
                if let sel = columns[kbColumn].selectedDir {
                    let parentDirs = sortedDirectories(columns[kbColumn].response.directories)
                    kbRow = parentDirs.firstIndex(where: { $0.name == sel }) ?? 0
                } else {
                    kbRow = 0
                }
            }

        case .activate:
            if kbRow >= 0 && kbRow < dirs.count {
                selectDirectory(dirs[kbRow].name, atColumn: colIdx)
            } else if kbRow >= dirs.count {
                let fileIdx = kbRow - dirs.count
                if fileIdx < files.count {
                    selectedFile = files[fileIdx]
                }
            }
        }

        return .handled
    }

    // MARK: - Sorting

    private func sortedDirectories(_ dirs: [DirectoryEntry]) -> [DirectoryEntry] {
        dirs.sorted { a, b in
            let asc = sortDirection == .ascending
            switch sortField {
            case .name, .type, .date:
                let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            case .size:
                return asc ? a.totalBytes < b.totalBytes : a.totalBytes > b.totalBytes
            }
        }
    }

    private func sortedFiles(_ files: [FileResponse]) -> [FileResponse] {
        files.sorted { a, b in
            let asc = sortDirection == .ascending
            switch sortField {
            case .name:
                let cmp = a.filename.localizedCaseInsensitiveCompare(b.filename)
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            case .size:
                return asc ? a.sizeBytes < b.sizeBytes : a.sizeBytes > b.sizeBytes
            case .date:
                let aTime = a.mtime ?? ""
                let bTime = b.mtime ?? ""
                return asc ? aTime < bTime : aTime > bTime
            case .type:
                let aExt = (a.filename as NSString).pathExtension.lowercased()
                let bExt = (b.filename as NSString).pathExtension.lowercased()
                if aExt != bExt {
                    return asc ? aExt < bExt : aExt > bExt
                }
                let cmp = a.filename.localizedCaseInsensitiveCompare(b.filename)
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
    }

    // MARK: - Data Loading

    private func loadDrives() async {
        // Load cached backup statuses
        if backupCache.isEmpty,
           let cached = ViewCache.load([String: BackupStatusResponse].self, key: "browserBackupCache") {
            backupCache = cached
        }

        // Show cached state immediately
        if drives.isEmpty {
            if let cached = ViewCache.load([DriveResponse].self, key: "browserDrives") {
                drives = cached
                let savedName = UserDefaults.standard.string(forKey: "browserSelectedDrive")
                if let name = savedName, let drive = cached.first(where: { $0.name == name }) {
                    selectedDrive = drive
                } else if let first = cached.first {
                    selectedDrive = first
                }
                // Load cached root column for selected drive
                if let sel = selectedDrive,
                   let cachedCol = ViewCache.load(BrowseResponse.self, key: "browserRoot_\(sel.name)") {
                    columns = [ColumnData(depth: 0, path: "", response: cachedCol)]
                    // Fetch backup statuses for cached directories
                    Task { await loadBackupStatuses(drive: sel.name, directories: cachedCol.directories) }
                }
            }
        }

        // Refresh from API in background
        do {
            let response = try await APIService.shared.fetchDrives()
            drives = response.drives
            ViewCache.save(response.drives, key: "browserDrives")
            if selectedDrive == nil, let first = drives.first {
                selectedDrive = first
            }
            // Always refresh root column to get fresh data + backup statuses
            if let sel = selectedDrive {
                await loadColumn(path: "", depth: 0)
            }
        } catch {
            // Non-critical — cached data already shown
        }
    }

    private func selectDirectory(_ name: String, atColumn index: Int) {
        // Toggle: clicking already-selected folder collapses it
        if columns[index].selectedDir == name {
            columns[index].selectedDir = nil
            columns = Array(columns.prefix(index + 1))
            kbColumn = index
            return
        }

        columns[index].selectedDir = name
        columns = Array(columns.prefix(index + 1))
        let parentPath = columns[index].path
        let newPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        kbColumn = index + 1
        kbRow = 0
        Task { await loadColumn(path: newPath, depth: index + 1) }
    }

    private func loadBackupStatuses(drive: String, directories: [DirectoryEntry]) async {
        // Fetch backup statuses with limited concurrency (4 at a time to avoid
        // overwhelming the single-threaded uvicorn backend)
        let batchSize = 4
        for batch in stride(from: 0, to: directories.count, by: batchSize) {
            let end = min(batch + batchSize, directories.count)
            let slice = directories[batch..<end]
            await withTaskGroup(of: (String, BackupStatusResponse?).self) { group in
                for dir in slice {
                    group.addTask {
                        let status = try? await APIService.shared.fetchBackupStatus(
                            drive: drive, path: dir.path
                        )
                        return (dir.path, status)
                    }
                }
                for await (path, status) in group {
                    if let status { backupCache[path] = status }
                }
            }
        }
        ViewCache.save(backupCache, key: "browserBackupCache")
    }

    private func loadColumn(path: String, depth: Int) async {
        guard let drive = selectedDrive else { return }
        if depth == 0 { isLoading = true }
        errorMessage = nil

        do {
            let response = try await APIService.shared.browseDirectory(
                drive: drive.name,
                path: path
            )

            let newCol = ColumnData(depth: depth, path: path, response: response)

            if depth == 0 {
                columns = [newCol]
                // Cache root column for instant load next time
                ViewCache.save(response, key: "browserRoot_\(drive.name)")
            } else {
                // Replace or append
                if columns.count > depth {
                    columns = Array(columns.prefix(depth)) + [newCol]
                } else {
                    columns.append(newCol)
                }
            }

            // Load backup statuses for directories in background
            Task { await loadBackupStatuses(drive: drive.name, directories: response.directories) }
        } catch {
            if depth == 0 {
                errorMessage = error.localizedDescription
            }
        }
        if depth == 0 { isLoading = false }
    }

    // MARK: - Search

    private func performSearch() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        hasSearched = true
        // Auto-wrap with wildcards if user didn't include glob characters
        let pattern = trimmed.contains("*") || trimmed.contains("?") ? trimmed : "*\(trimmed)*"
        do {
            let response = try await APIService.shared.searchFiles(
                query: pattern, drive: showAllDrives ? nil : selectedDrive?.name
            )
            searchResults = response.files
            searchTotal = response.total
        } catch {
            searchResults = []
            searchTotal = 0
        }
        isSearching = false
    }

    private func clearSearch() {
        searchQuery = ""
        searchResults = []
        searchTotal = 0
        hasSearched = false
    }

    // MARK: - Reveal in Finder

    private func revealInFinder(relativePath: String, isDirectory: Bool) {
        guard let drive = selectedDrive else { return }
        let fullPath = "\(drive.mountPath)/\(relativePath)"
        let url = URL(fileURLWithPath: fullPath)

        if FileManager.default.fileExists(atPath: fullPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Helpers

    private func formattedBrowseSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

}

#Preview {
    BrowserView()
}
