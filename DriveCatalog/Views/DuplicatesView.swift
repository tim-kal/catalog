import SwiftUI

/// Dashboard showing duplicate file statistics and expandable cluster list.
struct DuplicatesView: View {
    @State private var duplicateData: DuplicateListResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var sortBy: String = "reclaimable"

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Loading duplicates...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Failed to load duplicates")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadDuplicates() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if let data = duplicateData {
                    if data.clusters.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.green)
                            Text("No duplicates found")
                                .font(.headline)
                            Text("Run hashing on your drives to detect duplicates.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                DuplicateStatsHeader(stats: data.stats)

                                List {
                                    ForEach(data.clusters) { cluster in
                                        DuplicateClusterRow(cluster: cluster)
                                    }
                                }
                                .listStyle(.inset)
                                .frame(minHeight: 400)
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("Duplicates")
            .toolbar {
                ToolbarItem {
                    Picker("Sort", selection: $sortBy) {
                        Text("Most Reclaimable").tag("reclaimable")
                        Text("Most Copies").tag("count")
                        Text("Largest Files").tag("size")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: sortBy) {
                        Task { await loadDuplicates() }
                    }
                }
                ToolbarItem {
                    Button {
                        Task { await loadDuplicates() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
            .task {
                await loadDuplicates()
            }
        }
    }

    private func loadDuplicates() async {
        isLoading = true
        errorMessage = nil
        do {
            duplicateData = try await APIService.shared.fetchDuplicates(sortBy: sortBy)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    DuplicatesView()
}
