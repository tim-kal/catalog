import SwiftUI

struct Sidebar: View {
    @Binding var selection: SidebarItem?
    @AppStorage("showConsolidatePage") private var showConsolidatePage = false
    @EnvironmentObject private var updater: UpdateService

    private var visibleItems: [SidebarItem] {
        SidebarItem.allCases.filter { item in
            if item == .consolidate { return showConsolidatePage }
            return true
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var buildInfo: String {
        let commit = Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? "dev"
        let date = Bundle.main.infoDictionary?["BuildDate"] as? String ?? "local"
        return "\(commit) · \(date)"
    }

    var body: some View {
        VStack(spacing: 0) {
            List(visibleItems, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .listStyle(.sidebar)

            // Update banner
            if updater.updateAvailable, let version = updater.latestVersion {
                Divider()
                Button {
                    Task { await updater.downloadAndInstall() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.white)
                        Text("Update to v\(version)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            // Version info
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("DriveCatalog v\(appVersion)")
                        .font(.caption2)
                    Spacer()
                    Text("Build \(appBuild)")
                        .font(.caption2)
                }
                Text(buildInfo)
                    .font(.system(size: 9, design: .monospaced))
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
