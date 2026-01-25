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

/// A file within a duplicate cluster.
struct DuplicateFile: Codable, Identifiable {
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

/// A cluster of duplicate files sharing the same hash.
struct DuplicateCluster: Codable, Identifiable {
    let partialHash: String
    let sizeBytes: Int64
    let count: Int
    let reclaimableBytes: Int64
    let files: [DuplicateFile]

    var id: String { partialHash }

    enum CodingKeys: String, CodingKey {
        case partialHash = "partial_hash"
        case sizeBytes = "size_bytes"
        case count
        case reclaimableBytes = "reclaimable_bytes"
        case files
    }
}

/// Statistics about duplicates in the catalog.
struct DuplicateStatsResponse: Codable {
    let totalClusters: Int
    let totalDuplicateFiles: Int
    let totalBytes: Int64
    let reclaimableBytes: Int64

    enum CodingKeys: String, CodingKey {
        case totalClusters = "total_clusters"
        case totalDuplicateFiles = "total_duplicate_files"
        case totalBytes = "total_bytes"
        case reclaimableBytes = "reclaimable_bytes"
    }
}

/// Response model for listing duplicates.
struct DuplicateListResponse: Codable {
    let clusters: [DuplicateCluster]
    let stats: DuplicateStatsResponse
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
