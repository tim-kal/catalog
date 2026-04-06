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
        case cancelled(String)
    }

    @State private var currentOperationId: String?

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
                            HStack(spacing: 12) {
                                if status.videoCount > 0 {
                                    Label("\(status.videoCount.formatted()) videos", systemImage: "film.fill")
                                        .foregroundStyle(.orange)
                                }
                                if status.imageCount > 0 {
                                    Label("\(status.imageCount.formatted()) images", systemImage: "photo.fill")
                                        .foregroundStyle(.blue)
                                }
                                if status.audioCount > 0 {
                                    Label("\(status.audioCount.formatted()) audio", systemImage: "waveform")
                                        .foregroundStyle(.purple)
                                }
                                if status.videoCount == 0 && status.imageCount == 0 && status.audioCount == 0 {
                                    Text("No media files")
                                        .foregroundStyle(.secondary)
                                }
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

                                    if let eta = operation.etaSeconds, eta > 0 {
                                        Text(formatETA(eta))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let progress = operation.progressPercent {
                                        Text("\(Int(progress))%")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if let progress = operation.progressPercent {
                                    ProgressView(value: progress / 100)
                                        .tint(.blue)
                                }

                                if operation.filesTotal > 0 {
                                    Text("\(operation.filesProcessed.formatted()) / \(operation.filesTotal.formatted()) files")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
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
                                case .cancelled(let message):
                                    Image(systemName: "stop.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text(message)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.callout)
                        }

                        // Action buttons
                        HStack(spacing: 12) {
                            if activeOperation != nil {
                                Button(role: .destructive) {
                                    Task { await cancelCurrentOperation() }
                                } label: {
                                    HStack {
                                        Image(systemName: "stop.fill")
                                        Text("Cancel")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button {
                                    Task { await triggerScan() }
                                } label: {
                                    HStack {
                                        Image(systemName: "magnifyingglass")
                                        Text("Scan & Hash")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!isMounted)
                            }
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
            if activeOperation == nil {
                await resumeRunningOperation()
            }
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

    private func resumeRunningOperation() async {
        do {
            let opList = try await APIService.shared.fetchOperations()
            if let running = opList.operations.first(where: {
                $0.driveName == drive.name &&
                ($0.status == "running" || $0.status == "pending")
            }) {
                currentOperationId = running.id
                activeOperationType = running.type
                activeOperation = running
                await pollOperation(id: running.id)
            }
        } catch {
            // Silently ignore
        }
    }

    private func triggerScan() async {
        operationResult = nil
        activeOperationType = "scan"

        do {
            let startResponse = try await APIService.shared.triggerScan(driveName: drive.name)
            currentOperationId = startResponse.operationId
            await pollOperation(id: startResponse.operationId)
        } catch {
            activeOperationType = nil
            currentOperationId = nil
            operationResult = .failure("Scan failed: \(error.localizedDescription)")
            clearResultAfterDelay()
        }
    }

    private func cancelCurrentOperation() async {
        guard let opId = currentOperationId else { return }
        do {
            try await APIService.shared.cancelOperation(id: opId)
        } catch {
            // Cancellation request failed — polling will handle final state
        }
    }

    private func pollOperation(id: String) async {
        while true {
            do {
                let operation = try await APIService.shared.fetchOperation(id: id)
                activeOperation = operation

                if operation.status == "completed" {
                    activeOperation = nil
                    activeOperationType = nil
                    currentOperationId = nil
                    operationResult = .success("Scan & hash completed")
                    clearResultAfterDelay()
                    await loadStatus()
                    break
                } else if operation.status == "failed" {
                    activeOperation = nil
                    activeOperationType = nil
                    currentOperationId = nil
                    operationResult = .failure(operation.error ?? "Operation failed")
                    clearResultAfterDelay()
                    break
                } else if operation.status == "cancelled" {
                    activeOperation = nil
                    activeOperationType = nil
                    currentOperationId = nil
                    operationResult = .cancelled("Cancelled — progress saved, resume anytime")
                    clearResultAfterDelay()
                    await loadStatus()
                    break
                }

                try await Task.sleep(for: .seconds(1))
            } catch {
                activeOperation = nil
                activeOperationType = nil
                currentOperationId = nil
                operationResult = .failure("Lost connection: \(error.localizedDescription)")
                clearResultAfterDelay()
                break
            }
        }
    }

    private func operationStatusText(_ operation: OperationResponse) -> String {
        switch operation.status {
        case "pending":
            return "Counting files..."
        case "running":
            return "Scanning & hashing..."
        default:
            return operation.status.capitalized
        }
    }

    private func formatETA(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s remaining"
        } else if seconds < 3600 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s remaining"
        } else {
            let hrs = Int(seconds) / 3600
            let mins = (Int(seconds) % 3600) / 60
            return "\(hrs)h \(mins)m remaining"
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
            usedBytes: 250_000_000_000,
            lastScan: Date().addingTimeInterval(-3600),
            fileCount: 12345,
            diskUuid: nil,
            deviceSerial: nil,
            fsFingerprint: nil
        ))
    }
}
