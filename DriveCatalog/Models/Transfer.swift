import Foundation

// MARK: - Request Models

/// Request to create a new file transfer.
struct CreateTransferRequest: Codable {
    let sourceDrive: String
    let destDrive: String
    let paths: [String]?
    let destFolder: String?

    enum CodingKeys: String, CodingKey {
        case sourceDrive = "source_drive"
        case destDrive = "dest_drive"
        case paths
        case destFolder = "dest_folder"
    }
}

// MARK: - Response Models

/// A single transfer record.
struct TransferResponse: Codable, Identifiable {
    let id: Int
    let sourceDrive: String
    let destDrive: String
    let status: String  // pending, running, completed, failed, cancelled
    let totalFiles: Int
    let totalBytes: Int64
    let filesTransferred: Int
    let bytesTransferred: Int64
    let filesFailed: Int
    let operationId: String?
    let createdAt: String
    let startedAt: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sourceDrive = "source_drive"
        case destDrive = "dest_drive"
        case status
        case totalFiles = "total_files"
        case totalBytes = "total_bytes"
        case filesTransferred = "files_transferred"
        case bytesTransferred = "bytes_transferred"
        case filesFailed = "files_failed"
        case operationId = "operation_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    /// Status badge color for the UI.
    var statusColor: String {
        switch status {
        case "completed":
            return filesFailed == 0 ? "green" : "orange"
        case "failed":
            return "red"
        case "running":
            return "blue"
        default:
            return "secondary"
        }
    }
}

/// Transfer list response.
struct TransferListResponse: Codable {
    let transfers: [TransferResponse]
    let total: Int
}

/// A single failed file in a transfer report.
struct TransferFailedFile: Codable, Identifiable {
    let path: String
    let error: String

    var id: String { path }
}

/// Transfer verification report.
struct TransferReportResponse: Codable {
    let transferId: Int
    let totalFiles: Int
    let totalBytes: Int64
    let filesVerified: Int
    let filesFailed: Int
    let allVerified: Bool
    let durationSeconds: Double?
    let failedFiles: [TransferFailedFile]

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case totalFiles = "total_files"
        case totalBytes = "total_bytes"
        case filesVerified = "files_verified"
        case filesFailed = "files_failed"
        case allVerified = "all_verified"
        case durationSeconds = "duration_seconds"
        case failedFiles = "failed_files"
    }
}
