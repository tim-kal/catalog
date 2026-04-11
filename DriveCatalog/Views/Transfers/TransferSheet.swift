import SwiftUI

/// Sheet for initiating a file transfer from one drive to another.
struct TransferSheet: View {
    let sourceDrive: DriveResponse
    var onStarted: (TransferResponse) -> Void

    @State private var drives: [DriveResponse] = []
    @State private var selectedDestDrive: String? = nil
    @State private var transferMode: TransferMode = .entireDrive
    @State private var folderPath: String = ""
    @State private var destFolder: String = ""
    @State private var isLoadingDrives = true
    @State private var isStarting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private enum TransferMode: String, CaseIterable {
        case entireDrive = "Entire drive"
        case specificFolder = "Specific folder"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Text("Transfer Files")
                    .font(.headline)
                Spacer()
                Button("Start Transfer") {
                    Task { await startTransfer() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedDestDrive == nil || isStarting)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Source
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow(label: "Drive", value: sourceDrive.name)
                            infoRow(label: "Mount", value: sourceDrive.mountPath)
                            infoRow(label: "Files", value: "\(sourceDrive.fileCount)")
                            infoRow(label: "Size", value: formattedSize(sourceDrive.totalBytes))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Source", systemImage: "externaldrive.fill")
                    }

                    // Path selection
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Mode", selection: $transferMode) {
                                ForEach(TransferMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)

                            if transferMode == .specificFolder {
                                HStack {
                                    Text("Folder:")
                                        .frame(width: 60, alignment: .trailing)
                                    TextField("e.g. DCIM/Photos", text: $folderPath)
                                        .textFieldStyle(.roundedBorder)
                                }
                                Text("Relative path from drive root")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Label("What to Transfer", systemImage: "folder.fill")
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
                        } else if availableDrives.isEmpty {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("No other mounted drives available")
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

                                if let dest = selectedDest {
                                    HStack {
                                        Text("Free:")
                                            .frame(width: 60, alignment: .trailing)
                                            .foregroundStyle(.secondary)
                                        Text(formattedSize(freeSpace(dest)))
                                            .foregroundColor(hasEnoughSpace(dest) ? .primary : .red)
                                        if !hasEnoughSpace(dest) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(.red)
                                            Text("Not enough space")
                                                .foregroundStyle(.red)
                                                .font(.caption)
                                        }
                                    }
                                }

                                HStack {
                                    Text("Folder:")
                                        .frame(width: 60, alignment: .trailing)
                                    TextField("Optional — preserves source structure", text: $destFolder)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    } label: {
                        Label("Destination", systemImage: "externaldrive.fill.badge.plus")
                    }

                    // Error
                    if let errorMessage {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal)
                    }

                    // Starting indicator
                    if isStarting {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting transfer...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 520, minHeight: 450)
        .task { await loadDrives() }
    }

    // MARK: - Computed

    private var availableDrives: [DriveResponse] {
        drives.filter {
            $0.name != sourceDrive.name
            && FileManager.default.fileExists(atPath: $0.mountPath)
        }
    }

    private var selectedDest: DriveResponse? {
        guard let name = selectedDestDrive else { return nil }
        return drives.first { $0.name == name }
    }

    private func freeSpace(_ drive: DriveResponse) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: drive.mountPath),
              let free = attrs[.systemFreeSize] as? Int64 else { return 0 }
        return free
    }

    private func hasEnoughSpace(_ drive: DriveResponse) -> Bool {
        freeSpace(drive) > sourceDrive.totalBytes
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

    // MARK: - Actions

    private func loadDrives() async {
        isLoadingDrives = true
        do {
            let response = try await APIService.shared.fetchDrives()
            drives = response.drives
        } catch {
            errorMessage = "Failed to load drives: \(error.localizedDescription)"
        }
        isLoadingDrives = false
    }

    private func startTransfer() async {
        guard let destDrive = selectedDestDrive else { return }
        isStarting = true
        errorMessage = nil

        let paths: [String]? = transferMode == .specificFolder && !folderPath.isEmpty
            ? [folderPath]
            : nil
        let folder: String? = destFolder.isEmpty ? nil : destFolder

        do {
            let transfer = try await APIService.shared.createTransfer(
                sourceDrive: sourceDrive.name,
                destDrive: destDrive,
                paths: paths,
                destFolder: folder
            )
            onStarted(transfer)
            dismiss()
        } catch let error as APIError {
            isStarting = false
            errorMessage = error.errorDescription
        } catch {
            isStarting = false
            errorMessage = "Transfer failed: \(error.localizedDescription)"
        }
    }
}
