import SwiftUI

/// Stats summary cards showing duplicate statistics.
struct DuplicateStatsHeader: View {
    let stats: DuplicateStatsResponse

    var body: some View {
        HStack(spacing: 12) {
            statCard(title: "Clusters", value: "\(stats.totalClusters)", icon: "square.stack.3d.up.fill", color: .blue)
            statCard(title: "Duplicate Files", value: "\(stats.totalDuplicateFiles)", icon: "doc.on.doc.fill", color: .purple)
            statCard(title: "Total Size", value: formattedSize(stats.totalBytes), icon: "internaldrive.fill", color: .secondary)
            statCard(title: "Reclaimable", value: formattedSize(stats.reclaimableBytes), icon: "arrow.uturn.backward.circle.fill", color: .orange)
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        GroupBox {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(value)
                    .font(.title3)
                    .fontWeight(.bold)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
