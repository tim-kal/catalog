import SwiftUI

/// System-wide storage and protection overview dashboard.
struct ProtectionDashboard: View {
    let stats: ProtectionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top row: system storage overview
            HStack(spacing: 12) {
                statCard(
                    title: "Cataloged",
                    value: formattedSize(stats.totalStorageBytes),
                    icon: "internaldrive.fill",
                    color: .blue
                )
                statCard(
                    title: "Drives",
                    value: "\(stats.totalDrives)",
                    icon: "externaldrive.fill",
                    color: .secondary
                )
                statCard(
                    title: "Protected",
                    value: formattedSize(stats.backedUpBytes + stats.overBackedUpBytes),
                    icon: "checkmark.shield.fill",
                    color: .green
                )
                statCard(
                    title: "At Risk",
                    value: formattedSize(stats.unprotectedBytes),
                    icon: "exclamationmark.shield.fill",
                    color: .red
                )
            }

            // Backup coverage bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Backup Coverage")
                        .font(.headline)
                    Spacer()
                    Text("\(stats.backupCoveragePercent, specifier: "%.1f")%")
                        .font(.headline)
                        .foregroundStyle(coverageColor)
                }

                GeometryReader { geo in
                    let width = geo.size.width
                    let total = max(stats.uniqueHashes, 1)
                    let backedUpWidth = CGFloat(stats.backedUpFiles + stats.overBackedUpFiles) / CGFloat(total) * width
                    let unprotectedWidth = CGFloat(stats.unprotectedFiles) / CGFloat(total) * width

                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 8)

                        // Backed up (green)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green)
                            .frame(width: backedUpWidth, height: 8)
                    }
                }
                .frame(height: 8)

                // Legend
                HStack(spacing: 16) {
                    legendItem(color: .green, label: "Backed up", size: formattedSize(stats.backedUpBytes + stats.overBackedUpBytes))
                    legendItem(color: .red, label: "Unprotected", size: formattedSize(stats.unprotectedBytes))
                }
                .font(.caption)
            }
            .padding(10)
            .background(Color(.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)

            // Protection breakdown cards — bytes prominent, file count secondary
            HStack(spacing: 12) {
                protectionCard(
                    title: "No Backup",
                    bytes: stats.unprotectedBytes,
                    count: stats.unprotectedFiles,
                    icon: "exclamationmark.shield.fill",
                    color: .red
                )
                protectionCard(
                    title: "On 2 Drives",
                    bytes: stats.backedUpBytes,
                    count: stats.backedUpFiles,
                    icon: "checkmark.shield.fill",
                    color: .green
                )
                protectionCard(
                    title: "3+ Drives",
                    bytes: stats.overBackedUpBytes,
                    count: stats.overBackedUpFiles,
                    icon: "shield.fill",
                    color: .blue
                )
                protectionCard(
                    title: "Reclaimable",
                    bytes: stats.reclaimableBytes,
                    count: stats.sameDriveDuplicateCount,
                    icon: "doc.on.doc.fill",
                    color: .orange,
                    subtitle: "Same-drive duplicates"
                )
            }
        }
    }

    private var coverageColor: Color {
        if stats.backupCoveragePercent >= 80 { return .green }
        if stats.backupCoveragePercent >= 50 { return .orange }
        return .red
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        GroupBox {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(value)
                    .font(.callout)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
    }

    private func protectionCard(title: String, bytes: Int64, count: Int, icon: String, color: Color, subtitle: String? = nil) -> some View {
        GroupBox {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(formattedSize(bytes))
                    .font(.callout)
                    .fontWeight(.bold)
                Text("\(formatCount(count)) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(subtitle ?? title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
    }

    private func legendItem(color: Color, label: String, size: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) (\(size))")
                .foregroundStyle(.secondary)
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
