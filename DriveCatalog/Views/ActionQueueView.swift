import AppKit
import SwiftUI

struct ActionQueueView: View {
    @Environment(\.activeTab) private var activeTab
    @State private var actions: [PlannedAction] = []
    @State private var actionableActions: [PlannedAction] = []
    @State private var mountedDrives: [String] = []
    @State private var isLoading = false
    @State private var filter: ActionFilter = .pending
    @State private var pollTask: Task<Void, Never>?
    @State private var completionBanner: String?
    @State private var showRescanPrompt = false
    @State private var drivesToRescan: Set<String> = []
    @State private var expandedDriveGroups: Set<String> = []

    enum ActionFilter: String, CaseIterable {
        case all = "All"
        case pending = "Pending"
        case completed = "Completed"
        case cancelled = "Cancelled"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            if isLoading && actions.isEmpty {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Loading queue...").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if actions.isEmpty {
                emptyState
            } else {
                actionList
            }
        }

        .task {
            if actions.isEmpty, let cached = ViewCache.load([PlannedAction].self, key: "actions") {
                actions = cached
                isLoading = false
            }
            await refresh()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
        }
        .onChange(of: activeTab) { _, newTab in
            if newTab == .queue {
                Task { await refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshCurrentPage)) { _ in
            if activeTab == .queue { Task { await refresh() } }
        }
        .overlay(alignment: .top) {
            if let banner = completionBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(banner)
                        .font(.callout)
                        .fontWeight(.medium)
                    Spacer()
                    Button("Dismiss") { completionBanner = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(12)
                .background(.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.top, 80)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showRescanPrompt) {
            rescanPromptSheet
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Action Queue")
                    .font(.title2)
                    .fontWeight(.bold)
                if !actions.isEmpty {
                    Text("\(filteredActions.count) shown · \(actions.count) total · \(actionableActions.count) ready now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !actionableActions.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.green)
                    Text("\(actionableActions.count) actionable")
                        .fontWeight(.medium)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
            }

            // Filter picker
            Picker("Filter", selection: $filter) {
                ForEach(ActionFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No planned actions")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Right-click folders in the Browser to plan delete, copy, or move operations.\nActions are verified automatically when drives are connected.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Action List (grouped by drive)

    /// Groups actions by source drive for the current filter.
    private var groupedActions: [(drive: String, actions: [PlannedAction])] {
        let filtered = filteredActions
        let grouped = Dictionary(grouping: filtered) { $0.sourceDrive }
        return grouped.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (drive: $0.key, actions: $0.value) }
    }

    private var actionList: some View {
        List {
            ForEach(groupedActions, id: \.drive) { group in
                Section(isExpanded: Binding(
                    get: { expandedDriveGroups.contains(group.drive) },
                    set: { expanded in
                        if expanded { expandedDriveGroups.insert(group.drive) }
                        else { expandedDriveGroups.remove(group.drive) }
                    }
                )) {
                    ForEach(group.actions) { action in
                        let isActionable = actionableActions.contains(where: { $0.id == action.id })
                        actionRow(action, isActionable: isActionable)
                    }
                } header: {
                    driveGroupHeader(drive: group.drive, actions: group.actions)
                }
            }
        }
    }

    private func driveGroupHeader(drive: String, actions: [PlannedAction]) -> some View {
        let isMounted = mountedDrives.contains(drive)
        let totalBytes = actions.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        let pendingCount = actions.filter { $0.status == "pending" }.count
        let actionableCount = actionableActions.filter { $0.sourceDrive == drive }.count

        return HStack(spacing: 8) {
            Image(systemName: isMounted ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(isMounted ? .blue : .secondary)

            Text(drive)
                .fontWeight(.semibold)

            Text("·")
                .foregroundStyle(.tertiary)

            Text("\(actions.count) action\(actions.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)

            if totalBytes > 0 {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if actionableCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                    Text("\(actionableCount) ready")
                        .font(.caption)
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1), in: Capsule())
            } else if pendingCount > 0 && !isMounted {
                Text("Connect to execute")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var filteredActions: [PlannedAction] {
        switch filter {
        case .all: return actions
        case .pending: return actions.filter { $0.status == "pending" }
        case .completed: return actions.filter { $0.status == "completed" }
        case .cancelled: return actions.filter { $0.status == "cancelled" }
        }
    }

    // MARK: - Action Row

    private func actionRow(_ action: PlannedAction, isActionable: Bool) -> some View {
        HStack(spacing: 12) {
            // Action icon
            Image(systemName: action.actionIcon)
                .font(.title3)
                .foregroundStyle(actionColor(action))
                .frame(width: 24)

            // Details
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(action.actionLabel)
                        .fontWeight(.medium)
                    Text(action.sourcePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    Label(action.sourceDrive, systemImage: "externaldrive.fill")
                        .font(.caption)
                        .foregroundStyle(
                            mountedDrives.contains(action.sourceDrive)
                                ? .blue : .secondary
                        )

                    if let target = action.targetDrive, action.actionType != "delete" {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Label(target, systemImage: "externaldrive.fill")
                            .font(.caption)
                            .foregroundStyle(
                                mountedDrives.contains(target) ? .blue : .secondary
                            )
                    }
                }

                if let reason = action.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Size
            Text(ByteCountFormatter.string(
                fromByteCount: action.estimatedBytes, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Status badge
            statusBadge(action)

            // Actions
            if isActionable {
                Button {
                    revealInFinder(action: action)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Open in Finder")
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if action.status == "pending" {
                Button {
                    revealInFinder(action: action)
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.right.circle")
                }
                Button {
                    Task { await markCompleted(action) }
                } label: {
                    Label("Mark Completed", systemImage: "checkmark.circle")
                }
                Divider()
                Button(role: .destructive) {
                    Task { await cancelAction(action) }
                } label: {
                    Label("Cancel Action", systemImage: "xmark.circle")
                }
            }
            if action.status == "completed" || action.status == "cancelled" {
                Button(role: .destructive) {
                    Task { await removeAction(action) }
                } label: {
                    Label("Remove from Queue", systemImage: "trash")
                }
            }
        }
    }

    private func statusBadge(_ action: PlannedAction) -> some View {
        Text(action.status.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor(action).opacity(0.15))
            .foregroundStyle(statusColor(action))
            .clipShape(Capsule())
    }

    private func actionColor(_ action: PlannedAction) -> Color {
        switch action.actionType {
        case "delete": return .red
        case "copy": return .blue
        case "move": return .orange
        default: return .secondary
        }
    }

    private func statusColor(_ action: PlannedAction) -> Color {
        switch action.status {
        case "pending": return .orange
        case "ready": return .blue
        case "in_progress": return .purple
        case "completed": return .green
        case "cancelled": return .gray
        default: return .secondary
        }
    }

    // MARK: - Actions

    private func refresh() async {
        if actions.isEmpty { isLoading = true }
        do {
            let response = try await APIService.shared.fetchActions()
            actions = response.actions
            // Auto-expand all drive groups on first load
            if expandedDriveGroups.isEmpty {
                expandedDriveGroups = Set(actions.map(\.sourceDrive))
            }
            ViewCache.save(actions, key: "actions")
            let actionable = try await APIService.shared.fetchActionableActions()
            actionableActions = actionable.actions
            mountedDrives = actionable.mountedDrives
        } catch {
            // Non-critical
        }
        isLoading = false
    }

    private func markCompleted(_ action: PlannedAction) async {
        let req = UpdateActionRequest(status: "completed")
        _ = try? await APIService.shared.updateAction(id: action.id, request: req)
        await refresh()
        // Prompt to rescan the affected drive
        drivesToRescan.insert(action.sourceDrive)
        showRescanPrompt = true
    }

    private func cancelAction(_ action: PlannedAction) async {
        let req = UpdateActionRequest(status: "cancelled")
        _ = try? await APIService.shared.updateAction(id: action.id, request: req)
        await refresh()
    }

    private func removeAction(_ action: PlannedAction) async {
        _ = try? await APIService.shared.deleteAction(id: action.id)
        await refresh()
    }

    private func revealInFinder(action: PlannedAction) {
        // Find the drive's mount path
        Task {
            do {
                let drives = try await APIService.shared.fetchDrives()
                if let drive = drives.drives.first(where: { $0.name == action.sourceDrive }) {
                    let fullPath = "\(drive.mountPath)/\(action.sourcePath)"
                    let url = URL(fileURLWithPath: fullPath)
                    if FileManager.default.fileExists(atPath: fullPath) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } catch {
                // Non-critical
            }
        }
    }

    // MARK: - Polling & Verification

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await verifyAndRefresh()
            }
        }
    }

    /// Ask the backend to check pending actions against the filesystem.
    /// Auto-completes deletes where the source is gone, then refreshes.
    private func verifyAndRefresh() async {
        do {
            let verification = try await APIService.shared.verifyActions()
            let completed = verification.results.filter { $0.autoCompleted }
            if !completed.isEmpty {
                // Gather drives that need rescanning
                let completedIds = Set(completed.map(\.actionId))
                let affectedDrives = actions
                    .filter { completedIds.contains($0.id) }
                    .map(\.sourceDrive)
                for drive in affectedDrives {
                    drivesToRescan.insert(drive)
                }

                await refresh()

                let count = completed.count
                withAnimation {
                    completionBanner = "\(count) action\(count == 1 ? "" : "s") auto-completed — files no longer on disk"
                }
                // Show rescan prompt
                if !drivesToRescan.isEmpty {
                    showRescanPrompt = true
                }
                // Auto-dismiss banner after 10 seconds
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    withAnimation { completionBanner = nil }
                }
            } else {
                // Still refresh to pick up status changes from other sources
                await refresh()
            }
        } catch {
            // Verify endpoint may not be available — fall back to client-side check
            await refresh()
            await clientSideVerify()
        }
    }

    /// Client-side filesystem check: verify ALL pending delete actions.
    /// If the source drive is mounted and the path is gone → auto-complete.
    /// If the source drive is NOT mounted → the path trivially doesn't exist,
    /// so we only auto-complete when the drive IS mounted (proving the user
    /// actually deleted it, not just unplugged the drive).
    ///
    /// For unmounted drives, we check on reconnect via the mount notification
    /// handler in DriveListView, and also re-verify when the Queue tab is selected.
    private func clientSideVerify() async {
        let pending = actions.filter { $0.actionType == "delete" && $0.status == "pending" }
        guard !pending.isEmpty else { return }

        do {
            let drivesResponse = try await APIService.shared.fetchDrives()
            let drivesByName = Dictionary(
                uniqueKeysWithValues: drivesResponse.drives.map { ($0.name, $0) }
            )
            var autoCompleted = 0

            for action in pending {
                guard let drive = drivesByName[action.sourceDrive] else { continue }
                let mountPath = drive.mountPath

                // Only verify if the drive is currently mounted
                guard FileManager.default.fileExists(atPath: mountPath) else { continue }

                let fullPath = "\(mountPath)/\(action.sourcePath)"
                if !FileManager.default.fileExists(atPath: fullPath) {
                    // Drive is mounted but path is gone → deletion confirmed
                    let req = UpdateActionRequest(status: "completed")
                    _ = try? await APIService.shared.updateAction(id: action.id, request: req)
                    drivesToRescan.insert(action.sourceDrive)
                    autoCompleted += 1
                }
            }

            if autoCompleted > 0 {
                await refresh()
                withAnimation {
                    completionBanner = "\(autoCompleted) action\(autoCompleted == 1 ? "" : "s") auto-completed — files no longer on disk"
                }
                if !drivesToRescan.isEmpty {
                    showRescanPrompt = true
                }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    withAnimation { completionBanner = nil }
                }
            }
        } catch {
            // Non-critical
        }
    }

    // MARK: - Rescan Prompt

    private var rescanPromptSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.blue)

            Text("Update Database?")
                .font(.headline)

            Text("The following drives had completed actions. Rescan now to keep the database in sync:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            VStack(spacing: 4) {
                ForEach(Array(drivesToRescan).sorted(), id: \.self) { drive in
                    Label(drive, systemImage: "externaldrive.fill")
                        .font(.callout)
                }
            }

            HStack(spacing: 12) {
                Button("Later") {
                    showRescanPrompt = false
                }
                .buttonStyle(.bordered)

                Button("Rescan Now") {
                    let drives = drivesToRescan
                    drivesToRescan.removeAll()
                    showRescanPrompt = false
                    Task {
                        for drive in drives {
                            _ = try? await APIService.shared.triggerAutoScan(driveName: drive)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
    }
}

#Preview {
    ActionQueueView()
}
