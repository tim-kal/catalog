import SwiftUI

/// Settings view showing backend status, database stats, and app info.
struct SettingsView: View {
    @EnvironmentObject private var backend: BackendService
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var license = LicenseManager.shared

    @AppStorage("showConsolidatePage") private var showConsolidatePage = false
    @State private var licenseKeyInput = ""
    @State private var showBugReport = false
    @State private var healthStatus: HealthStatusResponse?
    @State private var isLoadingHealth = true
    @State private var healthError: String?
    @State private var errorEntries: [ErrorLogEntry] = []
    @State private var isLoadingErrors = false
    @State private var showResetConfirm = false
    @State private var isResetting = false
    @State private var resetComplete = false

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

            // How it works
            Section("How it Works") {
                VStack(alignment: .leading, spacing: 8) {
                    helpItem(icon: "1.circle.fill", color: .blue,
                        title: "Connect & Scan",
                        text: "Plug in an external drive. Catalog scans all files and computes hashes to identify duplicates.")
                    helpItem(icon: "2.circle.fill", color: .green,
                        title: "Browse & Search",
                        text: "Use the Files page to browse any drive's contents and search across all drives at once.")
                    helpItem(icon: "3.circle.fill", color: .orange,
                        title: "Check Backups",
                        text: "The Backups page shows which files are protected (on 2+ drives) and which are at risk (only on one drive).")
                    helpItem(icon: "4.circle.fill", color: .purple,
                        title: "Get Insights",
                        text: "Insights shows what's at risk, what's redundant, and what you can clean up to free space.")
                    helpItem(icon: "5.circle.fill", color: .red,
                        title: "Take Action",
                        text: "Queue copy or delete operations. Drives don't need to be connected — actions wait until the drive is plugged in.")
                }
                .padding(.vertical, 4)
            }

            // Error Log
            if backend.isRunning {
                Section("Error Log") {
                    if isLoadingErrors {
                        ProgressView()
                            .controlSize(.small)
                    } else if errorEntries.isEmpty {
                        Text("No errors recorded")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(errorEntries.prefix(10)) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(colorForSeverity(entry.severity))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(entry.code)
                                            .font(.system(.caption, design: .monospaced))
                                            .fontWeight(.medium)
                                        Text(entry.title)
                                            .font(.caption)
                                    }
                                    Text(entry.timestamp.prefix(19).replacingOccurrences(of: "T", with: " "))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.copyText, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help("Copy error details")
                            }
                        }
                        if errorEntries.count > 10 {
                            Text("\(errorEntries.count - 10) more errors...")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Danger Zone
            Section("Danger Zone") {
                if resetComplete {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("All data deleted. Restart the app to begin fresh.")
                            .font(.caption)
                    }
                } else {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text("Reset All Data")
                        }
                    }
                    .disabled(isResetting)

                    Text("Deletes all registered drives, scanned files, hashes, and operations. You will need to rescan everything. This cannot be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Bug Report
            Section("Feedback") {
                Button {
                    showBugReport = true
                } label: {
                    Label("Report a Bug", systemImage: "ladybug")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showBugReport) {
            BugReportView()
        }
        .alert("Reset All Data?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) {
                Task { await performReset() }
            }
        } message: {
            Text("This will permanently delete all registered drives, scanned files, hashes, and operations. You will need to rescan all drives from scratch.\n\nThis cannot be undone.")
        }
        .task(id: backend.isRunning) {
            if backend.isRunning {
                await loadHealth()
            }
        }
    }

    private func helpItem(icon: String, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(text).font(.caption).foregroundStyle(.secondary)
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
        await loadErrors()
    }

    private func performReset() async {
        isResetting = true
        do {
            let url = URL(string: "\(APIService.baseURL)/reset-all?confirm=true")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                resetComplete = true
                healthStatus = nil
            }
        } catch {
            healthError = "Reset failed: \(error.localizedDescription)"
        }
        isResetting = false
    }

    private func loadErrors() async {
        isLoadingErrors = true
        do {
            errorEntries = try await APIService.shared.fetchErrors(limit: 50)
        } catch {
            errorEntries = []
        }
        isLoadingErrors = false
    }

    private func colorForSeverity(_ severity: String) -> Color {
        switch severity {
        case "critical": return .red
        case "error": return .orange
        case "warning": return .yellow
        default: return .gray
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(BackendService.shared)
}
