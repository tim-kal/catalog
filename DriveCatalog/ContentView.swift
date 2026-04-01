import SwiftUI

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

                BackupsView()
                    .zIndex(selection == .backups ? 1 : 0)
                    .opacity(selection == .backups ? 1 : 0)
                    .allowsHitTesting(selection == .backups)

                InsightsView()
                    .zIndex(selection == .insights ? 1 : 0)
                    .opacity(selection == .insights ? 1 : 0)
                    .allowsHitTesting(selection == .insights)

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
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

#Preview {
    ContentView()
}
