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
