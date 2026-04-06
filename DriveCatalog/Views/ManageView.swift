import SwiftUI

/// Unified Manage page combining backup status, duplicates/space savings, and recommended actions.
struct ManageView: View {
    @Environment(\.activeTab) private var activeTab
    @ObservedObject private var backend = BackendService.shared
    @State private var insightsData: InsightsResponse?
    @State private var folderDuplicates: FolderDuplicateResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedAction: RecommendedAction?
    @State private var showAllDrives = false

    var body: some View {
        Group {
            if let action = selectedAction {
                ActionDrillDownView(action: action, onBack: { selectedAction = nil })
            } else {
                manageContent
            }
        }
        .task {
            if insightsData == nil {
                insightsData = ViewCache.load(InsightsResponse.self, key: "insights")
            }
        }
        .task(id: backend.isRunning) {
            if backend.isRunning { await loadData() }
        }
        .onChange(of: activeTab) { _, newTab in
            if newTab == .manage && selectedAction == nil {
                Task { await loadData() }
            }
        }
    }

    // MARK: - Main Content

    private var manageContent: some View {
        Group {
            if isLoading && insightsData == nil {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Analyzing your drives...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, insightsData == nil {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Failed to load data")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await loadData() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if let data = insightsData {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Section 1: Backup Status
                        backupStatusSection(data.health)

                        Divider()

                        // Section 2: Duplikate & Platzgewinn
                        duplicatesSection(data)

                        Divider()

                        // Section 3: Empfohlene Aktionen
                        actionsSection(data.actions)
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Manage")
        .onReceive(NotificationCenter.default.publisher(for: .refreshCurrentPage)) { _ in
            if activeTab == .manage { Task { await loadData() } }
        }
    }

    // MARK: - Section 1: Backup Status

    private func backupStatusSection(_ health: InsightsHealth) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Backup Status", icon: "shield.lefthalf.filled")

            // Coverage bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Coverage")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(health.backupCoveragePercent, specifier: "%.1f")%")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(coverageColor(health.backupCoveragePercent))
                }

                GeometryReader { geo in
                    let width = geo.size.width
                    let total = max(health.uniqueHashes, 1)
                    let backedUp = CGFloat(health.backedUpHashes + health.redundantHashes)
                    let backedUpWidth = backedUp / CGFloat(total) * width

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 12)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.green)
                            .frame(width: max(backedUpWidth, 2), height: 12)
                    }
                }
                .frame(height: 12)
            }

            // Key numbers
            HStack(spacing: 0) {
                healthMetric(
                    value: formattedSize(health.backedUpBytes + health.redundantBytes),
                    label: "backed up",
                    color: .green
                )
                Spacer()
                healthMetric(
                    value: formattedSize(health.unprotectedBytes),
                    label: "at risk",
                    color: .red
                )
                Spacer()
                healthMetric(
                    value: formattedSize(health.reclaimableBytes),
                    label: "reclaimable",
                    color: .orange
                )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor).opacity(0.5)))

            // Drive risk ranking
            if let data = insightsData, !data.driveRisks.isEmpty {
                driveRiskSection(data.driveRisks)
            }
        }
    }

    private func healthMetric(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func driveRiskSection(_ risks: [DriveRisk]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Drive Risk")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if risks.count > 4 {
                    Button(showAllDrives ? "Show less" : "Show all \(risks.count)") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAllDrives.toggle()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            let visible = showAllDrives ? risks : Array(risks.prefix(4))
            ForEach(visible) { risk in
                driveRiskRow(risk)
            }
        }
    }

    private func driveRiskRow(_ risk: DriveRisk) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(riskColor(risk.riskLevel))
                .frame(width: 8, height: 8)

            Text(risk.driveName)
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 70, alignment: .leading)

            GeometryReader { geo in
                let maxBytes = insightsData?.driveRisks.first?.unprotectedBytes ?? 1
                let proportion = CGFloat(risk.unprotectedBytes) / CGFloat(max(maxBytes, 1))
                let barWidth = proportion * geo.size.width

                RoundedRectangle(cornerRadius: 3)
                    .fill(riskColor(risk.riskLevel).opacity(0.6))
                    .frame(width: max(barWidth, 2), height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 12)

            Text(formattedSize(risk.unprotectedBytes))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(riskColor(risk.riskLevel))
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Section 2: Duplikate & Platzgewinn

    private func duplicatesSection(_ data: InsightsResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Duplikate & Platzgewinn", icon: "doc.on.doc")

            // Same-drive duplicates from insights
            let sameDriveDupes = data.health.sameDriveDuplicates
            let reclaimable = data.health.reclaimableBytes

            HStack(spacing: 16) {
                statPill(
                    value: formatCount(sameDriveDupes),
                    label: "Same-drive Duplikate",
                    color: sameDriveDupes > 0 ? .orange : .green
                )
                statPill(
                    value: formattedSize(reclaimable),
                    label: "Reclaimable",
                    color: reclaimable > 0 ? .orange : .green
                )
            }

            // Folder duplicates (from DC-001 endpoint, graceful degradation)
            if let fd = folderDuplicates {
                if fd.stats.exactMatchGroups > 0 || fd.stats.subsetPairsFound > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Folder-Level")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if !fd.exactMatchGroups.isEmpty {
                            ForEach(fd.exactMatchGroups.prefix(5)) { group in
                                folderMatchCard(group)
                            }
                        }

                        if !fd.subsetPairs.isEmpty {
                            ForEach(fd.subsetPairs.prefix(3)) { pair in
                                subsetPairCard(pair)
                            }
                        }

                        if fd.stats.exactMatchGroups > 5 || fd.stats.subsetPairsFound > 3 {
                            Text("\(fd.stats.exactMatchGroups + fd.stats.subsetPairsFound) folder groups total")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("No duplicate folders found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // If folderDuplicates is nil, the endpoint was unavailable — silently omit
        }
    }

    private func folderMatchCard(_ group: ExactMatchGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill.badge.minus")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.folders.count) identical folders (\(group.hashCount) files)")
                    .font(.caption)
                    .fontWeight(.medium)
                ForEach(group.folders.prefix(3)) { folder in
                    Text("\(folder.driveName)/\(folder.folderPath)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            let totalBytes = group.folders.first?.totalBytes ?? 0
            let saveable = totalBytes * Int64(group.folders.count - 1)
            if saveable > 0 {
                Text(formattedSize(saveable))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor).opacity(0.5)))
    }

    private func subsetPairCard(_ pair: SubsetPair) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(pair.subsetFolder.driveName)/\(pair.subsetFolder.folderPath)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("contained in \(pair.supersetFolder.driveName)/\(pair.supersetFolder.folderPath) (\(pair.overlapPercent, specifier: "%.0f")%)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(formattedSize(pair.subsetFolder.totalBytes))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.blue)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor).opacity(0.5)))
    }

    private func statPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor).opacity(0.5)))
    }

    // MARK: - Section 3: Empfohlene Aktionen

    private func actionsSection(_ actions: [RecommendedAction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Empfohlene Aktionen", icon: "lightbulb")

            let dataAtRisk = actions.filter { $0.actionType == "backup" }
            let redundant = actions.first { $0.id == "trim_redundant" }
            let sameDrive = actions.first { $0.id == "clean_same_drive_dupes" }

            actionCard(
                title: "Data at Risk",
                subtitle: dataAtRisk.isEmpty ? "All files are backed up" : "\(dataAtRisk.count) drives with unprotected files",
                icon: "exclamationmark.shield.fill",
                color: .red,
                bytes: dataAtRisk.reduce(Int64(0)) { $0 + $1.impactBytes },
                action: dataAtRisk.first
            )

            actionCard(
                title: "Redundant Copies",
                subtitle: redundant?.description ?? "No files on 3+ drives",
                icon: "shield.fill",
                color: .blue,
                bytes: redundant?.impactBytes ?? 0,
                action: redundant
            )

            actionCard(
                title: "Same-Drive Copies",
                subtitle: sameDrive?.description ?? "No same-drive duplicates found",
                icon: "doc.on.doc.fill",
                color: .orange,
                bytes: sameDrive?.impactBytes ?? 0,
                action: sameDrive
            )
        }
    }

    private func actionCard(title: String, subtitle: String, icon: String, color: Color, bytes: Int64, action: RecommendedAction?) -> some View {
        Button {
            if let action { selectedAction = action }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if bytes > 0 {
                    Text(formattedSize(bytes))
                        .font(.callout)
                        .fontWeight(.bold)
                        .foregroundStyle(color)
                }

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.controlBackgroundColor)))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: - Shared Components

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = insightsData == nil
        errorMessage = nil

        async let insightsFetch: Void = loadInsights()
        async let folderFetch: Void = loadFolderDuplicates()
        _ = await (insightsFetch, folderFetch)

        isLoading = false
    }

    private func loadInsights() async {
        do {
            let fresh = try await APIService.shared.fetchInsights()
            insightsData = fresh
            ViewCache.save(fresh, key: "insights")
        } catch {
            if insightsData == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadFolderDuplicates() async {
        folderDuplicates = await APIService.shared.fetchFolderDuplicates()
    }

    // MARK: - Helpers

    private func coverageColor(_ pct: Double) -> Color {
        if pct >= 80 { return .green }
        if pct >= 50 { return .orange }
        return .red
    }

    private func riskColor(_ level: String) -> Color {
        switch level {
        case "critical": return .red
        case "high": return .orange
        case "moderate": return .yellow
        case "low": return .green
        default: return .gray
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000).\((n % 1_000_000) / 100_000)M" }
        if n >= 1_000 { return "\(n / 1_000).\((n % 1_000) / 100)K" }
        return "\(n)"
    }
}

#Preview {
    ManageView()
}
