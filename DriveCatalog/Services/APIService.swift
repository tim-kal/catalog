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
    static let baseURL = "http://localhost:8000"

    /// Shared instance for convenience.
    static let shared = APIService()

    /// JSON decoder configured for the API response format.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

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
        encoder.keyEncodingStrategy = .convertToSnakeCase
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

    /// Fetch the status of an async operation.
    /// - Parameter id: The operation ID to check.
    /// - Returns: Operation response with status and progress.
    func fetchOperation(id: String) async throws -> OperationResponse {
        let url = try buildURL(path: "/operations/\(id)")
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

    // MARK: - Duplicate Endpoints

    /// Fetch duplicate clusters with stats.
    func fetchDuplicates(limit: Int = 100, minSize: Int? = nil, sortBy: String = "reclaimable") async throws -> DuplicateListResponse {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: sortBy)
        ]
        if let minSize { queryItems.append(URLQueryItem(name: "min_size", value: String(minSize))) }

        let url = try buildURL(path: "/duplicates", queryItems: queryItems)
        return try await get(url: url)
    }

    /// Fetch duplicate stats only.
    func fetchDuplicateStats() async throws -> DuplicateStatsResponse {
        let url = try buildURL(path: "/duplicates/stats")
        return try await get(url: url)
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
