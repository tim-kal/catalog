import SwiftUI

extension Notification.Name {
    static let refreshCurrentPage = Notification.Name("refreshCurrentPage")
}

struct ContentView: View {
    @EnvironmentObject private var backend: BackendService
    @State private var selection: SidebarItem? = .drives
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @AppStorage("showConsolidatePage") private var showConsolidatePage = false

    var body: some View {
        ZStack {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $selection)
        } detail: {
            ZStack {
                DrivesView()
                    .zIndex(selection == .drives ? 1 : 0)
                    .opacity(selection == .drives ? 1 : 0)
                    .allowsHitTesting(selection == .drives)

                BrowserView()
                    .zIndex(selection == .browser ? 1 : 0)
                    .opacity(selection == .browser ? 1 : 0)
                    .allowsHitTesting(selection == .browser)

                ManageView()
                    .zIndex(selection == .manage ? 1 : 0)
                    .opacity(selection == .manage ? 1 : 0)
                    .allowsHitTesting(selection == .manage)

                ActionQueueView()
                    .zIndex(selection == .queue ? 1 : 0)
                    .opacity(selection == .queue ? 1 : 0)
                    .allowsHitTesting(selection == .queue)

                if showConsolidatePage {
                    ConsolidatePageView()
                        .zIndex(selection == .consolidate ? 1 : 0)
                        .opacity(selection == .consolidate ? 1 : 0)
                        .allowsHitTesting(selection == .consolidate)
                }

                SettingsView()
                    .zIndex(selection == .settings ? 1 : 0)
                    .opacity(selection == .settings ? 1 : 0)
                    .allowsHitTesting(selection == .settings)
            }
            .environment(\.activeTab, selection)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(name: .refreshCurrentPage, object: nil)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh current page")
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)

            if backend.isMigrating || backend.migrationFailed {
                MigrationOverlay(
                    current: backend.migrationCurrent,
                    total: backend.migrationTotal,
                    description: backend.migrationDescription,
                    failed: backend.migrationFailed,
                    errorMessage: backend.migrationError
                )
            }
        } // ZStack
    }
}

// MARK: - Migration Overlay

struct MigrationOverlay: View {
    let current: Int
    let total: Int
    let description: String
    var failed: Bool = false
    var errorMessage: String = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)

                    Text("Database update failed")
                        .font(.title2.weight(.semibold))

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }

                    Text("Your data has been restored from backup.\nPlease contact support or use the previous app version.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    Text("Updating database...")
                        .font(.title2.weight(.semibold))

                    if total > 0 {
                        ProgressView(value: Double(current), total: Double(total))
                            .progressViewStyle(.linear)
                            .frame(width: 300)

                        Text("Step \(current) of \(total)")
                            .font(.headline)
                            .monospacedDigit()
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }

                    if !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text("Your existing data is being updated for the new version.\nNo rescanning needed.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

#Preview {
    ContentView()
}
