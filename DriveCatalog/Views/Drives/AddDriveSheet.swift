import SwiftUI

/// A discovered volume mounted under /Volumes/.
private struct MountedVolume: Identifiable {
    let name: String
    let path: String
    let totalBytes: Int64
    var id: String { path }
}

/// Sheet for adding a new drive to the catalog.
/// Discovers mounted volumes and lets the user pick one.
struct AddDriveSheet: View {
    @State private var volumes: [MountedVolume] = []
    @State private var registeredPaths: Set<String> = []
    @State private var selectedVolume: MountedVolume?
    @State private var customName: String = ""
    @State private var isSubmitting = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    /// Callback invoked after a drive is successfully added.
    var onAdded: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("Add Drive")
                    .font(.headline)

                Spacer()

                Button("Add") {
                    Task { await addDrive() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedVolume == nil || isSubmitting)
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Scanning volumes...")
                Spacer()
            } else if availableVolumes.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No new drives found")
                        .font(.headline)
                    Text("All mounted volumes are already registered, or no external drives are connected.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(availableVolumes) { volume in
                            VolumeCard(
                                volume: volume,
                                isSelected: selectedVolume?.id == volume.id
                            )
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if selectedVolume?.id == volume.id {
                                        selectedVolume = nil
                                    } else {
                                        selectedVolume = volume
                                        customName = ""
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }

                // Custom name (only when a volume is selected)
                if selectedVolume != nil {
                    Divider()
                    HStack {
                        Text("Name:")
                            .foregroundStyle(.secondary)
                        TextField(
                            "Custom name",
                            text: $customName,
                            prompt: Text(selectedVolume?.name ?? "")
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }

            // Error / progress
            if let errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if isSubmitting {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Registering drive...")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 440, minHeight: 340)
        .task {
            await loadVolumes()
        }
    }

    /// Volumes not yet registered.
    private var availableVolumes: [MountedVolume] {
        volumes.filter { !registeredPaths.contains($0.path) }
    }

    // MARK: - Data Loading

    private func loadVolumes() async {
        isLoading = true

        // 1. Discover mounted volumes from filesystem
        let fm = FileManager.default
        let volumesDir = "/Volumes"
        var discovered: [MountedVolume] = []

        if let contents = try? fm.contentsOfDirectory(atPath: volumesDir) {
            for name in contents.sorted() {
                let fullPath = "\(volumesDir)/\(name)"

                // Skip symlinks (Macintosh HD is often a symlink to /)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                // Get volume size
                let totalBytes: Int64
                if let attrs = try? fm.attributesOfFileSystem(forPath: fullPath),
                   let size = attrs[.systemSize] as? Int64 {
                    totalBytes = size
                } else {
                    totalBytes = 0
                }

                discovered.append(MountedVolume(
                    name: name,
                    path: fullPath,
                    totalBytes: totalBytes
                ))
            }
        }

        volumes = discovered

        // 2. Fetch already-registered drives to grey them out
        if let response = try? await APIService.shared.fetchDrives() {
            registeredPaths = Set(response.drives.map(\.mountPath))
        }

        isLoading = false
    }

    // MARK: - Actions

    private func addDrive() async {
        guard let volume = selectedVolume else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            let name = customName.isEmpty ? nil : customName
            _ = try await APIService.shared.createDrive(path: volume.path, name: name)
            await onAdded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - Volume Card

private struct VolumeCard: View {
    let volume: MountedVolume
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundStyle(isSelected ? .white : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name)
                    .font(.headline)
                    .foregroundStyle(isSelected ? .white : .primary)

                Text(volume.path)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }

            Spacer()

            Text(formattedSize(volume.totalBytes))
                .font(.callout)
                .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    AddDriveSheet(onAdded: {})
}
