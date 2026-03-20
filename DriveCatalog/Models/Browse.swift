import Foundation

/// Directory entry from the browse API.
struct DirectoryEntry: Codable, Identifiable {
    let name: String
    let path: String
    let fileCount: Int
    let totalBytes: Int64
    let childDirCount: Int

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case fileCount = "file_count"
        case totalBytes = "total_bytes"
        case childDirCount = "child_dir_count"
    }
}

/// Response from the /files/browse endpoint — Finder-style directory listing.
struct BrowseResponse: Codable {
    let drive: String
    let currentPath: String
    let directories: [DirectoryEntry]
    let files: [FileResponse]

    enum CodingKeys: String, CodingKey {
        case drive
        case currentPath = "current_path"
        case directories
        case files
    }
}

/// Backup coverage of a folder on another drive.
struct BackupDriveInfo: Codable, Identifiable {
    let driveName: String
    let fileCount: Int
    let percentCoverage: Double

    var id: String { driveName }

    enum CodingKeys: String, CodingKey {
        case driveName = "drive_name"
        case fileCount = "file_count"
        case percentCoverage = "percent_coverage"
    }
}

/// Response from /files/browse/backup-status — which other drives have this folder.
struct BackupStatusResponse: Codable {
    let drive: String
    let path: String
    let totalFiles: Int
    let hashedFiles: Int
    let backedUpFiles: Int
    let backupDrives: [BackupDriveInfo]

    enum CodingKeys: String, CodingKey {
        case drive
        case path
        case totalFiles = "total_files"
        case hashedFiles = "hashed_files"
        case backedUpFiles = "backed_up_files"
        case backupDrives = "backup_drives"
    }
}
