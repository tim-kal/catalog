import SwiftUI

/// Row view for a single search result.
struct SearchResultRow: View {
    let file: SearchFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(file.driveName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            }

            Spacer()

            Text(formattedSize(file.sizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
