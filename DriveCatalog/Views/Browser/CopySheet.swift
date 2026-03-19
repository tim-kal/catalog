import SwiftUI

/// Sheet for performing a verified file copy from one drive to another.
struct CopySheet: View {
    let sourceFile: FileResponse
    var onComplete: () async -> Void

    @State private var drives: [DriveResponse] = []
    @State private var selectedDestDrive: String? = nil
    @State private var destPath: String = ""
    @State private var isLoadingDrives = true
    @State private var isCopying = false
    @State private var activeOperation: OperationResponse?
    @State private var copyResult: CopyResult?
    @Environment(\.dismiss) private var dismiss

    private enum CopyResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Text("Copy File")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    Task { await startCopy() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedDestDrive == nil || isCopying)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Source info
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow(label: "Drive", value: sourceFile.driveName)
                            infoRow(label: "Path", value: sourceFile.path)
                            infoRow(label: "Size", value: formattedSize(sourceFile.sizeBytes))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Source", systemImage: "doc.fill")
                    }

                    // Destination
                    GroupBox {
                        if isLoadingDrives {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading drives...")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Drive:")
                                        .frame(width: 60, alignment: .trailing)
                                    Picker("Destination Drive", selection: $selectedDestDrive) {
                                        Text("Select...").tag(nil as String?)
                                        ForEach(availableDrives) { drive in
                                            Text(drive.name).tag(drive.name as String?)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                }
                                HStack {
                                    Text("Path:")
                                        .frame(width: 60, alignment: .trailing)
                                    TextField("Destination path", text: $destPath)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    } label: {
                        Label("Destination", systemImage: "folder.fill")
                    }

                    // Progress section
                    if isCopying, let operation = activeOperation {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(operationStatusText(operation))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let progress = operation.progressPercent {
                                        Text("\(Int(progress))%")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let progress = operation.progressPercent {
                                    ProgressView(value: progress / 100)
                                        .tint(.blue)
                                }
                            }
                        } label: {
                            Label("Progress", systemImage: "arrow.right.circle.fill")
                        }
                    }

                    // Result section
                    if let result = copyResult {
                        GroupBox {
                            HStack {
                                switch result {
                                case .success(let message):
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.title2)
                                    Text(message)
                                        .foregroundStyle(.green)
                                case .failure(let message):
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .font(.title2)
                                    Text(message)
                                        .foregroundStyle(.red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Label("Result", systemImage: "checkmark.shield.fill")
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .task {
            destPath = sourceFile.path
            await loadDrives()
        }
    }

    // MARK: - Computed

    private var availableDrives: [DriveResponse] {
        drives.filter { $0.name != sourceFile.driveName }
    }

    // MARK: - Helpers

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func operationStatusText(_ operation: OperationResponse) -> String {
        switch operation.status {
        case "pending":
            return "Waiting to start..."
        case "running":
            return "Copying and verifying..."
        default:
            return operation.status.capitalized
        }
    }

    // MARK: - Data Loading

    private func loadDrives() async {
        isLoadingDrives = true
        do {
            let response = try await APIService.shared.fetchDrives()
            drives = response.drives
        } catch {
            copyResult = .failure("Failed to load drives: \(error.localizedDescription)")
        }
        isLoadingDrives = false
    }

    private func startCopy() async {
        guard let destDrive = selectedDestDrive else { return }
        isCopying = true
        copyResult = nil

        let request = CopyRequest(
            sourceDrive: sourceFile.driveName,
            sourcePath: sourceFile.path,
            destDrive: destDrive,
            destPath: destPath.isEmpty ? nil : destPath
        )

        do {
            let startResponse = try await APIService.shared.triggerCopy(request: request)
            await pollOperation(id: startResponse.operationId)
        } catch {
            isCopying = false
            copyResult = .failure("Copy failed: \(error.localizedDescription)")
        }
    }

    private func pollOperation(id: String) async {
        while true {
            do {
                let operation = try await APIService.shared.fetchOperation(id: id)
                activeOperation = operation

                if operation.status == "completed" {
                    activeOperation = nil
                    isCopying = false
                    copyResult = .success("Copy verified successfully")
                    await onComplete()
                    break
                } else if operation.status == "failed" {
                    activeOperation = nil
                    isCopying = false
                    copyResult = .failure(operation.error ?? "Copy failed")
                    break
                }

                try await Task.sleep(for: .seconds(2))
            } catch {
                activeOperation = nil
                isCopying = false
                copyResult = .failure("Lost connection: \(error.localizedDescription)")
                break
            }
        }
    }
}
