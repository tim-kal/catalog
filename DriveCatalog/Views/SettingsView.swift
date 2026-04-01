import SwiftUI

/// Settings view showing backend status, database stats, and app info.
struct SettingsView: View {
    @EnvironmentObject private var backend: BackendService

    @AppStorage("showConsolidatePage") private var showConsolidatePage = false
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
                    Text("1.1")
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
