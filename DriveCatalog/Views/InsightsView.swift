import SwiftUI

/// Unified insights page: backup health, risk assessment, and recommended actions.
struct InsightsView: View {
    @Environment(\.activeTab) private var activeTab
    @ObservedObject private var backend = BackendService.shared
    @State private var data: InsightsResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showAllDrives = false
    @State private var selectedAction: RecommendedAction?

    var body: some View {
        Group {
            if let action = selectedAction {
                ActionDrillDownView(action: action, onBack: { selectedAction = nil })
            } else {
                insightsContent
            }
        }
        .task {
            if data == nil { data = ViewCache.load(InsightsResponse.self, key: "insights") }
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

    private var insightsContent: some View {
        Group {
            if isLoading && data == nil {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Analyzing your drives...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, data == nil {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Failed to load insights")
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
            } else if let data {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        healthSection(data.health)
                        Divider()
                        actionsSection(data.actions)
                        Divider()
                        driveRiskSection(data.driveRisks)
                        Divider()
                        contentSection(data.atRiskContent)
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Insights")
        .onReceive(NotificationCenter.default.publisher(for: .refreshCurrentPage)) { _ in
            if activeTab == .manage { Task { await loadData() } }
        }
    }

    // MARK: - Health Section

    private func healthSection(_ health: InsightsHealth) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Coverage bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Backup Health")
                        .font(.title3)
                        .fontWeight(.semibold)
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

            // Key numbers — show bytes, not file counts
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

            // Quick stats row
            HStack(spacing: 16) {
                miniStat(icon: "externaldrive.fill", value: "\(health.totalDrives)", label: "drives")
                miniStat(icon: "doc.fill", value: formatCount(health.totalFiles), label: "files")
                miniStat(icon: "internaldrive.fill", value: formattedSize(health.totalStorageBytes), label: "cataloged")
                if health.sameDriveDuplicates > 0 {
                    miniStat(icon: "doc.on.doc.fill", value: formatCount(health.sameDriveDuplicates), label: "same-drive dupes")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private func miniStat(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text("\(value) \(label)")
        }
    }

    // MARK: - Actions Section

    private func actionsSection(_ actions: [RecommendedAction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Three fixed categories
            let dataAtRisk = actions.filter { $0.actionType == "backup" }
            let redundant = actions.first { $0.id == "trim_redundant" }
            let sameDrive = actions.first { $0.id == "clean_same_drive_dupes" }

            // 1. Data at Risk
            categoryCard(
                title: "Data at Risk",
                subtitle: dataAtRisk.isEmpty ? "All files are backed up" : "\(dataAtRisk.count) drives with unprotected files",
                icon: "exclamationmark.shield.fill",
                color: .red,
                bytes: dataAtRisk.reduce(Int64(0)) { $0 + $1.impactBytes },
                action: dataAtRisk.first
            )

            // 2. Redundant Copies
            categoryCard(
                title: "Redundant Copies",
                subtitle: redundant?.description ?? "No files on 3+ drives",
                icon: "shield.fill",
                color: .blue,
                bytes: redundant?.impactBytes ?? 0,
                action: redundant
            )

            // 3. Same-Drive Copies
            categoryCard(
                title: "Same-Drive Copies",
                subtitle: sameDrive?.description ?? "No same-drive duplicates found",
                icon: "doc.on.doc.fill",
                color: .orange,
                bytes: sameDrive?.impactBytes ?? 0,
                action: sameDrive
            )
        }
    }

    private func categoryCard(title: String, subtitle: String, icon: String, color: Color, bytes: Int64, action: RecommendedAction?) -> some View {
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

    // MARK: - Drive Risk Section

    private func driveRiskSection(_ risks: [DriveRisk]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Drive Risk Ranking")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if risks.count > 6 {
                    Button(showAllDrives ? "Show less" : "Show all \(risks.count)") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAllDrives.toggle()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            let visibleRisks = showAllDrives ? risks : Array(risks.prefix(6))

            ForEach(visibleRisks) { risk in
                driveRiskRow(risk)
            }
        }
    }

    private func driveRiskRow(_ risk: DriveRisk) -> some View {
        HStack(spacing: 10) {
            // Risk indicator
            Circle()
                .fill(riskColor(risk.riskLevel))
                .frame(width: 10, height: 10)

            // Drive name
            Text(risk.driveName)
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(width: 70, alignment: .leading)

            // Unprotected bar (proportional)
            GeometryReader { geo in
                let maxBytes = data?.driveRisks.first?.unprotectedBytes ?? 1
                let proportion = CGFloat(risk.unprotectedBytes) / CGFloat(max(maxBytes, 1))
                let barWidth = proportion * geo.size.width

                RoundedRectangle(cornerRadius: 3)
                    .fill(riskColor(risk.riskLevel).opacity(0.6))
                    .frame(width: max(barWidth, 2), height: 8)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            // Stats
            Text(formattedSize(risk.unprotectedBytes))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(riskColor(risk.riskLevel))
                .frame(width: 65, alignment: .trailing)

            Text("\(risk.freePercent, specifier: "%.0f")% free")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    // MARK: - Content Section

    private func contentSection(_ content: [AtRiskContent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's at Risk")
                .font(.title3)
                .fontWeight(.semibold)

            ForEach(content) { cat in
                contentRow(cat)
            }
        }
    }

    private func contentRow(_ cat: AtRiskContent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cat.icon)
                .font(.body)
                .foregroundStyle(cat.category == "Cache / Metadata" ? .secondary : .primary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(cat.category)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if cat.category == "Cache / Metadata" {
                        Text("safe to ignore")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                Text(cat.topExtensions.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(formattedSize(cat.totalBytes))
                    .font(.callout)
                    .fontWeight(.medium)
                Text("\(formatCount(cat.fileCount)) files")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .opacity(cat.category == "Cache / Metadata" ? 0.6 : 1.0)
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = data == nil
        errorMessage = nil
        do {
            let fresh = try await APIService.shared.fetchInsights()
            data = fresh
            ViewCache.save(fresh, key: "insights")
        } catch {
            if data == nil {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
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
    InsightsView()
}
