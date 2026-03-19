import SwiftUI

/// Settings view showing API connection status, database stats, and app info.
struct SettingsView: View {
    @State private var healthStatus: HealthStatusResponse?
    @State private var isLoadingHealth = true
    @State private var healthError: String?
    @State private var isConnected = false

    var body: some View {
        Form {
            // API Connection
            Section("API Connection") {
                HStack {
                    Circle()
                        .fill(isConnected ? .green : .red)
                        .frame(width: 10, height: 10)
                    Text(isConnected ? "Connected" : "Disconnected")
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

                if isLoadingHealth {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking connection...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await loadHealth() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }

            // Database Stats
            if isConnected, let health = healthStatus {
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
        .task {
            await loadHealth()
        }
    }

    private func loadHealth() async {
        isLoadingHealth = true
        healthError = nil
        do {
            healthStatus = try await APIService.shared.fetchHealthStatus()
            isConnected = true
        } catch {
            isConnected = false
            healthError = error.localizedDescription
        }
        isLoadingHealth = false
    }
}

#Preview {
    SettingsView()
}
