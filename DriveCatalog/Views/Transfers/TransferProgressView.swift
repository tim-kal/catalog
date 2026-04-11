import SwiftUI

/// Live progress view for an active transfer, polling every 500ms.
struct TransferProgressView: View {
    let transferId: Int
    var onComplete: (TransferResponse) -> Void
    var onCancelled: () -> Void

    @State private var transfer: TransferResponse?
    @State private var operation: OperationResponse?
    @State private var isCancelling = false
    @State private var startTime: Date = Date()
    @State private var pollTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Spacer()
                Text("Transfer in Progress")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            VStack(spacing: 24) {
                Spacer()

                // Progress ring
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: progressFraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progressFraction)
                    Text("\(Int(progressFraction * 100))%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 120, height: 120)

                // Stats
                VStack(spacing: 8) {
                    if let transfer {
                        // File counter
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.secondary)
                            Text("\(transfer.filesTransferred) / \(transfer.totalFiles) files")
                                .monospacedDigit()
                        }
                        .font(.title3)

                        // Bytes transferred
                        Text("\(formattedSize(transfer.bytesTransferred)) / \(formattedSize(transfer.totalBytes))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        // Speed
                        if let speed = transferSpeed {
                            Text(speed)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // ETA
                        if let eta = etaText {
                            Text(eta)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        ProgressView()
                            .controlSize(.large)
                        Text("Starting transfer...")
                            .foregroundStyle(.secondary)
                    }

                    // Current file
                    if let op = operation, op.filesProcessed < op.filesTotal {
                        Text("Processing file \(op.filesProcessed + 1)...")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                // Cancel button
                Button(role: .destructive) {
                    Task { await cancelTransfer() }
                } label: {
                    HStack {
                        if isCancelling {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isCancelling ? "Cancelling..." : "Cancel Transfer")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isCancelling)
                .padding(.bottom)
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 400)
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Computed

    private var progressFraction: Double {
        guard let t = transfer, t.totalBytes > 0 else { return 0 }
        return min(Double(t.bytesTransferred) / Double(t.totalBytes), 1.0)
    }

    private var transferSpeed: String? {
        guard let t = transfer, t.bytesTransferred > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 1 else { return nil }
        let bytesPerSec = Double(t.bytesTransferred) / elapsed
        let mbPerSec = bytesPerSec / (1024 * 1024)
        return String(format: "%.1f MB/s", mbPerSec)
    }

    private var etaText: String? {
        guard let t = transfer, t.bytesTransferred > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 2 else { return nil }
        let bytesPerSec = Double(t.bytesTransferred) / elapsed
        guard bytesPerSec > 0 else { return nil }
        let remaining = Double(t.totalBytes - t.bytesTransferred) / bytesPerSec
        return "ETA: \(formattedDuration(remaining))"
    }

    // MARK: - Helpers

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(secs)s"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }

    // MARK: - Polling

    private func startPolling() {
        startTime = Date()
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    let t = try await APIService.shared.getTransferStatus(transferId: transferId)
                    transfer = t

                    // Also fetch operation status for file-level info
                    if let opId = t.operationId {
                        operation = try? await APIService.shared.fetchOperation(id: opId)
                    }

                    if t.status == "completed" {
                        onComplete(t)
                        return
                    } else if t.status == "failed" || t.status == "cancelled" {
                        onCancelled()
                        return
                    }

                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func cancelTransfer() async {
        isCancelling = true
        do {
            try await APIService.shared.cancelTransfer(transferId: transferId)
        } catch {
            // Even if cancel fails, keep polling — backend may still stop
        }
    }
}
