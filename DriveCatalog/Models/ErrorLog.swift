import Foundation

/// A single error log entry from the backend.
struct ErrorLogEntry: Codable, Identifiable {
    let timestamp: String
    let code: String
    let title: String
    let severity: String
    let context: [String: String]?

    var id: String { "\(timestamp)-\(code)" }

    /// Severity color name for display.
    var severityColor: String {
        switch severity {
        case "critical": return "red"
        case "error": return "orange"
        case "warning": return "yellow"
        default: return "gray"
        }
    }

    /// Format the entry as a single-line string for copying.
    var copyText: String {
        var text = "[\(timestamp)] \(code) \(title) (\(severity))"
        if let ctx = context, !ctx.isEmpty {
            let ctxStr = ctx.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            text += " — \(ctxStr)"
        }
        return text
    }
}

/// Summary response from GET /errors/summary.
struct ErrorSummaryResponse: Codable {
    let totalCount: Int
    let byCode: [String: Int]
    let bySeverity: [String: Int]
    let recent: [ErrorLogEntry]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case byCode = "by_code"
        case bySeverity = "by_severity"
        case recent
    }
}
