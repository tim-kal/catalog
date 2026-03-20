import SwiftUI

/// System-wide storage and protection overview dashboard.
struct ProtectionDashboard: View {
    let stats: ProtectionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top row: system storage overview
            HStack(spacing: 12) {
                statCard(
                    title: "Total Storage",
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
                    title: "Files",
                    value: formatCount(stats.totalFiles),
                    icon: "doc.fill",
                    color: .secondary
                )
                statCard(
                    title: "Hashed",
                    value: "\(stats.hashedFiles)/\(stats.totalFiles)",
                    icon: "number",
                    color: stats.unhashedFiles > 0 ? .orange : .green
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
                    legendItem(color: .green, label: "Backed up", count: stats.backedUpFiles + stats.overBackedUpFiles)
                    legendItem(color: .red, label: "Unprotected", count: stats.unprotectedFiles)
                    if stats.unhashedFiles > 0 {
                        legendItem(color: .orange, label: "Not hashed", count: stats.unhashedFiles)
                    }
                }
                .font(.caption)
            }
            .padding(10)
            .background(Color(.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)

            // Protection breakdown cards
            HStack(spacing: 12) {
                protectionCard(
                    title: "Unprotected",
                    count: stats.unprotectedFiles,
                    bytes: stats.unprotectedBytes,
                    icon: "exclamationmark.shield.fill",
                    color: .red,
                    subtitle: "No backup"
                )
                protectionCard(
                    title: "Backed Up",
                    count: stats.backedUpFiles,
                    bytes: stats.backedUpBytes,
                    icon: "checkmark.shield.fill",
                    color: .green,
                    subtitle: "On 2 drives"
                )
                protectionCard(
                    title: "Redundant",
                    count: stats.overBackedUpFiles,
                    bytes: stats.overBackedUpBytes,
                    icon: "shield.fill",
                    color: .blue,
                    subtitle: "3+ drives"
                )
                protectionCard(
                    title: "Same-Drive Dupes",
                    count: stats.sameDriveDuplicateCount,
                    bytes: stats.reclaimableBytes,
                    icon: "doc.on.doc.fill",
                    color: .orange,
                    subtitle: "Reclaimable"
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

    private func protectionCard(title: String, count: Int, bytes: Int64, icon: String, color: Color, subtitle: String) -> some View {
        GroupBox {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(formatCount(count))
                    .font(.callout)
                    .fontWeight(.bold)
                Text(formattedSize(bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
    }

    private func legendItem(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) (\(formatCount(count)))")
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
