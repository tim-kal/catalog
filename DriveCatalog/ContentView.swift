import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarItem? = .drives
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $selection)
        } detail: {
            ZStack {
                DrivesView()
                    .opacity(selection == .drives ? 1 : 0)
                    .allowsHitTesting(selection == .drives)

                BrowserView()
                    .opacity(selection == .browser ? 1 : 0)
                    .allowsHitTesting(selection == .browser)

                SearchView()
                    .opacity(selection == .search ? 1 : 0)
                    .allowsHitTesting(selection == .search)

                BackupsView()
                    .opacity(selection == .backups ? 1 : 0)
                    .allowsHitTesting(selection == .backups)

                InsightsView()
                    .opacity(selection == .insights ? 1 : 0)
                    .allowsHitTesting(selection == .insights)

                ActionQueueView()
                    .opacity(selection == .queue ? 1 : 0)
                    .allowsHitTesting(selection == .queue)

                ConsolidatePageView()
                    .opacity(selection == .consolidate ? 1 : 0)
                    .allowsHitTesting(selection == .consolidate)

                SettingsView()
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
