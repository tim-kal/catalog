import Foundation

enum SidebarItem: String, CaseIterable, Identifiable {
    case drives
    case browser
    case duplicates
    case search
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .drives: return "Drives"
        case .browser: return "Browser"
        case .duplicates: return "Duplicates"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .drives: return "externaldrive"
        case .browser: return "folder"
        case .duplicates: return "doc.on.doc"
        case .search: return "magnifyingglass"
        case .settings: return "gear"
        }
    }
}
