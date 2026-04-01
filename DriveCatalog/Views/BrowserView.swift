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
                    if showAllDrives {
                        AllDrivesView()
                    } else {
                        toolBar
                        Divider()
                        if hasSearched {
                            searchContent
                        } else {
                            columnContent
                        }
                    }
                }
            }
            .navigationTitle("Browse")
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
                        if let sel = selectedDrive {
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

    private var toolBar: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    selectedDrive.map { "Search \($0.name)..." } ?? "Search all drives...",
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
                        if sortField == field {
                            Image(systemName: sortDirection == .ascending
                                  ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
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
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { index, col in
                            columnView(col: col, index: index)
                                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
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
                    if backup.backupDrives.isEmpty {
                        if backup.hashedFiles > 0 {
                            // Hashed but no copies on other drives
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .help("No backups — only on this drive")
                        }
                    } else {
                        backupBadge(backup)
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
                        if backup.backupDrives.isEmpty {
                            if backup.hashedFiles == 0 {
                                Label("Not hashed yet", systemImage: "questionmark.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Label("No backups", systemImage: "exclamationmark.shield.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Text("Copies found:")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            ForEach(backup.backupDrives, id: \.driveName) { bd in
                                HStack(spacing: 4) {
                                    Image(systemName: bd.percentCoverage >= 100
                                          ? "checkmark.circle.fill" : "externaldrive.fill")
                                        .foregroundStyle(bd.percentCoverage >= 100 ? .green : .orange)
                                    Text("\(bd.driveName) – \(bd.fileCount) of \(backup.totalFiles) files\(bd.totalBytes.map { " – \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "")")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
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
                .help("Exists on \(copies) drives")
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
            selectedFile = file
        }
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
        for dir in directories {
            if let status = try? await APIService.shared.fetchBackupStatus(
                drive: drive, path: dir.path
            ) {
                backupCache[dir.path] = status
            }
        }
        // Persist to disk for instant display next time
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
        do {
            let response = try await APIService.shared.searchFiles(
                query: trimmed, drive: selectedDrive?.name
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

    @ViewBuilder
    private func backupBadge(_ backup: BackupStatusResponse) -> some View {
        BackupBadgeView(backup: backup)
    }

}

/// Backup badge with hover popover — needs its own View for @State.
private struct BackupBadgeView: View {
    let backup: BackupStatusResponse
    @Environment(\.activeTab) private var activeTab
    @State private var isHovered = false

    private var allFull: Bool {
        backup.backupDrives.allSatisfy { $0.percentCoverage >= 100 }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: allFull ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .font(.caption2)
            Text("\(backup.backupDrives.count)")
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(allFull ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
        .foregroundStyle(allFull ? .green : .orange)
        .clipShape(Capsule())
        .onHover { hovering in
            if activeTab == .browser { isHovered = hovering }
        }
        .popover(isPresented: $isHovered, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(.blue)
                    Text("Backup Status")
                        .font(.callout)
                        .fontWeight(.medium)
                }

                Divider()

                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("\(backup.totalFiles)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Total files")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading) {
                        Text("\(backup.hashedFiles)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Hashed")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading) {
                        Text("\(backup.backedUpFiles)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Backed up")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !backup.backupDrives.isEmpty {
                    Divider()
                    Text("Copies on:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(backup.backupDrives, id: \.driveName) { bd in
                        HStack(spacing: 6) {
                            Image(systemName: "externaldrive.fill")
                                .font(.caption)
                                .foregroundStyle(bd.percentCoverage >= 100 ? .green : .orange)
                            Text(bd.driveName)
                                .font(.callout)
                            Spacer()
                            Text("\(bd.fileCount) files\(bd.totalBytes.map { " – \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(Int(bd.percentCoverage))%")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(bd.percentCoverage >= 100 ? .green : .orange)
                        }
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 220)
        }
    }
}

#Preview {
    BrowserView()
}
