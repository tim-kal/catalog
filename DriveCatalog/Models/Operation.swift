import Foundation

/// Response model when starting an async operation.
/// Used by scan, hash, media, and verify endpoints.
struct OperationStartResponse: Codable {
    let operationId: String
    let status: String
    let pollUrl: String

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case status
        case pollUrl = "poll_url"
    }
}

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
struct OperationResponse: Identifiable {
    let id: String
    let type: String  // scan, hash, copy, media, verify
    let driveName: String
    let status: String  // pending, running, completed, failed, cancelled
    let progressPercent: Double?
    let etaSeconds: Double?
    let filesProcessed: Int
    let filesTotal: Int
    /// Scan result fields (nil for non-scan ops or if result has nested objects).
    let scanResult: [String: Int]?
    let error: String?
    let createdAt: Date
    let completedAt: Date?

    var isActive: Bool { status == "pending" || status == "running" }

    /// Whether the scan result indicates no changes were found.
    var isUpToDate: Bool {
        guard let r = scanResult else { return false }
        return (r["new_files"] ?? 0) == 0
            && (r["modified_files"] ?? 0) == 0
            && (r["removed_files"] ?? 0) == 0
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case driveName = "drive_name"
        case status
        case progressPercent = "progress_percent"
        case etaSeconds = "eta_seconds"
        case filesProcessed = "files_processed"
        case filesTotal = "files_total"
        case result
        case error
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}

extension OperationResponse: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        driveName = try c.decode(String.self, forKey: .driveName)
        status = try c.decode(String.self, forKey: .status)
        progressPercent = try c.decodeIfPresent(Double.self, forKey: .progressPercent)
        etaSeconds = try c.decodeIfPresent(Double.self, forKey: .etaSeconds)
        filesProcessed = try c.decode(Int.self, forKey: .filesProcessed)
        filesTotal = try c.decode(Int.self, forKey: .filesTotal)
        // Try decoding result as flat [String: Int]; falls back to nil for nested dicts
        scanResult = try? c.decodeIfPresent([String: Int].self, forKey: .result)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(driveName, forKey: .driveName)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(progressPercent, forKey: .progressPercent)
        try c.encodeIfPresent(etaSeconds, forKey: .etaSeconds)
        try c.encode(filesProcessed, forKey: .filesProcessed)
        try c.encode(filesTotal, forKey: .filesTotal)
        try c.encodeIfPresent(scanResult, forKey: .result)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

/// Response model for listing operations.
struct OperationListResponse: Codable {
    let operations: [OperationResponse]
    let total: Int
}

// MARK: - Verification Report

/// Parsed verification result from the verify-integrity operation.
struct VerificationReport {
    let scanPass: Bool
    let filesOnDisk: Int
    let filesInDb: Int
    let missingFromDb: Int
    let staleInDb: Int
    let sizeMismatches: Int

    let hashPass: Bool
    let hashesChecked: Int
    let hashesMatched: Int
    let hashesMismatched: Int
    let hashReadErrors: Int

    let duplicatePass: Bool
    let clustersChecked: Int
    let clustersValid: Int
    let clustersInvalid: Int

    let allPass: Bool

    /// Parse from the raw result dictionary returned by the operations endpoint.
    static func from(dict: [String: Any]) -> VerificationReport? {
        guard let scan = dict["scan"] as? [String: Any],
              let hash = dict["hash"] as? [String: Any],
              let dups = dict["duplicates"] as? [String: Any]
        else { return nil }

        return VerificationReport(
            scanPass: scan["pass"] as? Bool ?? false,
            filesOnDisk: scan["files_on_disk"] as? Int ?? 0,
            filesInDb: scan["files_in_db"] as? Int ?? 0,
            missingFromDb: scan["missing_from_db"] as? Int ?? 0,
            staleInDb: scan["stale_in_db"] as? Int ?? 0,
            sizeMismatches: scan["size_mismatches"] as? Int ?? 0,
            hashPass: hash["pass"] as? Bool ?? false,
            hashesChecked: hash["checked"] as? Int ?? 0,
            hashesMatched: hash["matched"] as? Int ?? 0,
            hashesMismatched: hash["mismatched"] as? Int ?? 0,
            hashReadErrors: hash["read_errors"] as? Int ?? 0,
            duplicatePass: dups["pass"] as? Bool ?? false,
            clustersChecked: dups["clusters_checked"] as? Int ?? 0,
            clustersValid: dups["clusters_valid"] as? Int ?? 0,
            clustersInvalid: dups["clusters_invalid"] as? Int ?? 0,
            allPass: dict["all_pass"] as? Bool ?? false
        )
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
