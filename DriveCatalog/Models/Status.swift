import Foundation

/// Response model for API health status and database statistics.
struct HealthStatusResponse: Codable {
    let dbPath: String
    let initialized: Bool
    let drivesCount: Int
    let filesCount: Int
    let hashedCount: Int
    let hashCoveragePercent: Double

    enum CodingKeys: String, CodingKey {
        case dbPath = "db_path"
        case initialized
        case drivesCount = "drives_count"
        case filesCount = "files_count"
        case hashedCount = "hashed_count"
        case hashCoveragePercent = "hash_coverage_percent"
    }
}
