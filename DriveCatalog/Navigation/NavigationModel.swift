import Foundation

enum SidebarItem: String, CaseIterable, Identifiable {
    case drives
    case browser
    case backups
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .drives: return "Drives"
        case .browser: return "Browser"
        case .backups: return "Backups"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .drives: return "externaldrive"
        case .browser: return "folder"
        case .backups: return "shield.lefthalf.filled"
        case .settings: return "gear"
        }
    }
}
