import SwiftUI

@main
struct DriveCatalogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var backend = BackendService.shared
    @StateObject private var updater = UpdateService.shared
    @StateObject private var beta = BetaService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(backend)
                .environmentObject(updater)
                .onAppear {
                    backend.start()
                    Task { await updater.checkForUpdates() }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await UpdateService.shared.checkForUpdates() }
                }
            }
        }
    }
}
