import AppKit
import SwiftUI

/// Live disk space info read from the filesystem.
private struct DiskSpace {
    let totalBytes: Int64
    let freeBytes: Int64
    var usedBytes: Int64 { totalBytes - freeBytes }
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    static func read(path: String) -> DiskSpace? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let total = attrs[.systemSize] as? Int64,
              let free = attrs[.systemFreeSize] as? Int64
        else { return nil }
        return DiskSpace(totalBytes: total, freeBytes: free)
    }
}

/// Row view for displaying a single drive as an expandable card.
struct DriveCard: View {
    let drive: DriveResponse
    @Binding var expandedDriveId: Int?
    /// Bumped by parent when volumes mount/unmount — triggers status refresh.
    var refreshTrigger: Int = 0

    @State private var status: DriveStatusResponse?
    @State private var isLoadingStatus = false
    @State private var statusError: String?
    @State private var diskSpace: DiskSpace?

    // Operation tracking
    @State private var activeOperation: OperationResponse?
    @State private var activeOperationType: String?
    @State private var operationResult: OperationResult?
    @State private var currentOperationId: String?
    @State private var showClearConfirmation = false
    @State private var verificationReport: VerificationReport?

    private enum OperationResult {
        case success(String)
        case failure(String)
        case cancelled(String)
    }

