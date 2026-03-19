import SwiftUI

/// Sheet view showing detailed file information and optional media metadata.
struct FileDetailSheet: View {
    let file: FileResponse

    @State private var mediaMetadata: MediaMetadataResponse?
    @State private var isLoadingMedia = false
    @State private var mediaError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("File Details")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Filename header
                    Text(file.filename)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(file.path)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)

                    // File Info
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            infoRow(label: "Drive", value: file.driveName)
                            infoRow(label: "Size", value: formattedSize(file.sizeBytes))
                            if let mtime = file.mtime {
                                infoRow(label: "Modified", value: mtime)
                            }
                            if let hash = file.partialHash {
                                HStack {
                                    Text("Partial Hash")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(hash)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("File Info", systemImage: "info.circle")
                    }

                    // Media Info (only for media files)
                    if file.isMedia {
                        GroupBox {
                            if isLoadingMedia {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading media info...")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                            } else if let mediaError {
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text(mediaError)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                            } else if let meta = mediaMetadata {
                                VStack(alignment: .leading, spacing: 10) {
                                    if let duration = meta.durationSeconds {
                                        infoRow(label: "Duration", value: formattedDuration(duration))
                                    }
                                    if let codec = meta.codecName {
                                        infoRow(label: "Codec", value: codec)
                                    }
                                    if let width = meta.width, let height = meta.height {
                                        infoRow(label: "Resolution", value: "\(width) x \(height)")
                                    }
                                    if let frameRate = meta.frameRate {
                                        infoRow(label: "Frame Rate", value: frameRate)
                                    }
                                    if let bitRate = meta.bitRate {
                                        infoRow(label: "Bit Rate", value: formattedBitRate(bitRate))
                                    }
                                    if let verifiedAt = meta.integrityVerifiedAt {
                                        HStack {
                                            Text("Integrity Verified")
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Image(systemName: meta.integrityErrors == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .foregroundStyle(meta.integrityErrors == nil ? .green : .red)
                                            Text(verifiedAt, style: .relative)
                                                .font(.caption)
                                        }
                                    }
                                    if let errors = meta.integrityErrors {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Integrity Errors")
                                                .foregroundStyle(.secondary)
                                            Text(errors)
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } label: {
                            Label("Media Info", systemImage: "film")
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 450, minHeight: 400)
        .task {
            if file.isMedia {
                await loadMediaMetadata()
            }
        }
    }

    // MARK: - Helpers

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func loadMediaMetadata() async {
        isLoadingMedia = true
        mediaError = nil
        do {
            mediaMetadata = try await APIService.shared.fetchFileMedia(fileId: file.id)
        } catch {
            mediaError = error.localizedDescription
        }
        isLoadingMedia = false
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func formattedBitRate(_ bitRate: Int) -> String {
        if bitRate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitRate) / 1_000_000)
        }
        return String(format: "%d kbps", bitRate / 1000)
    }
}
