import Foundation

// MARK: - Folder Duplicate Response

struct FolderDuplicateResponse: Codable {
    let exactMatchGroups: [ExactMatchGroup]
    let subsetPairs: [SubsetPair]
    let stats: FolderDuplicateStats

    enum CodingKeys: String, CodingKey {
        case exactMatchGroups = "exact_match_groups"
        case subsetPairs = "subset_pairs"
        case stats
    }
}

struct FolderInfo: Codable, Identifiable {
    let driveId: Int
    let driveName: String
    let folderPath: String
    let fileCount: Int
    let totalBytes: Int64

    var id: String { "\(driveId):\(folderPath)" }

    enum CodingKeys: String, CodingKey {
        case driveId = "drive_id"
        case driveName = "drive_name"
        case folderPath = "folder_path"
        case fileCount = "file_count"
        case totalBytes = "total_bytes"
    }
}

struct ExactMatchGroup: Codable, Identifiable {
    let matchType: String
    let hashCount: Int
    let folders: [FolderInfo]

    var id: String {
        folders.map(\.id).sorted().joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case matchType = "match_type"
        case hashCount = "hash_count"
        case folders
    }
}

struct SubsetPair: Codable, Identifiable {
    let matchType: String
    let subsetHashCount: Int
    let supersetHashCount: Int
    let overlapPercent: Double
    let subsetFolder: FolderInfo
    let supersetFolder: FolderInfo

    var id: String { "\(subsetFolder.id)->\(supersetFolder.id)" }

    enum CodingKeys: String, CodingKey {
        case matchType = "match_type"
        case subsetHashCount = "subset_hash_count"
        case supersetHashCount = "superset_hash_count"
        case overlapPercent = "overlap_percent"
        case subsetFolder = "subset_folder"
        case supersetFolder = "superset_folder"
    }
}

struct FolderDuplicateStats: Codable {
    let totalFoldersAnalyzed: Int
    let exactMatchGroups: Int
    let subsetPairsFound: Int

    enum CodingKeys: String, CodingKey {
        case totalFoldersAnalyzed = "total_folders_analyzed"
        case exactMatchGroups = "exact_match_groups"
        case subsetPairsFound = "subset_pairs_found"
    }
}
