import Foundation

/// Manages app licensing: beta → free → pro.
/// Currently returns .beta for all users. License validation
/// can be added later (e.g. via Lemon Squeezy API).
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    enum Tier: String {
        case beta       // Full access, no time limit
        case free       // Limited (e.g. max 3 drives)
        case pro        // Full access with license key
    }

    @Published var tier: Tier = .beta
    @Published var licenseKey: String? = nil

    /// Limits for the free tier.
    static let freeDriveLimit = 3

    private init() {
        // Load saved license key
        if let saved = UserDefaults.standard.string(forKey: "licenseKey"), !saved.isEmpty {
            licenseKey = saved
            tier = .pro  // Will be validated on next check
        }
    }

    /// Whether the current tier allows a feature.
    func canUse(feature: Feature) -> Bool {
        switch tier {
        case .beta, .pro:
            return true
        case .free:
            switch feature {
            case .unlimitedDrives: return false
            case .insights: return false
            case .actionQueue: return false
            case .browse, .backups, .settings: return true
            }
        }
    }

    /// Check if adding another drive is allowed.
    func canAddDrive(currentCount: Int) -> Bool {
        switch tier {
        case .beta, .pro: return true
        case .free: return currentCount < Self.freeDriveLimit
        }
    }

    /// Activate a license key. For now just saves it — real validation comes later.
    func activate(key: String) {
        licenseKey = key
        UserDefaults.standard.set(key, forKey: "licenseKey")
        tier = .pro
        // TODO: Validate against Lemon Squeezy API
    }

    /// Deactivate the current license.
    func deactivate() {
        licenseKey = nil
        UserDefaults.standard.removeObject(forKey: "licenseKey")
        tier = .free
    }

    enum Feature {
        case unlimitedDrives
        case insights
        case actionQueue
        case browse
        case backups
        case settings
    }
}