    private var isExpanded: Bool { expandedDriveId == drive.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header — always visible, tap to expand
            cardHeader
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedDriveId = isExpanded ? nil : drive.id
                    }
                    if !isExpanded {
                        Task { await loadStatus() }
                    }
                }

            // Expanded detail
            if isExpanded {
                Divider()
                    .padding(.horizontal)
                expandedContent
                    .padding()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isExpanded ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .task(id: refreshTrigger) {
            diskSpace = DiskSpace.read(path: drive.mountPath)
            await loadStatus()
            // Resume polling if there's a running operation on this drive
            if activeOperation == nil {
                await resumeRunningOperation()
            }
        }
    }

    // MARK: - Card Header

    private var cardHeader: some View {
        HStack(spacing: 12) {
            // Drive icon with mounted indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Circle()
                    .fill(isMounted ? .green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(drive.name)
                        .font(.headline)

                    // Connected badge — only show when mounted (most drives are disconnected, so no label needed)
                    if isMounted {
                        Text("Connected")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }

                    if drive.fileCount > 0 {
                        Text("\(drive.fileCount.formatted()) files")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    if let status, status.folderCount > 0 {
                        Text("\(status.folderCount.formatted()) folders")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }

                // Disk space bar
                if let space = diskSpace {
                    HStack(spacing: 6) {
                        Text("\(formattedSize(space.usedBytes))/\(formattedSize(space.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.15))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.4))
                                    .frame(width: geo.size.width * CGFloat(min(space.usedPercent, 100) / 100))
                            }
                        }
                        .frame(height: 5)

                        Text("\(Int(space.usedPercent))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                } else if let used = status?.usedBytes, drive.totalBytes > 0 {
                    // Disconnected drive — show last-known usage from DB
                    let pct = Double(used) / Double(drive.totalBytes) * 100
                    HStack(spacing: 6) {
                        Text("\(formattedSize(used))/\(formattedSize(drive.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.15))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: geo.size.width * CGFloat(min(pct, 100) / 100))
                            }
                        }
                        .frame(height: 5)

                        Text("\(Int(pct))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                } else if drive.totalBytes > 0 {
                    Text(formattedSize(drive.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(drive.mountPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Scan/hash status summary
            VStack(alignment: .trailing, spacing: 3) {
                if let status {
                    HStack(spacing: 6) {
                        scanBadge(status: status)
                        hashBadge(status: status)
                    }
                    if let lastScan = status.lastScan ?? drive.lastScan {
                        Text(lastScanText(lastScan))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if drive.lastScan != nil {
                    Text("Scanned")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(lastScanText(drive.lastScan))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not scanned")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Info row
            HStack(spacing: 20) {
                Label(drive.mountPath, systemImage: "folder.fill")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let uuid = drive.uuid {
                    Label(uuid, systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Disk space detail
            if let space = diskSpace {
                HStack(spacing: 24) {
                    spaceDetail(label: "Used", bytes: space.usedBytes, color: .blue)
                    spaceDetail(label: "Free", bytes: space.freeBytes, color: .green)
                    spaceDetail(label: "Total", bytes: space.totalBytes, color: .secondary)
                }
            }

            // Drive health info
            if let status {
                driveHealthRow(status: status)
            }

            Divider()

            // Status section
            if isLoadingStatus {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading status...")
                        .foregroundStyle(.secondary)
                }
            } else if let statusError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(statusError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await loadStatus() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            } else if let status {
                HStack(spacing: 20) {
                    Label("\(status.fileCount.formatted()) files", systemImage: "doc.fill")
                        .foregroundStyle(.primary)

                    if status.videoCount > 0 {
                        Label("\(status.videoCount.formatted())", systemImage: "film.fill")
                            .foregroundStyle(.orange)
                    }

                    if status.imageCount > 0 {
                        Label("\(status.imageCount.formatted())", systemImage: "photo.fill")
                            .foregroundStyle(.blue)
                    }

                    if status.audioCount > 0 {
                        Label("\(status.audioCount.formatted())", systemImage: "waveform")
                            .foregroundStyle(.purple)
                    }
                }
                .font(.callout)

                // Hash coverage — subtle when complete, progress bar only when incomplete
                if activeOperation == nil {
                    if status.hashCoveragePercent >= 100 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.purple)
                            Text("Fully hashed")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 12) {
                            Text("\(status.hashCoveragePercent, specifier: "%.1f")% hashed")
                                .font(.callout)
                            ProgressView(value: status.hashCoveragePercent / 100)
                                .tint(.purple)
                        }
                    }
                }
            }

            Divider()

            // Operation progress
            if let operation = activeOperation {
                VStack(alignment: .leading, spacing: 6) {
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

                    // Show hash coverage inline with file count during operation
                    HStack(spacing: 8) {
                        if operation.filesTotal > 0 {
                            Text("\(operation.filesProcessed.formatted()) / \(operation.filesTotal.formatted()) files")
                        }
                        if let status {
                            Text("·")
                            Text("\(status.hashCoveragePercent, specifier: "%.1f")% hashed")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }

            // Operation result
            if let result = operationResult {
                HStack {
                    switch result {
                    case .success(let msg):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(msg).foregroundStyle(.green)
                    case .failure(let msg):
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(msg).foregroundStyle(.red)
                    case .cancelled(let msg):
                        Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
                        Text(msg).foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }

            // Verification report
            if let report = verificationReport {
                verificationReportView(report)
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
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await triggerScan() }
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            if let status, status.hashCoveragePercent > 0 && status.hashCoveragePercent < 100 {
                                Text("Continue Hashing")
                            } else {
                                Text("Scan & Hash")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isMounted)

                    if drive.fileCount > 0 {
                        Button {
                            Task { await triggerVerifyIntegrity() }
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.shield")
                                Text("Verify")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!isMounted)

                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Clear Scan Data")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .alert("Clear Scan Data", isPresented: $showClearConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    Task { await clearScanData() }
                }
            } message: {
                Text("This will delete all \(drive.fileCount.formatted()) catalogued files and hashes for \"\(drive.name)\". The drive registration will be kept so you can re-scan.")
            }

            if !isMounted {
                Text("Drive must be mounted to perform actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var isMounted: Bool {
        status?.mounted ?? (diskSpace != nil)
    }

    private func spaceDetail(label: String, bytes: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(formattedSize(bytes))
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(color)
        }
    }

    private func spaceBarColor(_ percent: Double) -> Color {
        if percent > 90 { return .red }
        if percent > 75 { return .orange }
        return .blue
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    @ViewBuilder
    private func scanBadge(status: DriveStatusResponse) -> some View {
        if status.lastScan != nil {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Scanned")
            }
            .font(.caption)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "circle")
                    .foregroundStyle(.orange)
                Text("Not scanned")
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func hashBadge(status: DriveStatusResponse) -> some View {
        let pct = status.hashCoveragePercent
        HStack(spacing: 3) {
            if pct >= 100 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Hashed")
            } else if pct > 0 {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.orange)
                Text("\(Int(pct))% hashed")
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text("Not hashed")
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func driveHealthRow(status: DriveStatusResponse) -> some View {
        let hasSmart = status.smartStatus != nil && status.smartStatus != "Not Supported"
        let hasMediaType = status.mediaType != nil
        let hasAge = status.firstSeen != nil

        if hasSmart || hasMediaType || hasAge {
            HStack(spacing: 16) {
                // SMART status
                if let smart = status.smartStatus, smart != "Not Supported" {
                    HStack(spacing: 4) {
                        Image(systemName: smart == "Verified"
                              ? "heart.fill" : "heart.slash.fill")
                            .foregroundStyle(smart == "Verified" ? .green : .red)
                        Text("SMART: \(smart)")
                    }
                    .font(.caption)
                }

                // Media type
                if let mediaType = status.mediaType {
                    HStack(spacing: 4) {
                        Image(systemName: mediaType == "SSD"
                              ? "bolt.fill" : "disk.2.fill")
                            .foregroundStyle(mediaType == "SSD" ? .blue : .orange)
                        Text(mediaType)
                    }
                    .font(.caption)
                }

                // Protocol
                if let proto = status.deviceProtocol {
                    HStack(spacing: 4) {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(.secondary)
                        Text(proto)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Age (time since first_seen)
                if let firstSeen = status.firstSeen {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                        Text("Registered \(ageString(firstSeen))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func ageString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func lastScanText(_ date: Date?) -> String {
        guard let date else { return "Never scanned" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Verification Report View

    @ViewBuilder
    private func verificationReportView(_ report: VerificationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: report.allPass ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(report.allPass ? .green : .red)
                Text(report.allPass ? "All checks passed" : "Issues found")
                    .font(.headline)
                    .foregroundStyle(report.allPass ? .green : .red)
                Spacer()
                Button {
                    verificationReport = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Scan check
            verifyCheckRow(
                title: "Scan Integrity",
                pass: report.scanPass,
                details: [
                    ("Files on disk", "\(report.filesOnDisk.formatted())"),
                    ("Files in database", "\(report.filesInDb.formatted())"),
                    ("Missing from DB", "\(report.missingFromDb)"),
                    ("Stale in DB", "\(report.staleInDb)"),
                    ("Size mismatches", "\(report.sizeMismatches)"),
                ]
            )

            // Hash check
            verifyCheckRow(
                title: "Hash Integrity",
                pass: report.hashPass,
                details: [
                    ("Hashes verified", "\(report.hashesChecked.formatted())"),
                    ("Matched", "\(report.hashesMatched.formatted())"),
                    ("Mismatched", "\(report.hashesMismatched)"),
                    ("Read errors", "\(report.hashReadErrors)"),
                ]
            )

            // Duplicate check
            verifyCheckRow(
                title: "Duplicate Integrity",
                pass: report.duplicatePass,
                details: [
                    ("Clusters checked", "\(report.clustersChecked.formatted())"),
                    ("Valid", "\(report.clustersValid.formatted())"),
                    ("Invalid", "\(report.clustersInvalid)"),
                ]
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(report.allPass ? Color.green.opacity(0.05) : Color.red.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(report.allPass ? Color.green.opacity(0.2) : Color.red.opacity(0.2), lineWidth: 1)
        )
    }

    private func verifyCheckRow(title: String, pass: Bool, details: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(pass ? .green : .red)
                    .font(.callout)
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
            }

            HStack(spacing: 16) {
                ForEach(details, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(value)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(value != "0" && !["Matched", "Hashes verified", "Valid", "Clusters checked", "Files on disk", "Files in database"].contains(label) ? .red : .secondary)
                    }
                }
            }
            .padding(.leading, 22)
        }
    }

    // MARK: - Data Loading

    private func loadStatus() async {
        isLoadingStatus = true
        statusError = nil
        do {
            status = try await APIService.shared.fetchDriveStatus(name: drive.name)
            // Refresh disk space too
            diskSpace = DiskSpace.read(path: drive.mountPath)
        } catch {
            statusError = error.localizedDescription
        }
        isLoadingStatus = false
    }

    // MARK: - Operations

    /// Check backend for any running operation on this drive and resume polling.
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
                if running.type == "verify-integrity" {
                    await pollVerification(id: running.id)
                } else {
                    await pollOperation(id: running.id)
                }
            }
        } catch {
            // Silently ignore — no running operation to resume
        }
    }

    private func triggerScan() async {
        operationResult = nil
        activeOperationType = "scan"
        do {
            let startResponse = try await APIService.shared.triggerAutoScan(driveName: drive.name)
            guard let opId = startResponse["operation_id"] as? String else {
                activeOperationType = nil
                operationResult = .failure("Unexpected response from server")
                clearResultAfterDelay()
                return
            }
            currentOperationId = opId
            await pollOperation(id: opId)
        } catch {
            activeOperationType = nil
            currentOperationId = nil
            operationResult = .failure("Scan failed: \(error.localizedDescription)")
            clearResultAfterDelay()
        }
    }

    private func triggerVerifyIntegrity() async {
        operationResult = nil
        verificationReport = nil
        activeOperationType = "verify-integrity"
        do {
            let startResponse = try await APIService.shared.triggerVerifyIntegrity(driveName: drive.name)
            currentOperationId = startResponse.operationId
            await pollVerification(id: startResponse.operationId)
        } catch {
            activeOperationType = nil
            currentOperationId = nil
            operationResult = .failure("Verification failed: \(error.localizedDescription)")
            clearResultAfterDelay()
        }
    }

    private func clearScanData() async {
        do {
            try await APIService.shared.clearScanData(driveName: drive.name)
            operationResult = .success("Scan data cleared")
            clearResultAfterDelay()
            await loadStatus()
        } catch {
            operationResult = .failure("Failed to clear: \(error.localizedDescription)")
            clearResultAfterDelay()
        }
    }

    private func cancelCurrentOperation() async {
        guard let opId = currentOperationId else { return }
        do {
            try await APIService.shared.cancelOperation(id: opId)
        } catch {
            // Polling handles final state
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
                    let message = operation.isUpToDate
                        ? "Drive is up to date — no changes detected"
                        : "Scan & hash completed"
                    operationResult = .success(message)
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

    private func pollVerification(id: String) async {
        while true {
            do {
                let operation = try await APIService.shared.fetchOperation(id: id)
                activeOperation = operation

                if operation.status == "completed" {
                    // Fetch the raw result to parse verification report
                    let rawResult = try await APIService.shared.fetchOperationResult(id: id)
                    verificationReport = VerificationReport.from(dict: rawResult)

                    activeOperation = nil
                    activeOperationType = nil
                    currentOperationId = nil

                    if verificationReport?.allPass == true {
                        operationResult = .success("Verification passed")
                    } else {
                        operationResult = .failure("Verification found issues")
                    }
                    break
                } else if operation.status == "failed" {
                    activeOperation = nil
                    activeOperationType = nil
                    currentOperationId = nil
                    operationResult = .failure(operation.error ?? "Verification failed")
                    clearResultAfterDelay()
                    break
                } else if operation.status == "cancelled" {
                    activeOperation = nil
                    activeOperationType = nil
                    currentOperationId = nil
                    operationResult = .cancelled("Verification cancelled")
                    clearResultAfterDelay()
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
        case "pending": return "Preparing..."
        case "running":
            switch operation.type {
            case "hash": return "Hashing files..."
            case "verify-integrity": return "Verifying integrity..."
            case "smart-scan": return "Smart scanning..."
            default: return "Scanning files..."
            }
        default: return operation.status.capitalized
        }
    }

    private func formatETA(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s remaining"
        } else if seconds < 3600 {
            return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s remaining"
        } else {
            return "\(Int(seconds) / 3600)h \((Int(seconds) % 3600) / 60)m remaining"
        }
    }

    private func clearResultAfterDelay() {
        Task {
            try await Task.sleep(for: .seconds(5))
            operationResult = nil
        }
    }
}

/// Main view for displaying and managing the list of registered drives.
struct DriveListView: View {
    @EnvironmentObject private var backend: BackendService
    @State private var drives: [DriveResponse] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showAddSheet = false
    @State private var showConsolidationWizard = false
    @State private var driveToDelete: DriveResponse?
    @State private var showDeleteConfirmation = false
    @State private var expandedDriveId: Int?
    /// Incremented on volume mount/unmount to trigger card refresh.
    @State private var volumeRefreshTrigger = 0

    var body: some View {
        Group {
            if !backend.isRunning {
                startupView
            } else if isLoading {
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
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(drives) { drive in
                            DriveCard(drive: drive, expandedDriveId: $expandedDriveId, refreshTrigger: volumeRefreshTrigger)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        driveToDelete = drive
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showConsolidationWizard = true
                } label: {
                    Image(systemName: "arrow.triangle.merge")
                }
                .help("Consolidate Drives")
            }
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
        .task(id: backend.isRunning) {
            if backend.isRunning {
                await loadDrives()
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { notification in
            volumeRefreshTrigger += 1
            // Recognize drive by UUID (handles renames) then trigger smart auto-scan
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                Task {
                    if let driveName = try? await APIService.shared.recognizeDrive(mountPath: volumeURL.path) {
                        // Drive recognized — refresh list (name/path may have updated) and auto-scan
                        await loadDrives()
                        _ = try? await APIService.shared.triggerAutoScan(driveName: driveName)
                    }
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumeRefreshTrigger += 1
        }
        .sheet(isPresented: $showAddSheet) {
            AddDriveSheet(onAdded: loadDrives)
        }
        .sheet(isPresented: $showConsolidationWizard) {
            ConsolidationWizardView()
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

    private var startupView: some View {
        VStack(spacing: 24) {
            ZStack {
                // Pulsing outer ring
                Circle()
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                    .frame(width: 80, height: 80)

                // Spinning arc
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(startupRotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            startupRotation = 360
                        }
                    }

                // Drive icon
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 8) {
                Text("Starting DriveCatalog")
                    .font(.headline)
                Text("Launching the catalog engine...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let error = backend.startupError {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        backend.stop()
                        backend.start()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var startupRotation: Double = 0

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
