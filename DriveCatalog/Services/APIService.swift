import Foundation

/// Errors that can occur during API requests.
enum APIError: Error, LocalizedError {
    case invalidURL
    case requestFailed(Error)
    case invalidResponse
    case httpError(Int, String)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .requestFailed(let error):
            return "Request failed: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .decodingFailed(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}

/// Thread-safe API service for communicating with the DriveCatalog FastAPI backend.
actor APIService {
    /// Base URL for the API server.
    static let baseURL = "http://localhost:8100"

    /// Shared instance for convenience.
    static let shared = APIService()

    /// JSON decoder configured for the API response format.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // NOTE: Do NOT use .convertFromSnakeCase here — all models define
        // explicit CodingKeys with snake_case raw values. Using both would
        // double-convert keys and break decoding.

        // Custom date decoding to handle ISO8601 with optional fractional seconds
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try ISO8601 with fractional seconds first
            let formatterWithFractional = ISO8601DateFormatter()
            formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatterWithFractional.date(from: dateString) {
                return date
            }

            // Try ISO8601 without fractional seconds
            let formatterWithoutFractional = ISO8601DateFormatter()
            formatterWithoutFractional.formatOptions = [.withInternetDateTime]
            if let date = formatterWithoutFractional.date(from: dateString) {
                return date
            }

            // Try bare datetime without timezone, stripping optional fractional seconds
            // Python's datetime.now().isoformat() → "2026-01-24T09:38:05.123456"
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

            // Strip fractional seconds (.123456) if present
            let stripped = dateString.contains(".")
                ? String(dateString.prefix(while: { $0 != "." }))
                : dateString

            if let date = df.date(from: stripped) {
                return date
            }

            // Try space-separated datetime from SQLite (e.g. "2026-01-24 09:38:05")
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = df.date(from: stripped) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(dateString)"
            )
        }

        return decoder
    }()

    /// JSON encoder configured for the API request format.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // CodingKeys handle snake_case mapping — no automatic conversion needed.
        return encoder
    }()

    // MARK: - Drive Endpoints

    /// Fetch all registered drives.
    func fetchDrives() async throws -> DriveListResponse {
        let url = try buildURL(path: "/drives")
        return try await get(url: url)
    }

    /// Create/register a new drive.
    /// - Parameters:
    ///   - path: Mount path of the drive (must be under /Volumes/).
    ///   - name: Optional custom name for the drive.
    /// - Returns: The created drive response.
    func createDrive(path: String, name: String? = nil) async throws -> DriveResponse {
        let url = try buildURL(path: "/drives")
        let request = DriveCreateRequest(path: path, name: name)
        return try await post(url: url, body: request)
    }

    /// Delete a drive registration and all associated file records.
    /// - Parameter name: Name of the drive to delete.
    func deleteDrive(name: String) async throws {
        let url = try buildURL(path: "/drives/\(name)", queryItems: [
            URLQueryItem(name: "confirm", value: "true")
        ])
        try await delete(url: url)
    }

    /// Clear all scan data for a drive (files, hashes, metadata) while keeping the registration.
    func clearScanData(driveName: String) async throws {
        let url = try buildURL(path: "/drives/\(driveName)/clear-scan", queryItems: [
            URLQueryItem(name: "confirm", value: "true")
        ])
        // Response contains mixed types (string + int), so use raw JSON
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(from: data) ?? "Unknown error"
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
    }

    /// Trigger deterministic integrity verification of scan, hash, and duplicate data.
    func triggerVerifyIntegrity(driveName: String) async throws -> OperationStartResponse {
        let url = try buildURL(path: "/drives/\(driveName)/verify-integrity")
        return try await postEmpty(url: url)
    }

    /// Recognize a mounted volume by UUID, auto-updating registration if renamed.
    /// Returns the recognized drive name, or nil if the volume isn't registered.
    func recognizeDrive(mountPath: String) async throws -> String? {
        let url = try buildURL(path: "/drives/recognize", queryItems: [
            URLQueryItem(name: "mount_path", value: mountPath)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String,
              status == "recognized",
              let drive = json["drive"] as? [String: Any],
              let name = drive["name"] as? String else {
            return nil
        }
        return name
    }

    /// Fetch detailed status for a drive.
    /// - Parameter name: Name of the drive.
    /// - Returns: Drive status including mount state and hash coverage.
    func fetchDriveStatus(name: String) async throws -> DriveStatusResponse {
        let url = try buildURL(path: "/drives/\(name)/status")
        return try await get(url: url)
    }

    // MARK: - Operation Endpoints

    /// Trigger a scan of the drive's filesystem.
    /// - Parameter driveName: Name of the drive to scan.
    /// - Returns: Operation start response with poll URL.
    func triggerScan(driveName: String) async throws -> OperationStartResponse {
        let url = try buildURL(path: "/drives/\(driveName)/scan")
        return try await postEmpty(url: url)
    }

    /// Trigger an auto-scan that only runs if filesystem differs from DB.
    /// Returns raw JSON since response shape varies (started vs skipped).
    func triggerAutoScan(driveName: String) async throws -> [String: Any] {
        let url = try buildURL(path: "/drives/\(driveName)/auto-scan")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Trigger partial hash computation for files on the drive.
    /// - Parameters:
    ///   - driveName: Name of the drive to hash.
    ///   - force: If true, re-hash files that already have hashes.
    /// - Returns: Operation start response with poll URL.
    func triggerHash(driveName: String, force: Bool = false) async throws -> OperationStartResponse {
        var queryItems: [URLQueryItem]? = nil
        if force {
            queryItems = [URLQueryItem(name: "force", value: "true")]
        }
        let url = try buildURL(path: "/drives/\(driveName)/hash", queryItems: queryItems)
        return try await postEmpty(url: url)
    }

    /// Cancel a running operation.
    func cancelOperation(id: String) async throws {
        let url = try buildURL(path: "/operations/\(id)/cancel")
        let _: [String: String] = try await postEmpty(url: url)
    }

    /// Fetch the status of an async operation.
    func fetchOperation(id: String) async throws -> OperationResponse {
        let url = try buildURL(path: "/operations/\(id)")
        return try await get(url: url)
    }

    /// Fetch the raw result dictionary from a completed operation.
    func fetchOperationResult(id: String) async throws -> [String: Any] {
        let url = try buildURL(path: "/operations/\(id)")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return json["result"] as? [String: Any] ?? [:]
    }

    /// Fetch all recent operations. Used to check for active operations before quit.
    func fetchOperations(limit: Int = 20) async throws -> OperationListResponse {
        let url = try buildURL(path: "/operations", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ])
        return try await get(url: url)
    }

    // MARK: - File Endpoints

    /// Fetch paginated file list with optional filters.
    func fetchFiles(
        drive: String? = nil,
        pathPrefix: String? = nil,
        extension ext: String? = nil,
        minSize: Int? = nil,
        maxSize: Int? = nil,
        hasHash: Bool? = nil,
        isMedia: Bool? = nil,
        page: Int = 1,
        pageSize: Int = 100
    ) async throws -> FileListResponse {
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ]
        if let drive { queryItems.append(URLQueryItem(name: "drive", value: drive)) }
        if let pathPrefix { queryItems.append(URLQueryItem(name: "path_prefix", value: pathPrefix)) }
        if let ext { queryItems.append(URLQueryItem(name: "extension", value: ext)) }
        if let minSize { queryItems.append(URLQueryItem(name: "min_size", value: String(minSize))) }
        if let maxSize { queryItems.append(URLQueryItem(name: "max_size", value: String(maxSize))) }
        if let hasHash { queryItems.append(URLQueryItem(name: "has_hash", value: String(hasHash))) }
        if let isMedia { queryItems.append(URLQueryItem(name: "is_media", value: String(isMedia))) }

        let url = try buildURL(path: "/files", queryItems: queryItems)
        return try await get(url: url)
    }

    /// Fetch a single file by ID.
    func fetchFile(id: Int) async throws -> FileResponse {
        let url = try buildURL(path: "/files/\(id)")
        return try await get(url: url)
    }

    /// Fetch media metadata for a file.
    func fetchFileMedia(fileId: Int) async throws -> MediaMetadataResponse {
        let url = try buildURL(path: "/files/\(fileId)/media")
        return try await get(url: url)
    }

    /// Browse a directory like Finder — returns subdirectories and files at a path level.
    func browseDirectory(drive: String, path: String = "") async throws -> BrowseResponse {
        let url = try buildURL(path: "/files/browse", queryItems: [
            URLQueryItem(name: "drive", value: drive),
            URLQueryItem(name: "path", value: path)
        ])
        return try await get(url: url)
    }

    /// Get backup status for a folder — which other drives have copies of these files.
    func fetchBackupStatus(drive: String, path: String) async throws -> BackupStatusResponse {
        let url = try buildURL(path: "/files/browse/backup-status", queryItems: [
            URLQueryItem(name: "drive", value: drive),
            URLQueryItem(name: "path", value: path)
        ])
        return try await get(url: url)
    }

    /// Check which registered drives are currently mounted.
    func fetchMountedDrives() async throws -> DriveListResponse {
        let url = try buildURL(path: "/drives/mounted")
        return try await get(url: url)
    }

    // MARK: - Backup / Protection Endpoints

    /// Fetch file groups with protection classification and system stats.
    func fetchProtectionData(
        limit: Int = 100,
        status: String? = nil,
        drive: String? = nil,
        sortBy: String = "reclaimable"
    ) async throws -> ProtectionResponse {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: sortBy),
        ]
        if let status { queryItems.append(URLQueryItem(name: "status", value: status)) }
        if let drive { queryItems.append(URLQueryItem(name: "drive", value: drive)) }

        let url = try buildURL(path: "/duplicates", queryItems: queryItems)
        return try await get(url: url)
    }

    /// Fetch system-wide protection stats only.
    func fetchProtectionStats() async throws -> ProtectionStats {
        let url = try buildURL(path: "/duplicates/stats")
        return try await get(url: url)
    }

    /// Fetch protection stats for a specific drive.
    func fetchDriveProtectionStats(driveName: String) async throws -> DriveProtectionStats {
        let url = try buildURL(path: "/duplicates/drive/\(driveName)")
        return try await get(url: url)
    }

    /// Fetch hierarchical protection tree: drives > directories.
    func fetchProtectionTree(drive: String? = nil) async throws -> ProtectionTreeResponse {
        var queryItems: [URLQueryItem]? = nil
        if let drive {
            queryItems = [URLQueryItem(name: "drive", value: drive)]
        }
        let url = try buildURL(path: "/duplicates/tree", queryItems: queryItems)
        return try await get(url: url)
    }

    /// Fetch file groups within a specific directory on a drive.
    func fetchDirectoryFiles(drive: String, path: String, limit: Int = 200) async throws -> [FileGroup] {
        let url = try buildURL(path: "/duplicates/directory", queryItems: [
            URLQueryItem(name: "drive", value: drive),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return try await get(url: url)
    }

    /// Verify files are true duplicates using deeper hash (first + middle + last chunks).
    func verifyFiles(fileIds: [Int]) async throws -> VerificationResponse {
        let url = try buildURL(path: "/duplicates/verify")
        return try await post(url: url, body: VerificationRequest(fileIds: fileIds))
    }

    // MARK: - Search Endpoints

    /// Search files by glob pattern.
    func searchFiles(
        query: String,
        drive: String? = nil,
        minSize: Int? = nil,
        maxSize: Int? = nil,
        extension ext: String? = nil,
        limit: Int = 100
    ) async throws -> SearchResultResponse {
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let drive { queryItems.append(URLQueryItem(name: "drive", value: drive)) }
        if let minSize { queryItems.append(URLQueryItem(name: "min_size", value: String(minSize))) }
        if let maxSize { queryItems.append(URLQueryItem(name: "max_size", value: String(maxSize))) }
        if let ext { queryItems.append(URLQueryItem(name: "extension", value: ext)) }

        let url = try buildURL(path: "/search", queryItems: queryItems)
        return try await get(url: url)
    }

    // MARK: - Copy Endpoints

    /// Trigger a verified file copy operation.
    func triggerCopy(request: CopyRequest) async throws -> OperationStartResponse {
        let url = try buildURL(path: "/copy")
        return try await post(url: url, body: request)
    }

    // MARK: - Status Endpoints

    /// Fetch API health status and database stats.
    func fetchHealthStatus() async throws -> HealthStatusResponse {
        let url = try buildURL(path: "/status")
        return try await get(url: url)
    }

    // MARK: - Consolidation Endpoints

    /// Fetch per-drive file distribution with unique/duplicated breakdown.
    /// - Returns: Distribution data for all drives.
    func fetchDistribution() async throws -> DriveDistributionResponse {
        let url = try buildURL(path: "/consolidation/distribution")
        return try await get(url: url)
    }

    /// Fetch drives eligible for consolidation.
    /// - Returns: Candidates with target drive information.
    func fetchConsolidationCandidates() async throws -> ConsolidationCandidatesResponse {
        let url = try buildURL(path: "/consolidation/candidates")
        return try await get(url: url)
    }

    /// Compute optimal consolidation strategy for a source drive.
    /// - Parameter drive: Name of the source drive to consolidate.
    /// - Returns: Strategy with file assignments and feasibility.
    func fetchConsolidationStrategy(drive: String) async throws -> ConsolidationStrategyResponse {
        let url = try buildURL(path: "/consolidation/strategy", queryItems: [
            URLQueryItem(name: "drive", value: drive)
        ])
        return try await get(url: url)
    }

    // MARK: - Migration Endpoints

    /// Generate a migration plan for a source drive.
    /// - Parameter sourceDrive: Name of the drive to migrate off.
    /// - Returns: Summary of the generated plan.
    func generateMigrationPlan(sourceDrive: String) async throws -> MigrationPlanSummary {
        let url = try buildURL(path: "/migrations/generate")
        let request = GeneratePlanRequest(sourceDrive: sourceDrive)
        return try await post(url: url, body: request)
    }

    /// Fetch full details of a migration plan.
    /// - Parameter planId: ID of the migration plan.
    /// - Returns: Full plan details including per-status file counts.
    func fetchMigrationPlan(planId: Int) async throws -> MigrationPlanResponse {
        let url = try buildURL(path: "/migrations/\(planId)")
        return try await get(url: url)
    }

    /// Validate a migration plan by checking free space on target drives.
    /// - Parameter planId: ID of the migration plan to validate.
    /// - Returns: Validation result with per-target space info.
    func validateMigrationPlan(planId: Int) async throws -> ValidatePlanResponse {
        let url = try buildURL(path: "/migrations/\(planId)/validate")
        return try await postEmpty(url: url)
    }

    /// Start execution of a validated migration plan.
    /// - Parameter planId: ID of the migration plan to execute.
    /// - Returns: Execution response with operation ID for polling.
    func executeMigrationPlan(planId: Int) async throws -> ExecuteResponse {
        let url = try buildURL(path: "/migrations/\(planId)/execute")
        return try await postEmpty(url: url)
    }

    /// Fetch paginated list of files in a migration plan.
    /// - Parameters:
    ///   - planId: ID of the migration plan.
    ///   - status: Optional filter by file status.
    ///   - limit: Maximum files to return (default 100).
    ///   - offset: Number of files to skip (default 0).
    /// - Returns: Paginated file list.
    func fetchMigrationFiles(planId: Int, status: String? = nil, limit: Int = 100, offset: Int = 0) async throws -> MigrationFilesResponse {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if let status {
            queryItems.append(URLQueryItem(name: "status", value: status))
        }
        let url = try buildURL(path: "/migrations/\(planId)/files", queryItems: queryItems)
        return try await get(url: url)
    }

    /// Cancel a running migration.
    /// - Parameter planId: ID of the migration plan to cancel.
    func cancelMigration(planId: Int) async throws {
        let url = try buildURL(path: "/migrations/\(planId)")
        try await delete(url: url)
    }

    func renameDrive(name: String, newName: String) async throws {
        let url = try buildURL(path: "/drives/\(name)/rename", queryItems: [
            URLQueryItem(name: "new_name", value: newName)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
    }

    // MARK: - Drive Quick Check & Diff

    func quickCheck(driveName: String) async throws -> [String: Any] {
        let url = try buildURL(path: "/drives/\(driveName)/quick-check")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func triggerDiff(driveName: String) async throws -> [String: Any] {
        let url = try buildURL(path: "/drives/\(driveName)/diff")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Insights

    func fetchInsights() async throws -> InsightsResponse {
        let url = try buildURL(path: "/insights")
        return try await get(url: url)
    }

    // MARK: - Actions Queue

    func fetchActions(status: String? = nil) async throws -> ActionListResponse {
        var queryItems: [URLQueryItem] = []
        if let status { queryItems.append(URLQueryItem(name: "status", value: status)) }
        let url = try buildURL(path: "/actions", queryItems: queryItems.isEmpty ? nil : queryItems)
        return try await get(url: url)
    }

    func fetchActionableActions() async throws -> ActionableResponse {
        let url = try buildURL(path: "/actions/actionable")
        return try await get(url: url)
    }

    func createAction(_ request: CreateActionRequest) async throws -> PlannedAction {
        let url = try buildURL(path: "/actions")
        return try await post(url: url, body: request)
    }

    func updateAction(id: Int, request: UpdateActionRequest) async throws -> PlannedAction {
        let url = try buildURL(path: "/actions/\(id)")
        return try await patch(url: url, body: request)
    }

    func deleteAction(id: Int) async throws {
        let url = try buildURL(path: "/actions/\(id)")
        try await delete(url: url)
    }

    func verifyActions() async throws -> VerifyActionsResponse {
        let url = try buildURL(path: "/actions/verify")
        return try await postEmpty(url: url)
    }

    // MARK: - Private Helpers

    /// Build a URL with the given path and optional query items.
    private func buildURL(path: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
        var components = URLComponents(string: Self.baseURL + path)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw APIError.invalidURL
        }
        return url
    }

    /// Perform a GET request and decode the response.
    private func get<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        return try await perform(request: request)
    }

    /// Perform a POST request with a JSON body and decode the response.
    private func post<T: Decodable, B: Encodable>(url: URL, body: B) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        return try await perform(request: request)
    }

    /// Perform a PATCH request with a JSON body and decode the response.
    private func patch<T: Decodable, B: Encodable>(url: URL, body: B) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        return try await perform(request: request)
    }

    /// Perform a POST request without a body and decode the response.
    private func postEmpty<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        return try await perform(request: request)
    }

    /// Perform a DELETE request.
    private func delete(url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(from: data) ?? "Unknown error"
            throw APIError.httpError(httpResponse.statusCode, message)
        }
    }

    /// Perform an HTTP request and decode the response.
    private func perform<T: Decodable>(request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.requestFailed(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(from: data) ?? "Unknown error"
            throw APIError.httpError(httpResponse.statusCode, message)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    /// Parse error message from API response body.
    /// The API returns errors as JSON with a "detail" field.
    private func parseErrorMessage(from data: Data) -> String? {
        struct ErrorResponse: Decodable {
            let detail: String
        }

        return try? JSONDecoder().decode(ErrorResponse.self, from: data).detail
    }
}
