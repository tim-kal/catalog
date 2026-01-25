import Foundation

/// Response model for a single drive.
struct DriveResponse: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let uuid: String?
    let mountPath: String
    let totalBytes: Int64
    let lastScan: Date?
    let fileCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case uuid
        case mountPath = "mount_path"
        case totalBytes = "total_bytes"
        case lastScan = "last_scan"
        case fileCount = "file_count"
    }
}

/// Response model for listing drives.
struct DriveListResponse: Codable {
    let drives: [DriveResponse]
    let total: Int
}

/// Request model for creating/registering a drive.
struct DriveCreateRequest: Codable {
    let path: String
    let name: String?
}

/// Response model for drive status.
struct DriveStatusResponse: Codable, Identifiable {
    let id: Int
    let name: String
    let mounted: Bool
    let fileCount: Int
    let hashedCount: Int
    let hashCoveragePercent: Double
    let lastScan: Date?
    let mediaCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mounted
        case fileCount = "file_count"
        case hashedCount = "hashed_count"
        case hashCoveragePercent = "hash_coverage_percent"
        case lastScan = "last_scan"
        case mediaCount = "media_count"
    }
}
