import SwiftUI

/// Detailed view for a selected drive showing status and actions.
struct DriveDetailView: View {
    let drive: DriveResponse

    @State private var status: DriveStatusResponse?
    @State private var isLoadingStatus = true
    @State private var statusError: String?

    // Operation tracking
    @State private var activeOperation: OperationResponse?
    @State private var activeOperationType: String?  // "scan" or "hash"
    @State private var operationResult: OperationResult?

    /// Tracks the result of a completed operation for brief display.
    private enum OperationResult {
        case success(String)
        case failure(String)
    }

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

                // Actions Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        // Active operation progress
                        if let operation = activeOperation {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(operationStatusText(operation))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let progress = operation.progressPercent {
                                        Text("\(Int(progress))%")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let progress = operation.progressPercent {
                                    ProgressView(value: progress / 100)
                                        .tint(.blue)
                                }
                            }
                        }

                        // Operation result message
                        if let result = operationResult {
                            HStack {
                                switch result {
                                case .success(let message):
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(message)
                                        .foregroundStyle(.green)
                                case .failure(let message):
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(message)
                                        .foregroundStyle(.red)
                                }
                            }
                            .font(.callout)
                        }

                        // Action buttons
                        HStack(spacing: 12) {
                            Button {
                                Task { await triggerScan() }
                            } label: {
                                HStack {
                                    if activeOperationType == "scan" {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "magnifyingglass")
                                    }
                                    Text("Scan Drive")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isMounted || activeOperation != nil)

                            Button {
                                Task { await triggerHash() }
                            } label: {
                                HStack {
                                    if activeOperationType == "hash" {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "number")
                                    }
                                    Text("Compute Hashes")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!isMounted || activeOperation != nil)
                        }

                        if !isMounted {
                            Text("Drive must be mounted to perform actions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Actions", systemImage: "play.circle.fill")
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

    /// Whether the drive is currently mounted.
    private var isMounted: Bool {
        status?.mounted ?? false
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

    // MARK: - Operations

    private func triggerScan() async {
        operationResult = nil
        activeOperationType = "scan"

        do {
            let startResponse = try await APIService.shared.triggerScan(driveName: drive.name)
            await pollOperation(id: startResponse.operationId, type: "scan")
        } catch {
            activeOperationType = nil
            operationResult = .failure("Scan failed: \(error.localizedDescription)")
            clearResultAfterDelay()
        }
    }

    private func triggerHash() async {
        operationResult = nil
        activeOperationType = "hash"

        do {
            let startResponse = try await APIService.shared.triggerHash(driveName: drive.name)
            await pollOperation(id: startResponse.operationId, type: "hash")
        } catch {
            activeOperationType = nil
            operationResult = .failure("Hash failed: \(error.localizedDescription)")
            clearResultAfterDelay()
        }
    }

    private func pollOperation(id: String, type: String) async {
        // Poll every 2 seconds until complete
        while true {
            do {
                let operation = try await APIService.shared.fetchOperation(id: id)
                activeOperation = operation

                if operation.status == "completed" {
                    // Success
                    activeOperation = nil
                    activeOperationType = nil
                    operationResult = .success("\(type.capitalized) completed successfully")
                    clearResultAfterDelay()
                    // Refresh status to show updated file count/hash coverage
                    await loadStatus()
                    break
                } else if operation.status == "failed" {
                    // Failure
                    activeOperation = nil
                    activeOperationType = nil
                    operationResult = .failure(operation.error ?? "\(type.capitalized) failed")
                    clearResultAfterDelay()
                    break
                }

                // Still running, wait and poll again
                try await Task.sleep(for: .seconds(2))
            } catch {
                // Polling error
                activeOperation = nil
                activeOperationType = nil
                operationResult = .failure("Lost connection: \(error.localizedDescription)")
                clearResultAfterDelay()
                break
            }
        }
    }

    private func operationStatusText(_ operation: OperationResponse) -> String {
        switch operation.status {
        case "pending":
            return "Waiting to start..."
        case "running":
            return "\(operation.type.capitalized) in progress..."
        default:
            return operation.status.capitalized
        }
    }

    private func clearResultAfterDelay() {
        Task {
            try await Task.sleep(for: .seconds(5))
            operationResult = nil
        }
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
