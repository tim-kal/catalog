import Foundation

/// A queued operation that waits for drives to come online.
struct PlannedAction: Codable, Identifiable {
    let id: Int
    let actionType: String
    let sourceDrive: String
    let sourcePath: String
    let targetDrive: String?
    let targetPath: String?
    let status: String
    let priority: Int
    let reason: String?
    let estimatedBytes: Int64
    let dependsOn: Int?
    let createdAt: String
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case actionType = "action_type"
        case sourceDrive = "source_drive"
        case sourcePath = "source_path"
        case targetDrive = "target_drive"
        case targetPath = "target_path"
        case status
        case priority
        case reason
        case estimatedBytes = "estimated_bytes"
        case dependsOn = "depends_on"
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }

    /// Human-readable action description.
    var actionLabel: String {
        switch actionType {
        case "delete": return "Delete"
        case "copy": return "Copy"
        case "move": return "Move"
        default: return actionType.capitalized
        }
    }

    /// SF Symbol for this action type.
    var actionIcon: String {
        switch actionType {
        case "delete": return "trash"
        case "copy": return "doc.on.doc"
        case "move": return "arrow.right.doc.on.clipboard"
        default: return "questionmark.circle"
        }
    }

    /// Status color name.
    var statusTint: String {
        switch status {
        case "pending": return "orange"
        case "ready": return "blue"
        case "in_progress": return "purple"
        case "completed": return "green"
        case "cancelled": return "gray"
        default: return "secondary"
        }
    }
}

/// Request to create a new planned action.
struct CreateActionRequest: Codable {
    let actionType: String
    let sourceDrive: String
    let sourcePath: String
    let targetDrive: String?
    let targetPath: String?
    let priority: Int
    let reason: String?
    let estimatedBytes: Int64

    enum CodingKeys: String, CodingKey {
        case actionType = "action_type"
        case sourceDrive = "source_drive"
        case sourcePath = "source_path"
        case targetDrive = "target_drive"
        case targetPath = "target_path"
        case priority
        case reason
        case estimatedBytes = "estimated_bytes"
    }
}

/// Response listing planned actions.
struct ActionListResponse: Codable {
    let actions: [PlannedAction]
    let total: Int
    let actionable: Int

    enum CodingKeys: String, CodingKey {
        case actions, total, actionable
    }
}

/// Response with currently executable actions.
struct ActionableResponse: Codable {
    let actions: [PlannedAction]
    let mountedDrives: [String]

    enum CodingKeys: String, CodingKey {
        case actions
        case mountedDrives = "mounted_drives"
    }
}

/// Result of verifying a single action against the filesystem.
struct VerifyActionResult: Codable, Identifiable {
    let actionId: Int
    let sourceExists: Bool
    let autoCompleted: Bool

    var id: Int { actionId }

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case sourceExists = "source_exists"
        case autoCompleted = "auto_completed"
    }
}

/// Response from the verify endpoint.
struct VerifyActionsResponse: Codable {
    let results: [VerifyActionResult]
}

/// Request to update a planned action.
struct UpdateActionRequest: Codable {
    var status: String?
    var priority: Int?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case status, priority, reason
    }
}
