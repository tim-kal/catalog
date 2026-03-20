import SwiftUI

@main
struct DriveCatalogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var backend = BackendService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(backend)
                .onAppear {
                    backend.start()
                }
        }
    }
}
