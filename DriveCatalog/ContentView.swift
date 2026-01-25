import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarItem? = .drives

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
        } detail: {
            switch selection {
            case .drives:
                DrivesView()
            case .browser:
                BrowserView()
            case .duplicates:
                DuplicatesView()
            case .search:
                SearchView()
            case .settings:
                SettingsView()
            case nil:
                DrivesView()
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

#Preview {
    ContentView()
}
