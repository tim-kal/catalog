import SwiftUI

/// Row view for displaying a single file in the browser list.
struct FileRow: View {
    let file: FileResponse

    var body: some View {
        HStack(spacing: 12) {
            // File icon
            Image(systemName: file.isMedia ? "film.fill" : "doc.fill")
                .font(.title3)
                .foregroundStyle(file.isMedia ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.headline)
                    .lineLimit(1)

                Text(file.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Size badge
            Text(formattedSize(file.sizeBytes))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.2))
                .clipShape(Capsule())

            // Hash indicator
            if file.partialHash != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.gray)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
