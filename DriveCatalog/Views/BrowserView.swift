import SwiftUI

/// File browser view with drive filtering, pagination, and file detail.
struct BrowserView: View {
    @State private var files: [FileResponse] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDrive: String? = nil
    @State private var drives: [DriveResponse] = []
    @State private var currentPage = 1
    @State private var totalFiles = 0
    @State private var selectedFile: FileResponse?
    @State private var fileToCopy: FileResponse?
    @State private var showCopySheet = false

    private let pageSize = 100

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Loading files...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Failed to load files")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadFiles() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if files.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.questionmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No files found")
                            .font(.headline)
                        Text("Try selecting a different drive or scan a drive first.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        List {
                            ForEach(files) { file in
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

                        // Pagination bar
                        Divider()
                        HStack {
                            Text("Showing \(rangeStart)-\(rangeEnd) of \(totalFiles)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("Page \(currentPage) of \(totalPages)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                currentPage -= 1
                                Task { await loadFiles() }
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(currentPage <= 1)
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                currentPage += 1
                                Task { await loadFiles() }
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(currentPage >= totalPages)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Browser")
            .toolbar {
                ToolbarItem {
                    Picker("Drive", selection: $selectedDrive) {
                        Text("All Drives").tag(nil as String?)
                        ForEach(drives) { drive in
                            Text(drive.name).tag(drive.name as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedDrive) {
                        currentPage = 1
                        Task { await loadFiles() }
                    }
                }
                ToolbarItem {
                    Button {
                        Task { await loadFiles() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
            .sheet(item: $selectedFile) { file in
                FileDetailSheet(file: file)
            }
            .sheet(isPresented: $showCopySheet) {
                if let file = fileToCopy {
                    CopySheet(sourceFile: file, onComplete: loadFiles)
                }
            }
            .task {
                await loadDrives()
                await loadFiles()
            }
        }
    }

    // MARK: - Pagination Helpers

    private var totalPages: Int {
        max(1, Int(ceil(Double(totalFiles) / Double(pageSize))))
    }

    private var rangeStart: Int {
        totalFiles == 0 ? 0 : (currentPage - 1) * pageSize + 1
    }

    private var rangeEnd: Int {
        min(currentPage * pageSize, totalFiles)
    }

    // MARK: - Data Loading

    private func loadDrives() async {
        do {
            let response = try await APIService.shared.fetchDrives()
            drives = response.drives
        } catch {
            // Non-critical — drive picker just won't populate
        }
    }

    private func loadFiles() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await APIService.shared.fetchFiles(
                drive: selectedDrive,
                page: currentPage,
                pageSize: pageSize
            )
            files = response.files
            totalFiles = response.total
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    BrowserView()
}
