import SwiftUI

struct ContentView: View {
    @State private var selectedTab: SidebarTab = .drives

    var body: some View {
        HStack(spacing: 0) {
            // Icon-only sidebar (NordVPN style)
            IconSidebar(selected: $selectedTab)

            Divider()

            // Main content
            Group {
                switch selectedTab {
                case .drives:
                    DriveDashboard()
                case .files:
                    PlaceholderPage(title: "Files", icon: "folder", description: "Browse cataloged files across all drives")
                case .manage:
                    ManagePage()
                case .transfers:
                    PlaceholderPage(title: "Transfer History", icon: "arrow.left.arrow.right", description: "View past transfers and verification reports")
                case .settings:
                    PlaceholderPage(title: "Settings", icon: "gear", description: "App preferences and configuration")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.windowBackgroundColor))
    }
}

// MARK: - Sidebar Tabs

enum SidebarTab: String, CaseIterable {
    case drives, files, manage, transfers, settings

    var icon: String {
        switch self {
        case .drives: return "externaldrive"
        case .files: return "folder"
        case .manage: return "rectangle.3.group"
        case .transfers: return "arrow.left.arrow.right"
        case .settings: return "gear"
        }
    }

    var label: String {
        switch self {
        case .drives: return "Drives"
        case .files: return "Files"
        case .manage: return "Manage"
        case .transfers: return "Transfers"
        case .settings: return "Settings"
        }
    }
}

// MARK: - Icon Sidebar

struct IconSidebar: View {
    @Binding var selected: SidebarTab

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selected = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18))
                            .frame(width: 36, height: 28)
                        Text(tab.label)
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(selected == tab ? .white : .secondary)
                    .frame(width: 56, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected == tab ? Color.accentColor.opacity(0.8) : .clear)
                    )
                }
                .buttonStyle(.plain)

                if tab == .manage {
                    Divider()
                        .frame(width: 32)
                        .padding(.vertical, 4)
                }
            }

            Spacer()

            // Version badge
            Text("v1.5.1")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .frame(width: 64)
        .background(Color(.controlBackgroundColor).opacity(0.5))
    }
}

// MARK: - Placeholder

struct PlaceholderPage: View {
    let title: String
    let icon: String
    let description: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .frame(width: 960, height: 640)
}
