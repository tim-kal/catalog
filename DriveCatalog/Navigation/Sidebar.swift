import SwiftUI

struct Sidebar: View {
    @Binding var selection: SidebarItem?
    @AppStorage("showConsolidatePage") private var showConsolidatePage = false

    private var visibleItems: [SidebarItem] {
        SidebarItem.allCases.filter { item in
            if item == .consolidate { return showConsolidatePage }
            return true
        }
    }

    var body: some View {
        List(visibleItems, selection: $selection) { item in
            Label(item.title, systemImage: item.systemImage)
                .tag(item)
        }
        .listStyle(.sidebar)
    }
}

#Preview {
    @Previewable @State var selection: SidebarItem? = .drives
    Sidebar(selection: $selection)
}
