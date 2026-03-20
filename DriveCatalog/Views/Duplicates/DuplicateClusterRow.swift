import SwiftUI

/// Row showing a file group with filename, protection status, and expandable locations.
struct FileGroupRow: View {
    let group: FileGroup
    @State private var showReclaim = false

    var body: some View {
        DisclosureGroup {
            ForEach(group.locations) { loc in
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(loc.driveName)
                        .font(.callout)
                        .fontWeight(.medium)
                    Text(loc.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 2)
            }
        } label: {
            HStack(spacing: 10) {
                // Status icon
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)

                // Filename
                Text(group.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Drive count badge
                HStack(spacing: 2) {
                    Image(systemName: "externaldrive.fill")
                        .font(.caption2)
                    Text("\(group.driveCount)")
                        .font(.caption)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(driveCountBackground)
                .clipShape(Capsule())

                // Same-drive duplicate warning
                if group.sameDriveExtras > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.caption2)
                        Text("+\(group.sameDriveExtras)")
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
                    .help("Same-drive duplicates")
                }

                Spacer()

                // File size
                Text(formattedSize(group.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Total copies
                Text("\(group.totalCopies) copies")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                // Reclaim button for over-backed-up
                if group.status == "over_backed_up" {
                    Button {
                        showReclaim = true
                    } label: {
                        Label("Reclaim", systemImage: "arrow.3.trianglepath")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                // Status label
                Text(statusLabel)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())
            }
        }
        .sheet(isPresented: $showReclaim) {
            ReclaimSheet(group: group)
        }
    }

    private var statusIcon: String {
        switch group.status {
        case "unprotected", "same_drive_duplicate":
            return "exclamationmark.shield.fill"
        case "backed_up":
            return "checkmark.shield.fill"
        case "over_backed_up":
            return "shield.fill"
        default:
            return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch group.status {
        case "unprotected", "same_drive_duplicate":
            return .red
        case "backed_up":
            return .green
        case "over_backed_up":
            return .blue
        default:
            return .secondary
        }
    }

    private var statusLabel: String {
        switch group.status {
        case "unprotected":
            return "No Backup"
        case "same_drive_duplicate":
            return "No Backup + Dupes"
        case "backed_up":
            return "Backed Up"
        case "over_backed_up":
            return "Redundant"
        default:
            return group.status
        }
    }

    private var driveCountBackground: Color {
        switch group.driveCount {
        case 1: return Color.red.opacity(0.15)
        case 2: return Color.green.opacity(0.15)
        default: return Color.blue.opacity(0.15)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
