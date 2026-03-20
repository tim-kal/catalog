import AppKit
import SwiftUI

/// App delegate that intercepts Cmd+Q to warn about active operations.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Check if the backend is even running
        guard BackendService.shared.isRunning else {
            return .terminateNow
        }

        // Query active operations asynchronously
        Task { @MainActor in
            let hasActive = await checkForActiveOperations()

            if hasActive {
                let alert = NSAlert()
                alert.messageText = "Operations in Progress"
                alert.informativeText = "A scan, hash, or copy operation is still running. Quitting now will cancel it.\n\nAre you sure you want to quit?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                } else {
                    NSApplication.shared.reply(toApplicationShouldTerminate: false)
                }
            } else {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    private func checkForActiveOperations() async -> Bool {
        do {
            let response = try await APIService.shared.fetchOperations(limit: 10)
            return response.operations.contains { $0.isActive }
        } catch {
            // If we can't reach the API, just let the app quit
            return false
        }
    }
}
