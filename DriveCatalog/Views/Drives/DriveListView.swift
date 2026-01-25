import SwiftUI

/// Row view for displaying a single drive in the list.
struct DriveRow: View {
    let drive: DriveResponse

    var body: some View {
        HStack(spacing: 12) {
            // Drive icon
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                // Drive name
                Text(drive.name)
                    .font(.headline)

                // Mount path
                Text(drive.mountPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // File count badge
            Text("\(drive.fileCount.formatted()) files")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.2))
                .clipShape(Capsule())

            // Last scanned date
            VStack(alignment: .trailing, spacing: 2) {
                Text("Last scan")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(lastScanText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var lastScanText: String {
        guard let lastScan = drive.lastScan else {
            return "Never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastScan, relativeTo: Date())
    }
}

/// Main view for displaying and managing the list of registered drives.
struct DriveListView: View {
    @State private var drives: [DriveResponse] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var showAddSheet = false
    @State private var driveToDelete: DriveResponse? = nil
    @State private var showDeleteConfirmation = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading drives...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Failed to load drives")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await loadDrives() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if drives.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No drives registered")
                        .font(.headline)
                    Text("Add a drive to start cataloging your files.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Drive", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(drives) { drive in
                        DriveRow(drive: drive)
                            .contextMenu {
                                Button(role: .destructive) {
                                    driveToDelete = drive
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    driveToDelete = drive
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Drive")
            }
            ToolbarItem {
                Button {
                    Task { await loadDrives() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .task {
            await loadDrives()
        }
        .sheet(isPresented: $showAddSheet) {
            AddDriveSheet(onAdded: loadDrives)
        }
        .alert("Delete Drive", isPresented: $showDeleteConfirmation, presenting: driveToDelete) { drive in
            Button("Cancel", role: .cancel) {
                driveToDelete = nil
            }
            Button("Delete", role: .destructive) {
                Task { await deleteDrive(drive) }
            }
        } message: { drive in
            Text("Are you sure you want to delete \"\(drive.name)\"? This will remove the drive registration and all associated file records.")
        }
    }

    private func loadDrives() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await APIService.shared.fetchDrives()
            drives = response.drives
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteDrive(_ drive: DriveResponse) async {
        do {
            try await APIService.shared.deleteDrive(name: drive.name)
            await loadDrives()
        } catch {
            errorMessage = error.localizedDescription
        }
        driveToDelete = nil
    }
}

#Preview {
    DriveListView()
}
