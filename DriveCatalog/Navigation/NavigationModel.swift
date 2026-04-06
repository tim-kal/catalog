import Foundation
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case drives
    case browser
    case manage
    case queue
    case consolidate
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .drives: return "Drives"
        case .browser: return "Files"
        case .manage: return "Manage"
        case .queue: return "Action Queue"
        case .consolidate: return "Consolidate"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .drives: return "externaldrive"
        case .browser: return "folder"
        case .manage: return "rectangle.3.group"
        case .queue: return "list.bullet.clipboard"
        case .consolidate: return "arrow.triangle.merge"
        case .settings: return "gear"
        }
    }
}

// MARK: - Active Tab Environment Key

private struct ActiveTabKey: EnvironmentKey {
    static let defaultValue: SidebarItem? = .drives
}

extension EnvironmentValues {
    var activeTab: SidebarItem? {
        get { self[ActiveTabKey.self] }
        set { self[ActiveTabKey.self] = newValue }
    }
}
