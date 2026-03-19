import SwiftUI

/// Search interface with glob pattern search, optional filters, and results list.
struct SearchView: View {
    @State private var query: String = ""
    @State private var results: [SearchFile] = []
    @State private var totalResults = 0
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false

    // Filters
    @State private var driveFilter: String? = nil
    @State private var extensionFilter: String = ""
    @State private var minSizeFilter: String = ""
    @State private var maxSizeFilter: String = ""
    @State private var showFilters = false
    @State private var drives: [DriveResponse] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search pattern (e.g. *.mp4, *vacation*)", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await performSearch() } }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            results = []
                            hasSearched = false
                            totalResults = 0
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Search") {
                        Task { await performSearch() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(query.isEmpty)
                }
                .padding()

                // Filter toggle
                HStack {
                    Button {
                        withAnimation { showFilters.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text("Filters")
                            Image(systemName: showFilters ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal)

                // Filter section
                if showFilters {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Drive:")
                                    .frame(width: 70, alignment: .trailing)
                                Picker("Drive", selection: $driveFilter) {
                                    Text("All Drives").tag(nil as String?)
                                    ForEach(drives) { drive in
                                        Text(drive.name).tag(drive.name as String?)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                            HStack {
                                Text("Extension:")
                                    .frame(width: 70, alignment: .trailing)
                                TextField("e.g. mp4", text: $extensionFilter)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 150)
                            }
                            HStack {
                                Text("Size:")
                                    .frame(width: 70, alignment: .trailing)
                                TextField("Min bytes", text: $minSizeFilter)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                                Text("to")
                                TextField("Max bytes", text: $maxSizeFilter)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }

                Divider()
                    .padding(.top, 8)

                // Results area
                Group {
                    if isSearching {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Searching...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.orange)
                            Text("Search failed")
                                .font(.headline)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Retry") {
                                Task { await performSearch() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    } else if !hasSearched {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Enter a search pattern to find files across drives")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if results.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.questionmark")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("No files matching '\(query)'")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(totalResults) results for '\(query)'")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .padding(.vertical, 8)

                            List {
                                ForEach(results) { file in
                                    SearchResultRow(file: file)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .task {
                await loadDrives()
            }
        }
    }

    // MARK: - Data Loading

    private func loadDrives() async {
        do {
            let response = try await APIService.shared.fetchDrives()
            drives = response.drives
        } catch {
            // Non-critical
        }
    }

    private func performSearch() async {
        guard !query.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        hasSearched = true

        let minSize = Int(minSizeFilter)
        let maxSize = Int(maxSizeFilter)
        let ext = extensionFilter.isEmpty ? nil : extensionFilter

        do {
            let response = try await APIService.shared.searchFiles(
                query: query,
                drive: driveFilter,
                minSize: minSize,
                maxSize: maxSize,
                extension: ext
            )
            results = response.files
            totalResults = response.total
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }
}

#Preview {
    SearchView()
}
