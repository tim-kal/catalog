import Foundation
import SwiftUI

// MARK: - Insights Response

struct InsightsResponse: Codable {
    let health: InsightsHealth
    let driveRisks: [DriveRisk]
    let atRiskContent: [AtRiskContent]
    let actions: [RecommendedAction]
    let consolidation: ConsolidationInsightsSummary

    enum CodingKeys: String, CodingKey {
        case health
        case driveRisks = "drive_risks"
        case atRiskContent = "at_risk_content"
        case actions
        case consolidation
    }
}

// MARK: - Health

struct InsightsHealth: Codable {
    let backupCoveragePercent: Double
    let totalFiles: Int
    let hashedFiles: Int
    let unhashedFiles: Int
    let uniqueHashes: Int
    let unprotectedHashes: Int
    let unprotectedBytes: Int64
    let backedUpHashes: Int
    let backedUpBytes: Int64
    let redundantHashes: Int
    let redundantBytes: Int64
    let sameDriveDuplicates: Int
    let reclaimableBytes: Int64
    let totalDrives: Int
    let totalStorageBytes: Int64

    enum CodingKeys: String, CodingKey {
        case backupCoveragePercent = "backup_coverage_percent"
        case totalFiles = "total_files"
        case hashedFiles = "hashed_files"
        case unhashedFiles = "unhashed_files"
        case uniqueHashes = "unique_hashes"
        case unprotectedHashes = "unprotected_hashes"
        case unprotectedBytes = "unprotected_bytes"
        case backedUpHashes = "backed_up_hashes"
        case backedUpBytes = "backed_up_bytes"
        case redundantHashes = "redundant_hashes"
        case redundantBytes = "redundant_bytes"
        case sameDriveDuplicates = "same_drive_duplicates"
        case reclaimableBytes = "reclaimable_bytes"
        case totalDrives = "total_drives"
        case totalStorageBytes = "total_storage_bytes"
    }
}

// MARK: - Drive Risk

struct DriveRisk: Codable, Identifiable {
    let driveName: String
    let unprotectedFiles: Int
    let unprotectedBytes: Int64
    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64
    let freePercent: Double
    let riskLevel: String // critical, high, moderate, low, safe

    var id: String { driveName }

    enum CodingKeys: String, CodingKey {
        case driveName = "drive_name"
        case unprotectedFiles = "unprotected_files"
        case unprotectedBytes = "unprotected_bytes"
        case totalBytes = "total_bytes"
        case usedBytes = "used_bytes"
        case freeBytes = "free_bytes"
        case freePercent = "free_percent"
        case riskLevel = "risk_level"
    }

    var riskColor: String {
        switch riskLevel {
        case "critical": return "red"
        case "high": return "orange"
        case "moderate": return "yellow"
        case "low": return "green"
        default: return "gray"
        }
    }
}

// MARK: - At-Risk Content

struct AtRiskContent: Codable, Identifiable {
    let category: String
    let icon: String
    let fileCount: Int
    let totalBytes: Int64
    let topExtensions: [String]

    var id: String { category }

    enum CodingKeys: String, CodingKey {
        case category
        case icon
        case fileCount = "file_count"
        case totalBytes = "total_bytes"
        case topExtensions = "top_extensions"
    }
}

// MARK: - Recommended Action

struct RecommendedAction: Codable, Identifiable, Hashable {
    let id: String
    let priority: Int
    let title: String
    let description: String
    let impactBytes: Int64
    let actionType: String // backup, cleanup, consolidate
    let target: String?
    let icon: String
    let color: String

    enum CodingKeys: String, CodingKey {
        case id
        case priority
        case title
        case description
        case impactBytes = "impact_bytes"
        case actionType = "action_type"
        case target
        case icon
        case color
    }

    var swiftColor: Color {
        switch color {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "blue": return .blue
        case "green": return .green
        default: return .secondary
        }
    }
}

// MARK: - Consolidation Summary

struct ConsolidationInsightsSummary: Codable {
    let consolidatableCount: Int
    let candidateDrives: [String]
    let totalFreeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case consolidatableCount = "consolidatable_count"
        case candidateDrives = "candidate_drives"
        case totalFreeBytes = "total_free_bytes"
    }
}
