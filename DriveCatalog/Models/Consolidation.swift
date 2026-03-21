import Foundation

// MARK: - Distribution Models

/// Per-drive file distribution with unique/duplicated classification.
struct DriveDistribution: Codable, Identifiable {
    let driveId: Int
    let driveName: String
    let totalFiles: Int
    let totalSizeBytes: Int64
    let uniqueFiles: Int
    let uniqueSizeBytes: Int64
    let duplicatedFiles: Int
    let duplicatedSizeBytes: Int64
    let reclaimableBytes: Int64
    let totalBytes: Int64?
    let usedBytes: Int64?
    let freeBytes: Int64?

    var id: Int { driveId }

    enum CodingKeys: String, CodingKey {
        case driveId = "drive_id"
        case driveName = "drive_name"
        case totalFiles = "total_files"
        case totalSizeBytes = "total_size_bytes"
        case uniqueFiles = "unique_files"
        case uniqueSizeBytes = "unique_size_bytes"
        case duplicatedFiles = "duplicated_files"
        case duplicatedSizeBytes = "duplicated_size_bytes"
        case reclaimableBytes = "reclaimable_bytes"
        case totalBytes = "total_bytes"
        case usedBytes = "used_bytes"
        case freeBytes = "free_bytes"
    }
}

/// Response wrapping per-drive distribution list.
struct DriveDistributionResponse: Codable {
    let drives: [DriveDistribution]
    let totalDrives: Int

    enum CodingKeys: String, CodingKey {
        case drives
        case totalDrives = "total_drives"
    }
}

// MARK: - Consolidation Candidate Models

/// A potential target drive for consolidation.
struct ConsolidationTargetDrive: Codable {
    let driveName: String
    let freeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case driveName = "drive_name"
        case freeBytes = "free_bytes"
    }
}

/// Per-drive consolidation candidacy information.
struct ConsolidationCandidate: Codable, Identifiable {
    let driveId: Int
    let driveName: String
    let totalFiles: Int
    let totalSizeBytes: Int64
    let uniqueFiles: Int
    let uniqueSizeBytes: Int64
    let duplicatedFiles: Int
    let duplicatedSizeBytes: Int64
    let reclaimableBytes: Int64
    let isCandidate: Bool
    let totalAvailableSpace: Int64
    let targetDrives: [ConsolidationTargetDrive]

    var id: Int { driveId }

    enum CodingKeys: String, CodingKey {
        case driveId = "drive_id"
        case driveName = "drive_name"
        case totalFiles = "total_files"
        case totalSizeBytes = "total_size_bytes"
        case uniqueFiles = "unique_files"
        case uniqueSizeBytes = "unique_size_bytes"
        case duplicatedFiles = "duplicated_files"
        case duplicatedSizeBytes = "duplicated_size_bytes"
        case reclaimableBytes = "reclaimable_bytes"
        case isCandidate = "is_candidate"
        case totalAvailableSpace = "total_available_space"
        case targetDrives = "target_drives"
    }
}

/// Response wrapping consolidation candidates list.
struct ConsolidationCandidatesResponse: Codable {
    let candidates: [ConsolidationCandidate]
    let totalDrives: Int
    let consolidatableCount: Int

    enum CodingKeys: String, CodingKey {
        case candidates
        case totalDrives = "total_drives"
        case consolidatableCount = "consolidatable_count"
    }
}

// MARK: - Strategy Models

/// A file in the consolidation strategy.
struct StrategyFile: Codable, Identifiable {
    let path: String
    let sizeBytes: Int64
    let partialHash: String?

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size_bytes"
        case partialHash = "partial_hash"
    }
}

/// Files assigned to a specific target drive.
struct StrategyAssignment: Codable, Identifiable {
    let targetDrive: String
    let fileCount: Int
    let totalBytes: Int64
    let files: [StrategyFile]

    var id: String { targetDrive }

    enum CodingKeys: String, CodingKey {
        case targetDrive = "target_drive"
        case fileCount = "file_count"
        case totalBytes = "total_bytes"
        case files
    }
}

/// Target drive capacity impact from strategy.
struct StrategyTargetDrive: Codable, Identifiable {
    let driveName: String
    let capacityBytes: Int64
    let freeBefore: Int64
    let freeAfter: Int64

    var id: String { driveName }

    enum CodingKeys: String, CodingKey {
        case driveName = "drive_name"
        case capacityBytes = "capacity_bytes"
        case freeBefore = "free_before"
        case freeAfter = "free_after"
    }
}

/// Response for a consolidation strategy computation.
struct ConsolidationStrategyResponse: Codable {
    let sourceDrive: String
    let totalUniqueFiles: Int
    let totalUniqueBytes: Int64
    let totalBytesToTransfer: Int64
    let isFeasible: Bool
    let assignments: [StrategyAssignment]
    let unplaceable: [StrategyFile]
    let targetDrives: [StrategyTargetDrive]

    enum CodingKeys: String, CodingKey {
        case sourceDrive = "source_drive"
        case totalUniqueFiles = "total_unique_files"
        case totalUniqueBytes = "total_unique_bytes"
        case totalBytesToTransfer = "total_bytes_to_transfer"
        case isFeasible = "is_feasible"
        case assignments
        case unplaceable
        case targetDrives = "target_drives"
    }
}
