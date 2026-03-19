import SwiftUI

/// Expandable row showing a cluster of duplicate files.
struct DuplicateClusterRow: View {
    let cluster: DuplicateCluster

    var body: some View {
        DisclosureGroup {
            ForEach(cluster.files) { file in
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(file.driveName)
                        .font(.callout)
                        .fontWeight(.medium)
                    Text(file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 2)
            }
        } label: {
            HStack(spacing: 12) {
                // Hash badge
                Text(String(cluster.partialHash.prefix(8)))
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())

                // File count
                Text("\(cluster.count) copies")
                    .font(.callout)

                Spacer()

                // Size
                Text(formattedSize(cluster.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Reclaimable badge
                Text("\(formattedSize(cluster.reclaimableBytes)) reclaimable")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
