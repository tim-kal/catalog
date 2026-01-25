import Foundation

/// Response model for scan results.
struct ScanResultResponse: Codable {
    let newFiles: Int
    let modifiedFiles: Int
    let unchangedFiles: Int
    let errors: Int
    let totalScanned: Int

    enum CodingKeys: String, CodingKey {
        case newFiles = "new_files"
        case modifiedFiles = "modified_files"
        case unchangedFiles = "unchanged_files"
        case errors
        case totalScanned = "total_scanned"
    }
}

/// Response model for async operations.
///
/// Note: The `result` field is omitted for simplicity. The UI can request
/// specific endpoints (scan results, copy results) rather than parsing
/// arbitrary nested dictionaries.
struct OperationResponse: Codable, Identifiable {
    let id: String
    let type: String  // scan, hash, copy, media, verify
    let status: String  // pending, running, completed, failed
    let progressPercent: Double?
    let error: String?
    let createdAt: Date
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case status
        case progressPercent = "progress_percent"
        case error
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}

/// Request model for file copy operations.
struct CopyRequest: Codable {
    let sourceDrive: String
    let sourcePath: String
    let destDrive: String
    let destPath: String?

    enum CodingKeys: String, CodingKey {
        case sourceDrive = "source_drive"
        case sourcePath = "source_path"
        case destDrive = "dest_drive"
        case destPath = "dest_path"
    }
}

/// Response model for copy operation results.
struct CopyResultResponse: Codable {
    let bytesCopied: Int64
    let sourceHash: String
    let destHash: String
    let verified: Bool

    enum CodingKeys: String, CodingKey {
        case bytesCopied = "bytes_copied"
        case sourceHash = "source_hash"
        case destHash = "dest_hash"
        case verified
    }
}

/// Response model for media file metadata.
struct MediaMetadataResponse: Codable, Identifiable {
    let fileId: Int
    let durationSeconds: Double?
    let codecName: String?
    let width: Int?
    let height: Int?
    let frameRate: String?
    let bitRate: Int?
    let integrityVerifiedAt: Date?
    let integrityErrors: String?

    var id: Int { fileId }

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case durationSeconds = "duration_seconds"
        case codecName = "codec_name"
        case width
        case height
        case frameRate = "frame_rate"
        case bitRate = "bit_rate"
        case integrityVerifiedAt = "integrity_verified_at"
        case integrityErrors = "integrity_errors"
    }
}
