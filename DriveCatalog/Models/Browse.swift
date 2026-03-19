import Foundation

/// Directory entry from the browse API.
struct DirectoryEntry: Codable, Identifiable {
    let name: String
    let path: String
    let fileCount: Int
    let totalBytes: Int64

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case fileCount = "file_count"
        case totalBytes = "total_bytes"
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
