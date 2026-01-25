import SwiftUI

/// Sheet for adding a new drive to the catalog.
struct AddDriveSheet: View {
    @State private var path: String = ""
    @State private var customName: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil
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
                .disabled(path.isEmpty || isSubmitting)
            }
            .padding()

            Divider()

            // Form content
            Form {
                Section {
                    TextField("Path", text: $path, prompt: Text("/Volumes/MyDrive"))
                        .textFieldStyle(.roundedBorder)
                    Text("Enter the mount path of the drive (e.g., /Volumes/MyDrive)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Name (optional)", text: $customName, prompt: Text("Custom name"))
                        .textFieldStyle(.roundedBorder)
                    Text("If not provided, the drive name will be derived from the path")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if isSubmitting {
                    Section {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Adding drive...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private func addDrive() async {
        isSubmitting = true
        errorMessage = nil
        do {
            let name = customName.isEmpty ? nil : customName
            _ = try await APIService.shared.createDrive(path: path, name: name)
            await onAdded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}

#Preview {
    AddDriveSheet(onAdded: {})
}
