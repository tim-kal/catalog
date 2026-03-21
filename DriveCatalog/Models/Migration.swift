import Foundation

// MARK: - Request Models

/// Request to generate a migration plan for a source drive.
struct GeneratePlanRequest: Codable {
    let sourceDrive: String

    enum CodingKeys: String, CodingKey {
        case sourceDrive = "source_drive"
    }
}

// MARK: - File-Level Response Models

/// A single file in a migration plan.
struct MigrationFileResponse: Codable, Identifiable {
    let id: Int
    let sourcePath: String
    let sourceSizeBytes: Int64
    let targetDriveName: String?
    let targetPath: String?
    let action: String
    let status: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sourcePath = "source_path"
        case sourceSizeBytes = "source_size_bytes"
        case targetDriveName = "target_drive_name"
        case targetPath = "target_path"
        case action
        case status
        case error
    }
}

/// Count and bytes for a specific file status.
struct FileStatusCount: Codable {
    let count: Int
    let bytes: Int64

    enum CodingKeys: String, CodingKey {
        case count
        case bytes
    }
}

// MARK: - Plan Response Models

/// Brief plan info returned after generation.
struct MigrationPlanSummary: Codable, Identifiable {
    let planId: Int
    let sourceDrive: String
    let status: String
    let totalFiles: Int
    let filesToCopy: Int
    let filesToDelete: Int
    let totalBytesToTransfer: Int64
    let isFeasible: Bool

    var id: Int { planId }

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case sourceDrive = "source_drive"
        case status
        case totalFiles = "total_files"
        case filesToCopy = "files_to_copy"
        case filesToDelete = "files_to_delete"
        case totalBytesToTransfer = "total_bytes_to_transfer"
        case isFeasible = "is_feasible"
    }
}

/// Full migration plan details.
struct MigrationPlanResponse: Codable, Identifiable {
    let planId: Int
    let sourceDriveName: String
    let status: String
    let totalFiles: Int
    let filesToCopy: Int
    let filesToDelete: Int
    let totalBytesToTransfer: Int64
    let filesCompleted: Int
    let bytesTransferred: Int64
    let filesFailed: Int
    let errors: [String]
    let operationId: String?
    let createdAt: String
    let startedAt: String?
    let completedAt: String?
    let fileStatusCounts: [String: FileStatusCount]

    var id: Int { planId }

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case sourceDriveName = "source_drive_name"
        case status
        case totalFiles = "total_files"
        case filesToCopy = "files_to_copy"
        case filesToDelete = "files_to_delete"
        case totalBytesToTransfer = "total_bytes_to_transfer"
        case filesCompleted = "files_completed"
        case bytesTransferred = "bytes_transferred"
        case filesFailed = "files_failed"
        case errors
        case operationId = "operation_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case fileStatusCounts = "file_status_counts"
    }
}

// MARK: - Validation Response Models

/// Free space check for a target drive.
struct TargetSpaceInfo: Codable, Identifiable {
    let driveName: String
    let bytesNeeded: Int64
    let bytesAvailable: Int64
    let sufficient: Bool

    var id: String { driveName }

    enum CodingKeys: String, CodingKey {
        case driveName = "drive_name"
        case bytesNeeded = "bytes_needed"
        case bytesAvailable = "bytes_available"
        case sufficient
    }
}

/// Result of plan validation.
struct ValidatePlanResponse: Codable {
    let planId: Int
    let status: String
    let valid: Bool
    let targetSpace: [TargetSpaceInfo]

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case status
        case valid
        case targetSpace = "target_space"
    }
}

// MARK: - File List Response

/// Paginated list of migration files.
struct MigrationFilesResponse: Codable {
    let planId: Int
    let files: [MigrationFileResponse]
    let total: Int

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case files
        case total
    }
}

// MARK: - Execution Response

/// Response after starting migration execution.
struct ExecuteResponse: Codable {
    let planId: Int
    let operationId: String
    let status: String
    let pollUrl: String

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case operationId = "operation_id"
        case status
        case pollUrl = "poll_url"
    }
}
