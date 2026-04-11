import SwiftUI

/// Shows the verification report after a transfer completes.
struct TransferReportView: View {
    let transferId: Int
    var onDismiss: () -> Void

    @State private var report: TransferReportResponse?
    @State private var transfer: TransferResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isVerifying = false
    @State private var showFailedFiles = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Spacer()
                Text("Transfer Report")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text("Loading report...")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Spacer()
            } else if let errorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else if let report {
                ScrollView {
                    VStack(spacing: 20) {
                        // Big status icon
                        if report.allVerified {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.red)
                        }

                        // Summary text
                        Text(summaryText(report))
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)

                        // Duration
                        if let duration = report.durationSeconds {
                            Text(formattedDuration(duration))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Stats
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                statRow(label: "Total files", value: "\(report.totalFiles)")
                                statRow(label: "Total size", value: formattedSize(report.totalBytes))
                                statRow(label: "Files verified", value: "\(report.filesVerified)", color: .green)
                                if report.filesFailed > 0 {
                                    statRow(label: "Files failed", value: "\(report.filesFailed)", color: .red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Label("Details", systemImage: "list.bullet")
                        }

                        // Transfer info
                        if let transfer {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    statRow(label: "Source", value: transfer.sourceDrive)
                                    statRow(label: "Destination", value: transfer.destDrive)
                                    statRow(label: "Status", value: transfer.status.capitalized)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Label("Transfer", systemImage: "arrow.right.circle")
                            }
                        }

                        // Failed files
                        if !report.failedFiles.isEmpty {
                            GroupBox {
                                DisclosureGroup("Failed Files (\(report.failedFiles.count))", isExpanded: $showFailedFiles) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(report.failedFiles) { file in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(file.path)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Text(file.error)
                                                    .font(.caption2)
                                                    .foregroundStyle(.red)
                                            }
                                            Divider()
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            } label: {
                                Label("Failures", systemImage: "xmark.circle")
                                    .foregroundStyle(.red)
                            }
                        }

                        // Action buttons
                        HStack(spacing: 12) {
                            Button {
                                Task { await reverify() }
                            } label: {
                                HStack {
                                    if isVerifying {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text("Verify Again")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isVerifying)
                            .accessibilityIdentifier("verifyAgainButton")

                            Button("Done") {
                                onDismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("transferDoneButton")
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 450, minHeight: 500)
        .task { await loadReport() }
    }

    // MARK: - Helpers

    private func summaryText(_ report: TransferReportResponse) -> String {
        if report.allVerified {
            return "\(report.totalFiles) files, \(formattedSize(report.totalBytes)) transferred, all verified"
        } else {
            return "\(report.filesVerified) of \(report.totalFiles) files verified, \(report.filesFailed) failed"
        }
    }

    private func statRow(label: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(color)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds) seconds"
        }
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes) minutes \(secs) seconds"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours) hours \(mins) minutes"
    }

    // MARK: - Data Loading

    private func loadReport() async {
        isLoading = true
        errorMessage = nil
        do {
            async let reportFetch = APIService.shared.getTransferReport(transferId: transferId)
            async let transferFetch = APIService.shared.getTransferStatus(transferId: transferId)
            report = try await reportFetch
            transfer = try await transferFetch
        } catch {
            errorMessage = "Failed to load report: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func reverify() async {
        isVerifying = true
        do {
            let op = try await APIService.shared.verifyTransfer(transferId: transferId)
            // Poll until verification completes
            await pollVerification(operationId: op.operationId)
            // Reload report
            await loadReport()
        } catch {
            errorMessage = "Verification failed: \(error.localizedDescription)"
        }
        isVerifying = false
    }

    private func pollVerification(operationId: String) async {
        while true {
            do {
                let op = try await APIService.shared.fetchOperation(id: operationId)
                if op.status == "completed" || op.status == "failed" || op.status == "cancelled" {
                    return
                }
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }
}
