import Foundation

/// Response model for a single file.
struct FileResponse: Codable, Identifiable {
    let id: Int
    let driveId: Int
    let driveName: String
    let path: String
    let filename: String
    let sizeBytes: Int64
    let mtime: String?
    let partialHash: String?
    let isMedia: Bool
    let copyCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case driveId = "drive_id"
        case driveName = "drive_name"
        case path
        case filename
        case sizeBytes = "size_bytes"
        case mtime
        case partialHash = "partial_hash"
        case isMedia = "is_media"
        case copyCount = "copy_count"
    }
}

/// Response model for listing files.
struct FileListResponse: Codable {
    let files: [FileResponse]
    let total: Int
    let page: Int
    let pageSize: Int

    enum CodingKeys: String, CodingKey {
        case files
        case total
        case page
        case pageSize = "page_size"
    }
}

// MARK: - Protection / Backup Models

/// A file location within a file group.
struct FileLocation: Codable, Identifiable {
    let driveName: String
    let path: String
    let fileId: Int

    var id: Int { fileId }

    enum CodingKeys: String, CodingKey {
        case driveName = "drive_name"
        case path
        case fileId = "file_id"
    }
}

/// A group of files sharing the same hash, classified by protection status.
struct FileGroup: Codable, Identifiable {
    let filename: String
    let partialHash: String
    let sizeBytes: Int64
    let totalCopies: Int
    let driveCount: Int
    let status: String  // unprotected, same_drive_duplicate, backed_up, over_backed_up
    let sameDriveExtras: Int
    let reclaimableBytes: Int64
    let locations: [FileLocation]

    var id: String { partialHash }

    enum CodingKeys: String, CodingKey {
        case filename
        case partialHash = "partial_hash"
        case sizeBytes = "size_bytes"
        case totalCopies = "total_copies"
        case driveCount = "drive_count"
        case status
        case sameDriveExtras = "same_drive_extras"
        case reclaimableBytes = "reclaimable_bytes"
        case locations
    }
}

/// System-wide protection and storage statistics.
struct ProtectionStats: Codable {
    let totalDrives: Int
    let totalFiles: Int
    let totalStorageBytes: Int64
    let hashedFiles: Int
    let unhashedFiles: Int
    let uniqueHashes: Int
    let unprotectedFiles: Int
    let unprotectedBytes: Int64
    let backedUpFiles: Int
    let backedUpBytes: Int64
    let overBackedUpFiles: Int
    let overBackedUpBytes: Int64
    let sameDriveDuplicateCount: Int
    let reclaimableBytes: Int64
    let backupCoveragePercent: Double

    enum CodingKeys: String, CodingKey {
        case totalDrives = "total_drives"
        case totalFiles = "total_files"
        case totalStorageBytes = "total_storage_bytes"
        case hashedFiles = "hashed_files"
        case unhashedFiles = "unhashed_files"
        case uniqueHashes = "unique_hashes"
        case unprotectedFiles = "unprotected_files"
        case unprotectedBytes = "unprotected_bytes"
        case backedUpFiles = "backed_up_files"
        case backedUpBytes = "backed_up_bytes"
        case overBackedUpFiles = "over_backed_up_files"
        case overBackedUpBytes = "over_backed_up_bytes"
        case sameDriveDuplicateCount = "same_drive_duplicate_count"
        case reclaimableBytes = "reclaimable_bytes"
        case backupCoveragePercent = "backup_coverage_percent"
    }
}

/// Per-drive protection statistics.
struct DriveProtectionStats: Codable {
    let driveName: String
    let totalFiles: Int
    let totalBytes: Int64
    let hashedFiles: Int
    let unhashedFiles: Int
    let unprotectedFiles: Int
    let unprotectedBytes: Int64
    let backedUpFiles: Int
    let backedUpBytes: Int64
    let overBackedUpFiles: Int
    let overBackedUpBytes: Int64
    let sameDriveDuplicateCount: Int
    let reclaimableBytes: Int64

