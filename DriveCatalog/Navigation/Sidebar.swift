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
        VStack(spacing: 0) {
            List(visibleItems, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .listStyle(.sidebar)

            // Version info
            Divider()
            HStack {
                Text("DriveCatalog v1.2")
                    .font(.caption2)
                Spacer()
                Text("Apr 2026")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

#Preview {
    @Previewable @State var selection: SidebarItem? = .drives
    Sidebar(selection: $selection)
}
