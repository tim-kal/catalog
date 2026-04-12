import SwiftUI

/// Lists past transfers with status badges and links to reports.
struct TransferHistoryView: View {
    @State private var transfers: [TransferResponse] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTransferId: Int?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Transfer History")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task { await loadTransfers() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text("Loading transfers...")
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
                    Button("Retry") { Task { await loadTransfers() } }
                        .buttonStyle(.bordered)
                }
                Spacer()
            } else if transfers.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No transfers yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("To transfer files between drives, expand a drive on the\nDrives page and click \"Transfer Files\".\nAll transfers are verified with SHA-256 checksums.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List(transfers) { transfer in
                    transferRow(transfer)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if transfer.status == "completed" || transfer.status == "failed" {
                                selectedTransferId = transfer.id
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: selectedTransferBinding) { transfer in
            TransferReportView(transferId: transfer.id) {
                selectedTransferId = nil
            }
        }
        .task { await loadTransfers() }
    }

    // MARK: - Row View

    private func transferRow(_ transfer: TransferResponse) -> some View {
        HStack(spacing: 12) {
            // Status badge
            statusBadge(transfer)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(transfer.sourceDrive)
                        .fontWeight(.medium)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transfer.destDrive)
                        .fontWeight(.medium)
                }

                HStack(spacing: 8) {
                    Text("\(transfer.totalFiles) files")
                    Text(formattedSize(transfer.totalBytes))
                    if let date = parseDate(transfer.createdAt) {
                        Text(date, style: .relative)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if transfer.status == "running" {
                ProgressView()
                    .controlSize(.small)
            } else if transfer.status == "completed" || transfer.status == "failed" {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ transfer: TransferResponse) -> some View {
        let (icon, color) = statusInfo(transfer)
        Image(systemName: icon)
            .font(.title2)
            .foregroundStyle(color)
    }

    private func statusInfo(_ transfer: TransferResponse) -> (String, Color) {
        switch transfer.status {
        case "completed":
            if transfer.filesFailed == 0 {
                return ("checkmark.circle.fill", .green)
            } else {
                return ("exclamationmark.circle.fill", .orange)
            }
        case "failed":
            return ("xmark.circle.fill", .red)
        case "running":
            return ("arrow.right.circle.fill", .blue)
        case "cancelled":
            return ("slash.circle.fill", .secondary)
        default:
            return ("circle.fill", .secondary)
        }
    }

    // MARK: - Helpers

    private var selectedTransferBinding: Binding<TransferResponse?> {
        Binding(
            get: {
                guard let id = selectedTransferId else { return nil }
                return transfers.first { $0.id == id }
            },
            set: { newValue in
                selectedTransferId = newValue?.id
            }
        )
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: - Data Loading

    private func loadTransfers() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await APIService.shared.listTransfers()
            transfers = response.transfers
        } catch {
            errorMessage = "Failed to load transfers: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