    enum CodingKeys: String, CodingKey {
        case driveName = "drive_name"
        case totalFiles = "total_files"
        case totalBytes = "total_bytes"
        case hashedFiles = "hashed_files"
        case unhashedFiles = "unhashed_files"
        case unprotectedFiles = "unprotected_files"
        case unprotectedBytes = "unprotected_bytes"
        case backedUpFiles = "backed_up_files"
        case backedUpBytes = "backed_up_bytes"
        case overBackedUpFiles = "over_backed_up_files"
        case overBackedUpBytes = "over_backed_up_bytes"
        case sameDriveDuplicateCount = "same_drive_duplicate_count"
        case reclaimableBytes = "reclaimable_bytes"
    }
}

/// Full response for the backups/protection page (flat list).
struct ProtectionResponse: Codable {
    let groups: [FileGroup]
    let stats: ProtectionStats
}

// MARK: - Hierarchical Protection Models

/// Protection stats for a single directory within a drive.
struct DirectoryProtection: Codable, Identifiable {
    let path: String
    let totalFiles: Int
    let totalBytes: Int64
    let unhashedFiles: Int
    let unprotectedFiles: Int
    let unprotectedBytes: Int64
    let backedUpFiles: Int
    let backedUpBytes: Int64
    let overBackedUpFiles: Int
    let overBackedUpBytes: Int64

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case totalFiles = "total_files"
        case totalBytes = "total_bytes"
        case unhashedFiles = "unhashed_files"
        case unprotectedFiles = "unprotected_files"
        case unprotectedBytes = "unprotected_bytes"
        case backedUpFiles = "backed_up_files"
        case backedUpBytes = "backed_up_bytes"
        case overBackedUpFiles = "over_backed_up_files"
        case overBackedUpBytes = "over_backed_up_bytes"
    }
}

/// Drive-level protection summary with directory breakdown.
struct DriveProtectionSummary: Codable, Identifiable {
    let driveName: String
    let totalFiles: Int
    let totalBytes: Int64
    let unprotectedFiles: Int
    let backedUpFiles: Int
    let overBackedUpFiles: Int
    let directories: [DirectoryProtection]

    var id: String { driveName }

    enum CodingKeys: String, CodingKey {
        case driveName = "drive_name"
        case totalFiles = "total_files"
        case totalBytes = "total_bytes"
        case unprotectedFiles = "unprotected_files"
        case backedUpFiles = "backed_up_files"
        case overBackedUpFiles = "over_backed_up_files"
        case directories
    }
}

/// Hierarchical protection view: drives > directories.
struct ProtectionTreeResponse: Codable {
    let drives: [DriveProtectionSummary]
    let stats: ProtectionStats
}

// MARK: - Verification Models

/// Request to verify files are true duplicates before deletion.
struct VerificationRequest: Codable {
    let fileIds: [Int]

    enum CodingKeys: String, CodingKey {
        case fileIds = "file_ids"
    }
}

/// Verification result for a single file.
struct FileVerificationResult: Codable, Identifiable {
    let fileId: Int
    let driveName: String
    let path: String
    let verificationHash: String?
    let accessible: Bool

    var id: Int { fileId }

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case driveName = "drive_name"
        case path
        case verificationHash = "verification_hash"
        case accessible
    }
}

/// Response from verification hash computation.
struct VerificationResponse: Codable {
    let verified: Bool
    let results: [FileVerificationResult]
    let matchingHash: String?

    enum CodingKeys: String, CodingKey {
        case verified
        case results
        case matchingHash = "matching_hash"
    }
}

/// File result from search query (simplified view).
struct SearchFile: Codable, Identifiable {
    let driveName: String
    let path: String
    let sizeBytes: Int64
    let mtime: String?

    var id: String { "\(driveName):\(path)" }

    enum CodingKeys: String, CodingKey {
        case driveName = "drive_name"
        case path
        case sizeBytes = "size_bytes"
        case mtime
    }
}

/// Response model for search results.
struct SearchResultResponse: Codable {
    let files: [SearchFile]
    let total: Int
    let pattern: String
}
