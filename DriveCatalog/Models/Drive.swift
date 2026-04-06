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
    let diskUuid: String?
    let deviceSerial: String?
    let fsFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case uuid
        case mountPath = "mount_path"
        case totalBytes = "total_bytes"
        case lastScan = "last_scan"
        case fileCount = "file_count"
        case diskUuid = "disk_uuid"
        case deviceSerial = "device_serial"
        case fsFingerprint = "fs_fingerprint"
    }
}

/// Response model for drive recognition.
struct DriveRecognizeResponse: Codable {
    let status: String  // recognized, not_found, ambiguous, weak_match
    let confidence: String  // certain, probable, ambiguous, weak, none
    let drive: DriveResponse?
    let candidates: [DriveResponse]?
    let mountPath: String?

    enum CodingKeys: String, CodingKey {
        case status
        case confidence
        case drive
        case candidates
        case mountPath = "mount_path"
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
    let folderCount: Int
    let hashedCount: Int
    let hashCoveragePercent: Double
    let lastScan: Date?
    let firstSeen: Date?
    let videoCount: Int
    let imageCount: Int
    let audioCount: Int
    // Disk usage (persisted — available even when disconnected)
    let usedBytes: Int64?
    // Drive health
    let smartStatus: String?
    let mediaType: String?
    let deviceProtocol: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mounted
        case fileCount = "file_count"
        case folderCount = "folder_count"
        case hashedCount = "hashed_count"
        case hashCoveragePercent = "hash_coverage_percent"
        case lastScan = "last_scan"
        case firstSeen = "first_seen"
        case videoCount = "video_count"
        case imageCount = "image_count"
        case audioCount = "audio_count"
        case usedBytes = "used_bytes"
        case smartStatus = "smart_status"
        case mediaType = "media_type"
        case deviceProtocol = "device_protocol"
    }
}
