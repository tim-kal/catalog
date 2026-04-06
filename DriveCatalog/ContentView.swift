import SwiftUI

extension Notification.Name {
    static let refreshCurrentPage = Notification.Name("refreshCurrentPage")
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .drives
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @AppStorage("showConsolidatePage") private var showConsolidatePage = false

    var body: some View {
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
    }
}

#Preview {
    ContentView()
}
