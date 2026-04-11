import SwiftUI

/// A discovered volume mounted under /Volumes/.
private struct MountedVolume: Identifiable {
    let name: String
    let path: String
    let totalBytes: Int64
    /// Name of the registered drive this volume was recognized as, if any.
    var recognizedAs: String?
    /// True when recognition returned multiple ambiguous candidates.
    var isAmbiguous: Bool = false
    /// Candidate registered drives returned by ambiguous recognition.
    var ambiguousCandidates: [DriveResponse] = []
    var id: String { path }
}

/// Sheet for adding a new drive to the catalog.
/// Discovers mounted volumes and lets the user pick one.
struct AddDriveSheet: View {
    private struct AmbiguousSelectionInfo: Identifiable {
        let volume: MountedVolume
        var id: String { volume.id }
    }

    @State private var volumes: [MountedVolume] = []
    @State private var selectedVolume: MountedVolume?
    @State private var customName: String = ""
    @State private var ambiguousSelection: AmbiguousSelectionInfo?
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
                .accessibilityIdentifier("addDriveConfirmButton")
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

                // Ambiguous volumes — can't be registered until disambiguated
                if !ambiguousVolumes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Ambiguous Drives")
                                .font(.subheadline.bold())
                        }
                        Text("These volumes match multiple registered drives. Connect them from the main view to identify.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(ambiguousVolumes) { volume in
                            Button {
                                ambiguousSelection = AmbiguousSelectionInfo(volume: volume)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "externaldrive.badge.questionmark")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(volume.name)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                        Text("Matches \(volume.ambiguousCandidates.count) registered drives")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
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
        .sheet(item: $ambiguousSelection) { info in
            AmbiguousDriveResolveSheet(
                volume: info.volume,
                onResolved: {
                    await onAdded()
                    await loadVolumes()
                }
            )
        }
    }

    /// Volumes not yet registered (recognized by cascade, not just path comparison).
    private var availableVolumes: [MountedVolume] {
        volumes.filter { $0.recognizedAs == nil && !$0.isAmbiguous }
    }

    /// Volumes with ambiguous recognition — match multiple registered drives.
    private var ambiguousVolumes: [MountedVolume] {
        volumes.filter { $0.isAmbiguous }
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

        // 2. Recognize each volume using cascade endpoint to filter already-registered
        for i in discovered.indices {
            if let response = try? await APIService.shared.recognizeDrive(mountPath: discovered[i].path) {
                if (response.status == "recognized" || response.status == "weak_match"),
                   let driveName = response.drive?.name {
                    discovered[i].recognizedAs = driveName
                } else if response.status == "ambiguous" {
                    discovered[i].isAmbiguous = true
                    discovered[i].ambiguousCandidates = response.candidates ?? []
                }
            }
        }

        volumes = discovered
        isLoading = false
    }

    // MARK: - Actions

    private func addDrive() async {
        guard let volume = selectedVolume else { return }
        await addDrive(volume: volume, forceNew: false)
    }

    private func addDrive(volume: MountedVolume, forceNew: Bool) async {
        isSubmitting = true
        errorMessage = nil
        do {
            let name = customName.isEmpty ? nil : customName
            _ = try await APIService.shared.createDrive(path: volume.path, name: name, forceNew: forceNew)
            await onAdded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - Ambiguous Resolve Sheet

private struct AmbiguousDriveResolveSheet: View {
    let volume: MountedVolume
    var onResolved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCandidate: DriveResponse?
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Text("Identify Drive")
                    .font(.headline)

                Spacer()

                Button("Confirm") {
                    Task { await resolveToExisting() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCandidate == nil || isSubmitting)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(volume.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(volume.ambiguousCandidates) { candidate in
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundStyle(selectedCandidate?.id == candidate.id ? .white : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.name)
                                        .foregroundStyle(selectedCandidate?.id == candidate.id ? .white : .primary)
                                    Text("\(candidate.fileCount) files")
                                        .font(.caption)
                                        .foregroundStyle(selectedCandidate?.id == candidate.id ? .white.opacity(0.8) : .secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedCandidate?.id == candidate.id ? Color.accentColor : Color(.controlBackgroundColor))
                            )
                            .onTapGesture {
                                selectedCandidate = (selectedCandidate?.id == candidate.id) ? nil : candidate
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Divider()
                    .padding(.top, 4)

                Button("None of these — register as new drive") {
                    Task { await registerAsNew() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isSubmitting)
                .padding(.horizontal)
                .padding(.bottom, 8)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 340)
    }

    private func resolveToExisting() async {
        guard let selectedCandidate else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await APIService.shared.resolveAmbiguousDrive(
                mountPath: volume.path,
                driveId: selectedCandidate.id
            )
            await onResolved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    private func registerAsNew() async {
        isSubmitting = true
        errorMessage = nil
        do {
            _ = try await APIService.shared.createDrive(
                path: volume.path,
                name: nil,
                forceNew: true
            )
            await onResolved()
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
