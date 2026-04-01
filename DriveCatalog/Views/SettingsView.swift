import SwiftUI

/// Settings view showing backend status, database stats, and app info.
struct SettingsView: View {
    @EnvironmentObject private var backend: BackendService
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var license = LicenseManager.shared

    @AppStorage("showConsolidatePage") private var showConsolidatePage = false
    @State private var licenseKeyInput = ""
    @State private var healthStatus: HealthStatusResponse?
    @State private var isLoadingHealth = true
    @State private var healthError: String?

    var body: some View {
        Form {
            // Backend Status
            Section("Backend") {
                HStack {
                    Circle()
                        .fill(backend.isRunning ? .green : .red)
                        .frame(width: 10, height: 10)
                    Text(backend.isRunning ? "Running" : "Stopped")
                    Spacer()
                    if !backend.isRunning {
                        Button("Start") {
                            backend.start()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Restart") {
                            backend.stop()
                            Task {
                                try? await Task.sleep(for: .seconds(1))
                                backend.start()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let error = backend.startupError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                HStack {
                    Text("API URL")
                    Spacer()
                    Text(APIService.baseURL)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let health = healthStatus {
                    HStack {
                        Text("Database")
                        Spacer()
                        Text(health.dbPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if let error = healthError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Database Stats
            if backend.isRunning, let health = healthStatus {
                Section("Database Stats") {
                    HStack {
                        Text("Drives registered")
                        Spacer()
                        Text("\(health.drivesCount)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Files catalogued")
                        Spacer()
                        Text("\(health.filesCount.formatted())")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Files hashed")
                        Spacer()
                        Text("\(health.hashedCount.formatted())")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Hash coverage")
                            Spacer()
                            Text("\(health.hashCoveragePercent, specifier: "%.1f")%")
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: health.hashCoveragePercent / 100)
                            .tint(.purple)
                    }
                }
            }

            // Updates
            Section("Updates") {
                if updater.updateAvailable, let version = updater.latestVersion {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Version \(version) available")
                                .fontWeight(.medium)
                            if let notes = updater.releaseNotes {
                                Text(notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if updater.isDownloading {
                            ProgressView(value: updater.downloadProgress)
                                .frame(width: 100)
                        } else {
                            Button("Install Update") {
                                Task { await updater.downloadAndInstall() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    if let error = updater.updateError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    HStack {
                        Text("App is up to date")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") {
                            Task { await updater.checkForUpdates() }
                        }
                        .controlSize(.small)
                    }
                }
            }

            // License
            Section("License") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(license.tier.rawValue.capitalized)
                        .fontWeight(.medium)
                        .foregroundStyle(license.tier == .pro ? .green : .blue)
                }

                if license.tier != .pro {
                    HStack {
                        TextField("License Key", text: $licenseKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Activate") {
                            license.activate(key: licenseKeyInput)
                        }
                        .disabled(licenseKeyInput.isEmpty)
                        .controlSize(.small)
                    }
                } else {
                    HStack {
                        Text(license.licenseKey ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Deactivate") {
                            license.deactivate()
                        }
                        .controlSize(.small)
                    }
                }
            }

            // Features
            Section("Features") {
                Toggle("Show Consolidate page", isOn: $showConsolidatePage)
            }

            // About
            Section("About") {
                HStack {
                    Text("App")
                    Spacer()
                    Text("DriveCatalog")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(updater.currentVersion) (build \(updater.currentBuild))")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Description")
                    Spacer()
                    Text("Catalog, deduplicate, and verify files across external drives")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task(id: backend.isRunning) {
            if backend.isRunning {
                await loadHealth()
            }
        }
    }

    private func loadHealth() async {
        isLoadingHealth = true
        healthError = nil
        do {
            healthStatus = try await APIService.shared.fetchHealthStatus()
        } catch {
            healthError = error.localizedDescription
        }
        isLoadingHealth = false
    }
}

#Preview {
    SettingsView()
        .environmentObject(BackendService.shared)
}
