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
    var isExpanded: Bool
    var onToggle: () -> Void
    /// Bumped by parent when volumes mount/unmount — triggers status refresh.
    var refreshTrigger: Int = 0
    /// When this drive was last connected (this session).
    var lastConnected: Date? = nil
    /// When this drive was last quick-checked, and whether it passed.
    var lastQuickCheckDate: Date? = nil
    var lastQuickCheckPassed: Bool? = nil

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
    @State private var isUnmounting = false
    @State private var unmountSuccess = false

    // Change detection
    @State private var changeReport: ChangeReport?
    @State private var isDiffing = false
    @State private var showChangeDetails = false
    @State private var diffConfirmedNoChanges = false

    /// Parsed change report from the diff endpoint.
    struct ChangeReport {
        let addedCount: Int
        let deletedCount: Int
        let modifiedCount: Int
        let movedCount: Int
        let unchangedCount: Int
        let bytesAdded: Int64
        let bytesDeleted: Int64
        let netBytes: Int64
        let addedFiles: [String]  // up to 200 paths
        let deletedFiles: [String]
        let modifiedFiles: [String]
        let movedFiles: [(path: String, from: String)]

        var totalChanges: Int { addedCount + deletedCount + modifiedCount + movedCount }
        var hasChanges: Bool { totalChanges > 0 }

        static func from(dict: [String: Any]) -> ChangeReport? {
            guard let summary = dict["summary"] as? [String: Any] else { return nil }
            let details = dict  // top-level has added/deleted/modified/moved arrays

            func paths(key: String) -> [String] {
                (details[key] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
            }

            let movedEntries: [(String, String)] = (details["moved"] as? [[String: Any]])?.compactMap { entry in
                guard let path = entry["path"] as? String,
                      let from = entry["moved_from"] as? String else { return nil }
                return (path, from)
            } ?? []

            return ChangeReport(
                addedCount: summary["added_count"] as? Int ?? 0,
                deletedCount: summary["deleted_count"] as? Int ?? 0,
                modifiedCount: summary["modified_count"] as? Int ?? 0,
                movedCount: summary["moved_count"] as? Int ?? 0,
                unchangedCount: summary["unchanged_count"] as? Int ?? 0,
                bytesAdded: Int64(summary["bytes_added"] as? Int ?? 0),
                bytesDeleted: Int64(summary["bytes_deleted"] as? Int ?? 0),
                netBytes: Int64(summary["net_bytes"] as? Int ?? 0),
                addedFiles: paths(key: "added"),
                deletedFiles: paths(key: "deleted"),
                modifiedFiles: paths(key: "modified"),
                movedFiles: movedEntries
            )
        }
    }

    private enum OperationResult {
        case success(String)
        case failure(String)
        case cancelled(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header — always visible, tap to expand
            cardHeader
                .contentShape(Rectangle())
                .onTapGesture {
                    let wasExpanded = isExpanded
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        onToggle()
                    }
                    if !wasExpanded {
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
            await loadStatus(force: refreshTrigger > 0)
            if activeOperation == nil {
                await resumeRunningOperation()
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            // Auto-trigger diff when expanding a drive with detected changes
            if expanded && lastQuickCheckPassed == false && changeReport == nil && !isDiffing {
                Task { await runDiff() }
            }
        }
    }

    // MARK: - Card Header

    private var cardHeader: some View {
        HStack(spacing: 10) {
            // Drive icon with mounted indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "externaldrive.fill")
                    .font(.body)
                    .foregroundStyle(.blue)
                Circle()
                    .fill(isMounted ? .green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: 2)
            }

            // Drive name
            Text(drive.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)

            // Total capacity
            if let space = diskSpace {
                Text(formattedSize(space.totalBytes))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            } else if drive.totalBytes > 0 {
                Text(formattedSize(drive.totalBytes))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

            // Compact usage bar
            if let space = diskSpace {
                compactSpaceBar(
                    used: space.usedBytes, total: space.totalBytes,
                    percent: space.usedPercent, live: true
                )
            } else if let used = status?.usedBytes, drive.totalBytes > 0 {
                compactSpaceBar(
                    used: used, total: drive.totalBytes,
                    percent: Double(used) / Double(drive.totalBytes) * 100, live: false
                )
            }

            Spacer()

            // Scan/hash status — compact inline
            if let status {
                statusIcons(status: status)
                if let lastScan = status.lastScan ?? drive.lastScan {
                    Text(lastScanText(lastScan))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if drive.lastScan != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(lastScanText(drive.lastScan))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Not scanned")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Compact space bar that fits in a single row.
    private func compactSpaceBar(used: Int64, total: Int64, percent: Double, live: Bool) -> some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(spaceBarColor(percent).opacity(live ? 0.6 : 0.35))
                        .frame(width: geo.size.width * CGFloat(min(percent, 100) / 100))
                }
            }
            .frame(width: 40, height: 4)

            Text("\(Int(percent))%")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()

            Text(formattedSize(total - used) + " free")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    /// Status icons: scan + hash individually, or single green check when both complete.
    /// While an operation is running, icons reflect the in-progress state, not stale DB data.
    @ViewBuilder
    private func statusIcons(status: DriveStatusResponse) -> some View {
        let scanned = status.lastScan != nil
        let isHashing = activeOperation != nil && (activeOperationType == "hash" || activeOperationType == "smart-scan")
        let isScanning = activeOperation != nil && (activeOperationType == "scan" || activeOperationType == "smart-scan")
        let fullyHashed = status.hashCoveragePercent >= 100 && !isHashing

        if scanned && fullyHashed && !isScanning {
            // Both complete — single green checkmark
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .help("Scanned & fully hashed")
        } else {
            HStack(spacing: 4) {
                // Scan icon — viewfinder
                Image(systemName: "viewfinder")
                    .font(.caption2)
                    .foregroundStyle(
                        isScanning ? .orange :
                        scanned ? .green :
                        Color.secondary.opacity(0.4)
                    )
                    .help(
                        isScanning ? "Scanning…" :
                        scanned ? "Scanned" :
                        "Not scanned"
                    )

                // Hash icon — number sign
                Image(systemName: "number")
                    .font(.caption2)
                    .foregroundStyle(
                        isHashing ? .orange :
                        fullyHashed ? .green :
                        status.hashCoveragePercent > 0 ? .orange :
                        Color.secondary.opacity(0.4)
                    )
                    .help(
                        isHashing ? "Hashing…" :
                        fullyHashed ? "Fully hashed" :
                        status.hashCoveragePercent > 0 ? "\(Int(status.hashCoveragePercent))% hashed" :
                        "Not hashed"
                    )
            }
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Info row + unmount button
            HStack(spacing: 20) {
                Label(drive.mountPath, systemImage: "folder.fill")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let uuid = drive.uuid {
                    Label(uuid, systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if unmountSuccess {
                    Label("Unmounted", systemImage: "eject.fill")
                        .font(.caption)
                        .foregroundStyle(Color(.systemGray))
                        .transition(.opacity)
                } else if isMounted {
                    Button {
                        Task { await unmountDrive() }
                    } label: {
                        HStack(spacing: 4) {
                            if isUnmounting {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "eject.fill")
                            }
                            Text("Unmount")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(activeOperation != nil || isUnmounting)
                    .help(activeOperation != nil ? "Cannot unmount while an operation is running" : "Safely unmount this drive")
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

            // Connection & check status (mounted drives only)
            if isMounted, lastConnected != nil || lastQuickCheckDate != nil || changeReport != nil {
                HStack(spacing: 12) {
                    if let connected = lastConnected {
                        HStack(spacing: 4) {
                            Image(systemName: "cable.connector")
                                .foregroundStyle(.green)
                            Text("Connected \(ageString(connected))")
                        }
                    }
                    if let checkDate = lastQuickCheckDate {
                        let effectivelyPassed = lastQuickCheckPassed == true || diffConfirmedNoChanges
                        HStack(spacing: 4) {
                            Image(systemName: effectivelyPassed ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .foregroundStyle(effectivelyPassed ? .green : .orange)
                            Text(diffConfirmedNoChanges ? "No changes" : "Checked \(ageString(checkDate))")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            // Change report (shown when quick-check detected changes or diff was run)
            if isDiffing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing changes...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let report = changeReport, report.hasChanges {
                changeReportView(report)
            } else if lastQuickCheckPassed == false && !diffConfirmedNoChanges && isMounted {
                // Quick-check failed and diff hasn't confirmed no changes — offer to analyze
                Button {
                    Task { await runDiff() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Analyze Changes")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                            if let status, status.lastScan != nil, status.hashCoveragePercent < 100 {
                                Image(systemName: "number")
                                Text(status.hashCoveragePercent > 0 ? "Continue Hashing" : "Hash")
                            } else if let status, status.lastScan != nil, status.hashCoveragePercent >= 100 {
                                Image(systemName: "arrow.clockwise")
                                Text("Re-Scan & Hash")
                            } else {
                                Image(systemName: "magnifyingglass")
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

    // MARK: - Change Report View

    @ViewBuilder
    private func changeReportView(_ report: ChangeReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Summary header
            HStack {
                Image(systemName: report.hasChanges ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(report.hasChanges ? .orange : .green)
                Text(report.hasChanges ? "\(report.totalChanges) changes detected" : "No changes")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                if report.hasChanges {
                    Button {
                        showChangeDetails.toggle()
                    } label: {
                        Text(showChangeDetails ? "Hide" : "Details")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Button {
                    changeReport = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Compact summary chips
            if report.hasChanges {
                HStack(spacing: 12) {
                    if report.addedCount > 0 {
                        changeChip(count: report.addedCount, label: "added", bytes: report.bytesAdded, color: .green, icon: "plus.circle.fill")
                    }
                    if report.deletedCount > 0 {
                        changeChip(count: report.deletedCount, label: "deleted", bytes: report.bytesDeleted, color: .red, icon: "minus.circle.fill")
                    }
                    if report.modifiedCount > 0 {
                        changeChip(count: report.modifiedCount, label: "modified", bytes: nil, color: .orange, icon: "pencil.circle.fill")
                    }
                    if report.movedCount > 0 {
                        changeChip(count: report.movedCount, label: "moved", bytes: nil, color: .blue, icon: "arrow.right.circle.fill")
                    }
                }

                // Net size change
                if report.netBytes != 0 {
                    Text("Net: \(report.netBytes > 0 ? "+" : "")\(formatChangeBytes(report.netBytes))")
                        .font(.caption)
                        .foregroundStyle(report.netBytes > 0 ? .green : .red)
                }
            }

            // Detailed file lists (toggled)
            if showChangeDetails && report.hasChanges {
                VStack(alignment: .leading, spacing: 8) {
                    if !report.addedFiles.isEmpty {
                        changeFileList(title: "Added", files: report.addedFiles, color: .green)
                    }
                    if !report.deletedFiles.isEmpty {
                        changeFileList(title: "Deleted", files: report.deletedFiles, color: .red)
                    }
                    if !report.modifiedFiles.isEmpty {
                        changeFileList(title: "Modified", files: report.modifiedFiles, color: .orange)
                    }
                    if !report.movedFiles.isEmpty {
                        changeMovedList(files: report.movedFiles)
                    }
                }
                .padding(.top, 4)
            }

            // Action: Sync button when changes detected
            if report.hasChanges {
                Button {
                    changeReport = nil
                    Task { await triggerScan() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Sync Database")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(activeOperation != nil)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(report.hasChanges ? Color.orange.opacity(0.05) : Color.green.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(report.hasChanges ? Color.orange.opacity(0.2) : Color.green.opacity(0.2), lineWidth: 1)
        )
    }

    private func changeChip(count: Int, label: String, bytes: Int64?, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text("\(count) \(label)")
            if let bytes, bytes > 0 {
                Text("(\(formatChangeBytes(bytes)))")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
    }

    private func changeFileList(title: String, files: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color)
            ForEach(files.prefix(10), id: \.self) { path in
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if files.count > 10 {
                Text("… and \(files.count - 10) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func changeMovedList(files: [(path: String, from: String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Moved")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.blue)
            ForEach(files.prefix(10), id: \.path) { entry in
                HStack(spacing: 4) {
                    Text(entry.from)
                        .strikethrough()
                        .foregroundStyle(.tertiary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text(entry.path)
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            }
            if files.count > 10 {
                Text("… and \(files.count - 10) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func formatChangeBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: abs(bytes))
    }

    // MARK: - Diff Operation

    private func runDiff() async {
        isDiffing = true
        changeReport = nil
        do {
            let result = try await APIService.shared.triggerDiff(driveName: drive.name)
            let report = ChangeReport.from(dict: result)
            changeReport = report
            if report?.hasChanges == false {
                diffConfirmedNoChanges = true
                // Notify parent to correct the activity log
                NotificationCenter.default.post(
                    name: .init("driveVerifiedNoChanges"),
                    object: drive.name
                )
            }
        } catch {
            // Silently fail — diff is optional
        }
        isDiffing = false
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

    @State private var lastStatusFetch: Date?

    private func loadStatus(force: Bool = false) async {
        // Show cached status immediately
        if status == nil {
            status = ViewCache.load(DriveStatusResponse.self, key: "driveStatus_\(drive.name)")
        }
        // Skip API call if we have fresh data (< 60s old) and not forced
        if !force, status != nil, let last = lastStatusFetch, Date().timeIntervalSince(last) < 60 {
            return
        }
        isLoadingStatus = status == nil  // Only show spinner if no cached data
        statusError = nil
        do {
            let fresh = try await APIService.shared.fetchDriveStatus(name: drive.name)
            status = fresh
            lastStatusFetch = Date()
            ViewCache.save(fresh, key: "driveStatus_\(drive.name)")
            diskSpace = DiskSpace.read(path: drive.mountPath)
        } catch {
            if status == nil {
                statusError = error.localizedDescription
            }
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
            let msg = (error as? URLError)?.code == .timedOut
                ? "Backend busy — scan may still be running. Check activity panel."
                : "Scan failed: \(error.localizedDescription)"
            operationResult = .failure(msg)
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

    private func unmountDrive() async {
        isUnmounting = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", drive.mountPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            isUnmounting = false
            if process.terminationStatus == 0 {
                withAnimation { unmountSuccess = true }
                diskSpace = nil
                await loadStatus()
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                operationResult = .failure("Unmount failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                clearResultAfterDelay()
            }
        } catch {
            isUnmounting = false
            operationResult = .failure("Unmount failed: \(error.localizedDescription)")
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
        var consecutiveErrors = 0
        while true {
            do {
                let operation = try await APIService.shared.fetchOperation(id: id)
                consecutiveErrors = 0
                activeOperation = operation

                if operation.status == "completed" {
                    activeOperation = nil
                    activeOperationType = nil
                    currentOperationId = nil
                    // Clear stale state — DB is now up to date
                    changeReport = nil
                    diffConfirmedNoChanges = true
                    verificationReport = nil
                    let message = operation.isUpToDate
                        ? "Drive is up to date — no changes detected"
                        : "Scan & hash completed"
                    operationResult = .success(message)
                    clearResultAfterDelay()
                    await loadStatus(force: true)
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
                consecutiveErrors += 1
                // Backend may be busy with heavy I/O — retry up to 5 times before giving up
                if consecutiveErrors >= 5 {
                    activeOperation = nil
                    activeOperationType = nil
                    currentOperationId = nil
                    operationResult = .failure("Lost connection to backend")
                    clearResultAfterDelay()
                    break
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func pollVerification(id: String) async {
        var consecutiveErrors = 0
        while true {
            do {
                let operation = try await APIService.shared.fetchOperation(id: id)
                consecutiveErrors = 0
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
                consecutiveErrors += 1
                if consecutiveErrors >= 5 {
                    activeOperation = nil
                    activeOperationType = nil
                    currentOperationId = nil
                    operationResult = .failure("Lost connection to backend")
                    clearResultAfterDelay()
                    break
                }
                try? await Task.sleep(for: .seconds(3))
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

/// Sort options for the drive list.
enum DriveSortOption: String, CaseIterable {
    case name = "Name"
    case lastScanned = "Last Scanned"
    case size = "Size"
    case usage = "Usage"
    case fileCount = "Files"

    var icon: String {
        switch self {
        case .name: "textformat.abc"
        case .lastScanned: "clock"
        case .size: "internaldisk"
        case .usage: "chart.bar.fill"
        case .fileCount: "doc"
        }
    }
}

/// Main view for displaying and managing the list of registered drives.
struct DriveListView: View {
    @Environment(\.activeTab) private var activeTab
    @EnvironmentObject private var backend: BackendService
    @State private var drives: [DriveResponse] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showAddSheet = false
    @State private var driveToDelete: DriveResponse?
    @State private var showDeleteConfirmation = false
    @State private var expandedDriveIds: Set<Int> = []
    /// Tracks the most recently expanded drive for auto-scroll.
    @State private var lastExpandedId: Int?
    /// Incremented on volume mount/unmount to trigger card refresh.
    @State private var volumeRefreshTrigger = 0
    @State private var sortOption: DriveSortOption = .name
    @State private var sortAscending = true
    /// ID of a just-registered drive — floated to top and auto-expanded until dismissed.
    @State private var newlyRegisteredDriveId: Int?
    /// Active operations polled from the backend.
    @State private var activeOperations: [OperationResponse] = []
    @State private var operationPollTask: Task<Void, Never>?
    /// Transient quick-check results shown in activity panel.
    @State private var quickCheckMessages: [QuickCheckMessage] = []
    @State private var connectionBanner: String?
    /// Session activity log for the history panel.
    @State private var activityLog: [ActivityLogEntry] = []
    /// Per-drive: when last mounted (this session only).
    @State private var driveLastConnected: [String: Date] = [:]
    /// Per-drive: last quick-check result.
    @State private var driveQuickChecks: [String: DriveCheckInfo] = [:]
    /// Whether the activity log disclosure is expanded.
    @State private var showActivityLog = false

    private struct QuickCheckMessage: Identifiable {
        let id = UUID()
        let driveName: String
        let passed: Bool
    }

    private struct DriveCheckInfo {
        let date: Date
        let passed: Bool
    }

    private struct ActivityLogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let driveName: String
        let type: ActivityType
        let passed: Bool?

        enum ActivityType {
            case connected, disconnected, quickCheck
        }

        var icon: String {
            switch type {
            case .connected: return "cable.connector"
            case .disconnected: return "eject"
            case .quickCheck:
                if passed == nil { return "hourglass" }
                return passed == true ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
            }
        }

        var iconColor: Color {
            switch type {
            case .connected: return .green
            case .disconnected: return .secondary
            case .quickCheck:
                if passed == nil { return .secondary }
                return passed == true ? .green : .orange
            }
        }

        var message: String {
            switch type {
            case .connected: return "\(driveName) connected"
            case .disconnected: return "\(driveName) disconnected"
            case .quickCheck:
                if passed == nil { return "\(driveName): Checking..." }
                return "\(driveName): \(passed == true ? "Unchanged" : "Quick-check: possible changes")"
            }
        }
    }

    private var sortedDrives: [DriveResponse] {
        let sorted: [DriveResponse]
        switch sortOption {
        case .name:
            sorted = drives.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastScanned:
            sorted = drives.sorted { ($0.lastScan ?? .distantPast) > ($1.lastScan ?? .distantPast) }
        case .size:
            sorted = drives.sorted { $0.totalBytes > $1.totalBytes }
        case .usage:
            // Sort by used percentage (fullest first) — uses live disk space
            sorted = drives.sorted { (a: DriveResponse, b: DriveResponse) -> Bool in
                let pctA = DiskSpace.read(path: a.mountPath)?.usedPercent ?? 0
                let pctB = DiskSpace.read(path: b.mountPath)?.usedPercent ?? 0
                return pctA > pctB
            }
        case .fileCount:
            sorted = drives.sorted { $0.fileCount > $1.fileCount }
        }
        let result: [DriveResponse] = sortAscending ? sorted : Array(sorted.reversed())

        // Float mounted drives to top, then newly registered
        var mounted = result.filter { FileManager.default.fileExists(atPath: $0.mountPath) }
        var unmounted = result.filter { !FileManager.default.fileExists(atPath: $0.mountPath) }

        // Pin newly registered drive to very top
        if let pinId = newlyRegisteredDriveId {
            if let idx = mounted.firstIndex(where: { $0.id == pinId }) {
                let pinned = mounted.remove(at: idx)
                mounted.insert(pinned, at: 0)
            } else if let idx = unmounted.firstIndex(where: { $0.id == pinId }) {
                let pinned = unmounted.remove(at: idx)
                mounted.insert(pinned, at: 0) // even unmounted new drive goes to top
            }
        }

        return mounted + unmounted
    }

    var body: some View {
        mainContent
            .toolbar(content: driveToolbar)
            .overlay(alignment: .top) {
                if let banner = connectionBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(.green)
                        Text(banner)
                            .fontWeight(.medium)
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 8)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        .task {
            // Show cached drive list immediately while backend starts
            loadCachedDrives()
        }
        .task(id: backend.isRunning) {
            if backend.isRunning {
                await loadDrives()
                volumeRefreshTrigger += 1
                startOperationPolling()
                // Quick-check in parallel — don't block UI
                Task { await quickCheckMountedDrives() }
            } else {
                operationPollTask?.cancel()
            }
        }
        .onDisappear {
            operationPollTask?.cancel()
        }
        .onChange(of: expandedDriveIds) { _, newIds in
            // Clear the "newly registered" pin when user collapses that drive
            if let pinId = newlyRegisteredDriveId, !newIds.contains(pinId) {
                newlyRegisteredDriveId = nil
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { notification in
            volumeRefreshTrigger += 1
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                Task {
                    if let driveName = try? await APIService.shared.recognizeDrive(mountPath: volumeURL.path) {
                        driveLastConnected[driveName] = Date()
                        withAnimation(.easeInOut) { connectionBanner = "\(driveName) connected" }
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            withAnimation(.easeOut) { connectionBanner = nil }
                        }
                        activityLog.insert(ActivityLogEntry(date: Date(), driveName: driveName, type: .connected, passed: nil), at: 0)
                        await loadDrives()
                        // Fully catalogued → quick-check (~5 sec, non-blocking)
                        // Not fully catalogued → full smart-scan
                        if let drive = drives.first(where: { $0.name == driveName }),
                           drive.lastScan != nil && !false {
                            // Show "checking..." immediately, wait a moment for drive to fully mount
                            let checkingEntry = ActivityLogEntry(date: Date(), driveName: driveName, type: .quickCheck, passed: nil)
                            activityLog.insert(checkingEntry, at: 0)
                            try? await Task.sleep(for: .seconds(3))

                            let result = try? await APIService.shared.quickCheck(driveName: driveName)
                            let status = result?["status"] as? String ?? "error"
                            let passed = status == "verified"

                            // Replace "checking..." with actual result
                            if let idx = activityLog.firstIndex(where: { $0.id == checkingEntry.id }) {
                                activityLog[idx] = ActivityLogEntry(date: Date(), driveName: driveName, type: .quickCheck, passed: passed)
                            }
                            if passed {
                                // No need for transient banner if unchanged
                                driveQuickChecks[driveName] = DriveCheckInfo(date: Date(), passed: true)
                            } else {
                                quickCheckMessages.append(
                                    QuickCheckMessage(driveName: driveName, passed: false)
                                )
                                driveQuickChecks[driveName] = DriveCheckInfo(date: Date(), passed: false)
                                clearQuickCheckAfterDelay()
                            }
                        } else {
                            _ = try? await APIService.shared.triggerAutoScan(driveName: driveName)
                        }
                    }
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { notification in
            volumeRefreshTrigger += 1
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                if let drive = drives.first(where: { $0.mountPath == volumeURL.path }) {
                    withAnimation(.easeInOut) { connectionBanner = "\(drive.name) disconnected" }
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation(.easeOut) { connectionBanner = nil }
                    }
                    activityLog.insert(ActivityLogEntry(date: Date(), driveName: drive.name, type: .disconnected, passed: nil), at: 0)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("driveVerifiedNoChanges"))) { notification in
            if let driveName = notification.object as? String {
                // Correct the quick-check log entry
                if let idx = activityLog.firstIndex(where: { $0.driveName == driveName && $0.type == .quickCheck && $0.passed == false }) {
                    activityLog.remove(at: idx)
                    activityLog.insert(ActivityLogEntry(date: Date(), driveName: driveName, type: .quickCheck, passed: true), at: 0)
                }
                driveQuickChecks[driveName] = DriveCheckInfo(date: Date(), passed: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshCurrentPage)) { _ in
            if activeTab == .drives {
                Task {
                    volumeRefreshTrigger += 1
                    await loadDrives()
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddDriveSheet {
                await loadDrives()
            }
        }
        .sheet(isPresented: $showDeleteConfirmation) {
            if let drive = driveToDelete {
                DeleteDriveConfirmation(drive: drive) {
                    Task {
                        await deleteDrive(drive)
                        showDeleteConfirmation = false
                    }
                } onCancel: {
                    driveToDelete = nil
                    showDeleteConfirmation = false
                }
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if !backend.isRunning && drives.isEmpty {
            startupView
        } else if isLoading && drives.isEmpty {
            loadingView
        } else if errorMessage != nil {
            errorView(errorMessage ?? "Unknown error")
        } else if drives.isEmpty {
            emptyView
        } else {
            driveListContent
        }
    }

    @ToolbarContentBuilder
    private func driveToolbar() -> some ToolbarContent {
        if activeTab == .drives || activeTab == nil {
            ToolbarItem {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    .help("Add Drive")
            }
        }
    }

    private var driveListContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                driveSummaryBar
                activityPanel
                sortBar
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(sortedDrives) { drive in
                            driveCardWithContext(drive)
                                .id(drive.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .onChange(of: lastExpandedId) { _, newId in
                    if let newId {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                proxy.scrollTo(newId, anchor: UnitPoint(x: 0.5, y: 0.15))
                            }
                        }
                    }
                }
            }
        }
    }

    private func driveCardWithContext(_ drive: DriveResponse) -> some View {
        DriveCard(
            drive: drive,
            isExpanded: expandedDriveIds.contains(drive.id),
            onToggle: { toggleExpansion(drive.id) },
            refreshTrigger: volumeRefreshTrigger,
            lastConnected: driveLastConnected[drive.name],
            lastQuickCheckDate: driveQuickChecks[drive.name]?.date,
            lastQuickCheckPassed: driveQuickChecks[drive.name]?.passed
        )
        .contextMenu {
            if FileManager.default.fileExists(atPath: drive.mountPath) {
                Button {
                    Task { await unmountDriveFromList(drive) }
                } label: {
                    Label("Unmount", systemImage: "eject.fill")
                }
            }
            Button(role: .destructive) {
                driveToDelete = drive
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Loading drives...").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle).foregroundStyle(.orange)
            Text("Failed to load drives").font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await loadDrives() } }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No drives registered").font(.headline)
            Text("Add a drive to start cataloging your files.").font(.subheadline).foregroundStyle(.secondary)
            Button { showAddSheet = true } label: { Label("Add Drive", systemImage: "plus") }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                VStack(spacing: 10) {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .frame(maxWidth: 500)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.05)))

                    HStack(spacing: 12) {
                        Button("Retry") {
                            backend.stop()
                            backend.start()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Show Log File") {
                            let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                                .appendingPathComponent("DriveCatalog/backend.log")
                            NSWorkspace.shared.open(logURL)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Summary Bar

    private var driveSummaryBar: some View {
        let totalStorage = drives.reduce(Int64(0)) { $0 + $1.totalBytes }
        let totalUsed = drives.reduce(Int64(0)) { total, drive in
            // Live disk space if mounted, otherwise cached status from DB
            let live = DiskSpace.read(path: drive.mountPath)?.usedBytes
            let cached = ViewCache.load(DriveStatusResponse.self, key: "driveStatus_\(drive.name)")?.usedBytes
            return total + (live ?? cached ?? 0)
        }
        let totalFree = totalStorage - totalUsed
        let usedPercent = totalStorage > 0 ? Double(totalUsed) / Double(totalStorage) * 100 : 0

        return HStack(spacing: 12) {
            // Drive count
            HStack(spacing: 4) {
                Image(systemName: "externaldrive.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text("\(drives.count)")
                    .fontWeight(.medium)
                Text("drives")
                    .foregroundStyle(.tertiary)
            }

            Divider().frame(height: 14)

            // Total capacity
            Text(formatBytes(totalStorage))
                .fontWeight(.medium)

            Divider().frame(height: 14)

            // Usage progress bar with percentage inside
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(usedPercent > 85 ? Color.orange : Color.blue)
                        .frame(width: max(0, geo.size.width * CGFloat(usedPercent / 100)))
                    Text("\(Int(usedPercent))%")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 0.5)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 80, height: 16)

            // Used · Free
            Text("\(formatBytes(totalUsed)) used")
                .fontWeight(.medium)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(formatBytes(totalFree)) free")
                .foregroundStyle(.tertiary)

            let mountedCount = drives.filter { DiskSpace.read(path: $0.mountPath) != nil }.count
            if mountedCount < drives.count {
                Text("(\(mountedCount)/\(drives.count) mounted)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor))
        )
    }

    // MARK: - Sort Bar

    private var sortBar: some View {
        HStack(spacing: 2) {
            ForEach(DriveSortOption.allCases, id: \.self) { option in
                Button {
                    if sortOption == option {
                        sortAscending.toggle()
                    } else {
                        sortOption = option
                        // Default direction: name ascending, others descending (biggest first)
                        sortAscending = option == .name
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: sortOption == option && option == .usage
                              ? (sortAscending ? "chart.bar" : "chart.bar.fill")
                              : option.icon)
                            .font(.caption2)
                        Text(option.rawValue)
                            .font(.caption2)
                        if sortOption == option {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(sortOption == option ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(sortOption == option ? .primary : .secondary)
            }
            Spacer()

            // Expand/collapse all toggle
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    if expandedDriveIds.count == drives.count {
                        expandedDriveIds.removeAll()
                    } else {
                        expandedDriveIds = Set(drives.map(\.id))
                    }
                }
            } label: {
                Image(systemName: expandedDriveIds.count == drives.count ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(expandedDriveIds.count == drives.count ? "Collapse all" : "Expand all")
        }
    }

    // MARK: - Activity Panel

    @ViewBuilder
    private var activityPanel: some View {
        let unscannedDrives = drives.filter { $0.lastScan == nil }
        let mountedNeedingHash = drives.filter {
            false && FileManager.default.fileExists(atPath: $0.mountPath)
        }
        let hasActivity = !activeOperations.isEmpty || !unscannedDrives.isEmpty || !mountedNeedingHash.isEmpty || !quickCheckMessages.isEmpty || !activityLog.isEmpty

        if hasActivity {
            VStack(alignment: .leading, spacing: 6) {
                // Active operations
                ForEach(activeOperations) { op in
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(operationLabel(op))
                                    .font(.caption)
                                    .fontWeight(.medium)

                                // Show overall coverage for hash ops, batch progress for others
                                let overallPct = overallHashProgress(op)
                                let displayPct = overallPct ?? op.progressPercent

                                if let pct = displayPct {
                                    Text("\(Int(pct))%")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                if let eta = op.etaSeconds, eta > 0 {
                                    Text(activityETA(eta))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            if op.filesTotal > 0 {
                                let overallPct = overallHashProgress(op)
                                let barValue = overallPct.map { $0 / 100 } ?? (op.progressPercent ?? 0) / 100

                                HStack(spacing: 6) {
                                    ProgressView(value: barValue)
                                        .tint(.blue)

                                    if let _ = overallPct, let drive = drives.first(where: { $0.name == op.driveName }) {
                                        let totalHashed = min(drive.fileCount, drive.fileCount + op.filesProcessed)
                                        Text("\(totalHashed.formatted())/\(drive.fileCount.formatted()) files")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .fixedSize()
                                    } else {
                                        Text("\(op.filesProcessed.formatted())/\(op.filesTotal.formatted()) files")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .fixedSize()
                                    }
                                }
                            }
                        }

                        Spacer()
                    }
                }

                // Quick-check results (transient, ~5 sec)
                ForEach(quickCheckMessages) { msg in
                    HStack(spacing: 8) {
                        Image(systemName: msg.passed ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(msg.passed ? .green : .orange)

                        Text(msg.passed
                             ? "\(msg.driveName): Unchanged"
                             : "\(msg.driveName): Quick-check: possible changes")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if !msg.passed {
                            Button {
                                Task {
                                    _ = try? await APIService.shared.triggerAutoScan(driveName: msg.driveName)
                                    quickCheckMessages.removeAll(where: { $0.id == msg.id })
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Full Scan")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }

                // Unscanned drives — action items
                if !unscannedDrives.isEmpty && activeOperations.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)

                        Text("\(unscannedDrives.count) drive\(unscannedDrives.count == 1 ? "" : "s") not yet scanned: \(unscannedDrives.map(\.name).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()

                        Button {
                            Task {
                                for drive in unscannedDrives {
                                    _ = try? await APIService.shared.triggerAutoScan(driveName: drive.name)
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill")
                                Text("Scan All")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                } else if !unscannedDrives.isEmpty {
                    // Show unscanned note alongside active operations (no button — already busy)
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(unscannedDrives.count) drive\(unscannedDrives.count == 1 ? "" : "s") queued for scanning")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Drives needing hashing — mounted, scanned, but not fully hashed
                if !mountedNeedingHash.isEmpty && activeOperations.isEmpty {
                    ForEach(mountedNeedingHash) { drive in
                        HStack(spacing: 8) {
                            Image(systemName: "number")
                                .font(.caption)
                                .foregroundStyle(.purple)

                            let pct = drive.fileCount > 0 ? Int(Double(drive.fileCount) / Double(drive.fileCount) * 100) : 0
                            Text("\(drive.name): \(pct)% hashed (\(drive.fileCount.formatted())/\(drive.fileCount.formatted()) files)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer()

                            Button {
                                Task {
                                    _ = try? await APIService.shared.triggerAutoScan(driveName: drive.name)
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "play.fill")
                                    Text(drive.fileCount > 0 ? "Continue" : "Hash")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }

                // Recent activity log — expandable history
                if !activityLog.isEmpty {
                    if !activeOperations.isEmpty || !unscannedDrives.isEmpty || !mountedNeedingHash.isEmpty || !quickCheckMessages.isEmpty {
                        Divider()
                    }
                    DisclosureGroup(isExpanded: $showActivityLog) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(activityLog.prefix(20)) { entry in
                                HStack(spacing: 6) {
                                    Image(systemName: entry.icon)
                                        .font(.caption2)
                                        .foregroundStyle(entry.iconColor)
                                        .frame(width: 14)
                                    Text(entry.message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(relativeTimeShort(entry.date))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize()
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption2)
                            Text("Recent")
                                .font(.caption2)
                            Text("(\(min(activityLog.count, 20)))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        !activeOperations.isEmpty ? Color.blue.opacity(0.2) :
                        (!unscannedDrives.isEmpty || !mountedNeedingHash.isEmpty) ? Color.orange.opacity(0.2) :
                        Color.secondary.opacity(0.1),
                        lineWidth: 1
                    )
            )
            .animation(nil, value: activeOperations.count)
        }
    }

    /// For hash/smart-scan ops, compute overall hash coverage across the drive
    /// (not just the current batch). Returns nil for non-hash operations.
    private func overallHashProgress(_ op: OperationResponse) -> Double? {
        guard op.type == "hash" || op.type == "smart-scan" else { return nil }
        guard let drive = drives.first(where: { $0.name == op.driveName }),
              drive.fileCount > 0 else { return nil }
        let totalHashed = min(drive.fileCount, drive.fileCount + op.filesProcessed)
        return Double(totalHashed) / Double(drive.fileCount) * 100
    }

    private func operationLabel(_ op: OperationResponse) -> String {
        let typeName: String
        switch op.type {
        case "scan": typeName = "Scanning"
        case "hash": typeName = "Hashing"
        case "smart-scan": typeName = "Smart scanning"
        case "verify-integrity": typeName = "Verifying"
        case "copy": typeName = "Copying"
        default: typeName = op.type.capitalized
        }
        return "\(typeName) \(op.driveName)"
    }

    private func relativeTimeShort(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    private func activityETA(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s left" }
        if seconds < 3600 { return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s left" }
        return "\(Int(seconds) / 3600)h \((Int(seconds) % 3600) / 60)m left"
    }

    private func startOperationPolling() {
        operationPollTask?.cancel()
        operationPollTask = Task {
            while !Task.isCancelled {
                do {
                    let response = try await APIService.shared.fetchOperations(limit: 10)
                    let active = response.operations.filter { $0.isActive }
                    // Only update state when data actually changes to avoid unnecessary layout passes
                    let activeIds = Set(active.map(\.id))
                    let currentIds = Set(activeOperations.map(\.id))
                    let progressChanged = zip(active.sorted(by: { $0.id < $1.id }),
                                              activeOperations.sorted(by: { $0.id < $1.id }))
                        .contains(where: { $0.filesProcessed != $1.filesProcessed })
                    if activeIds != currentIds || progressChanged {
                        await MainActor.run { activeOperations = active }
                    }
                } catch {
                    // Silently continue polling
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Toggle a drive's expansion state.
    private func toggleExpansion(_ id: Int) {
        if expandedDriveIds.contains(id) {
            expandedDriveIds.remove(id)
        } else {
            expandedDriveIds.insert(id)
            lastExpandedId = id
        }
    }

    /// Quick-check all fully-catalogued mounted drives (e.g. on app startup).
    private func quickCheckMountedDrives() async {
        let candidates = drives.filter {
            $0.lastScan != nil && !false && FileManager.default.fileExists(atPath: $0.mountPath)
        }
        guard !candidates.isEmpty else { return }

        // Insert "Checking..." entries for all candidates
        var checkingEntries: [String: ActivityLogEntry] = [:]
        for drive in candidates {
            let entry = ActivityLogEntry(date: Date(), driveName: drive.name, type: .quickCheck, passed: nil)
            checkingEntries[drive.name] = entry
            activityLog.insert(entry, at: 0)
        }

        // Brief delay for drives to fully mount before checking
        try? await Task.sleep(for: .seconds(2))

        // Run checks and update entries with results
        var hasChanges = false
        for drive in candidates {
            let result = try? await APIService.shared.quickCheck(driveName: drive.name)
            let status = result?["status"] as? String ?? "error"
            let passed = status == "verified"

            // Replace "Checking..." with result
            if let entry = checkingEntries[drive.name],
               let idx = activityLog.firstIndex(where: { $0.id == entry.id }) {
                activityLog[idx] = ActivityLogEntry(date: Date(), driveName: drive.name, type: .quickCheck, passed: passed)
            }

            driveQuickChecks[drive.name] = DriveCheckInfo(date: Date(), passed: passed)
            if !passed {
                quickCheckMessages.append(QuickCheckMessage(driveName: drive.name, passed: false))
                hasChanges = true
            }
        }
        if hasChanges {
            clearQuickCheckAfterDelay()
        }
    }

    private func clearQuickCheckAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(8))
            withAnimation { quickCheckMessages.removeAll() }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    @State private var startupRotation: Double = 0

    // MARK: - Drive Cache

    private static let cacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DriveCatalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drives_cache.json")
    }()

    private func loadCachedDrives() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cached = try? JSONDecoder().decode([DriveResponse].self, from: data)
        else { return }
        if drives.isEmpty {
            drives = cached
            isLoading = false  // Show cached data immediately
        }
    }

    private func saveDrivesToCache() {
        guard let data = try? JSONEncoder().encode(drives) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private func loadDrives() async {
        let wasEmpty = drives.isEmpty
        if wasEmpty { isLoading = true }
        errorMessage = nil
        do {
            let response = try await APIService.shared.fetchDrives()
            drives = response.drives
            saveDrivesToCache()
        } catch {
            if drives.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func unmountDriveFromList(_ drive: DriveResponse) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", drive.mountPath]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                volumeRefreshTrigger += 1
            }
        } catch {
            // Unmount failed silently in context menu
        }
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

// MARK: - Delete Drive Confirmation

/// Requires the user to type "DELETE" to confirm drive deletion.
private struct DeleteDriveConfirmation: View {
    let drive: DriveResponse
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var confirmText = ""
    @FocusState private var isFocused: Bool

    private var isConfirmed: Bool {
        confirmText.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text("Delete \"\(drive.name)\"?")
                .font(.headline)

            Text("This will permanently remove the drive registration and all \(drive.fileCount.formatted()) catalogued file records and hashes. This cannot be undone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 4) {
                Text("Type DELETE to confirm:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $confirmText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit {
                        if isConfirmed { onConfirm() }
                    }
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape)
                    .buttonStyle(.bordered)

                Button("Delete Drive") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!isConfirmed)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }
}

#Preview {
    DriveListView()
}
