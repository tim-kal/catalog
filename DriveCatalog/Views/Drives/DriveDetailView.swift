import SwiftUI

/// Detailed view for a selected drive showing status and actions.
struct DriveDetailView: View {
    let drive: DriveResponse

    @State private var status: DriveStatusResponse?
    @State private var isLoadingStatus = true
    @State private var statusError: String?
    @State private var activeOperation: OperationResponse?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Drive Info Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        // Name
                        Text(drive.name)
                            .font(.title)
                            .fontWeight(.bold)

                        // Mount path
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                            Text(drive.mountPath)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        // Total size
                        HStack {
                            Image(systemName: "internaldrive.fill")
                                .foregroundStyle(.secondary)
                            Text(formattedSize(drive.totalBytes))
                                .foregroundStyle(.secondary)
                        }

                        // UUID (if available)
                        if let uuid = drive.uuid {
                            HStack {
                                Image(systemName: "number")
                                    .foregroundStyle(.secondary)
                                Text(uuid)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Drive Info", systemImage: "info.circle")
                }

                // Status Section
                GroupBox {
                    if isLoadingStatus {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading status...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else if let statusError {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(statusError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Retry") {
                                Task { await loadStatus() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else if let status {
                        VStack(alignment: .leading, spacing: 12) {
                            // Mounted indicator
                            HStack {
                                Circle()
                                    .fill(status.mounted ? .green : .red)
                                    .frame(width: 10, height: 10)
                                Text(status.mounted ? "Mounted" : "Not Mounted")
                                    .foregroundStyle(status.mounted ? .primary : .secondary)
                            }

                            Divider()

                            // File count
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.blue)
                                Text("\(status.fileCount.formatted()) files catalogued")
                            }

                            // Hash coverage
                            HStack(spacing: 12) {
                                Image(systemName: "number.circle.fill")
                                    .foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(status.hashCoveragePercent, specifier: "%.1f")% hashed")
                                    ProgressView(value: status.hashCoveragePercent / 100)
                                        .tint(.purple)
                                }
                            }

                            // Media files
                            HStack {
                                Image(systemName: "film.fill")
                                    .foregroundStyle(.orange)
                                Text("\(status.mediaCount.formatted()) media files")
                            }

                            Divider()

                            // Last scanned
                            HStack {
                                Image(systemName: "clock.fill")
                                    .foregroundStyle(.secondary)
                                Text("Last scanned: \(lastScanText(status.lastScan))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } label: {
                    HStack {
                        Label("Status", systemImage: "chart.bar.fill")
                        Spacer()
                        Button {
                            Task { await loadStatus() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoadingStatus)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .navigationTitle(drive.name)
        .task {
            await loadStatus()
        }
    }

    // MARK: - Helpers

    private func loadStatus() async {
        isLoadingStatus = true
        statusError = nil
        do {
            status = try await APIService.shared.fetchDriveStatus(name: drive.name)
        } catch {
            statusError = error.localizedDescription
        }
        isLoadingStatus = false
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func lastScanText(_ date: Date?) -> String {
        guard let date else {
            return "Never scanned"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    NavigationStack {
        DriveDetailView(drive: DriveResponse(
            id: 1,
            name: "TestDrive",
            uuid: "ABC-123-DEF",
            mountPath: "/Volumes/TestDrive",
            totalBytes: 500_000_000_000,
            lastScan: Date().addingTimeInterval(-3600),
            fileCount: 12345
        ))
    }
}
