import AppKit
import Foundation
import os

/// Manages beta access: invite codes, registration, usage tracking, and bug reports.
@MainActor
final class BetaService: ObservableObject {
    enum BugReportSubmissionResult {
        case backend
        case githubDraft
        case failed
    }

    static let shared = BetaService()

    /// Backend URL for beta management. Set to your actual endpoint.
    static let apiURL = "https://catalog-beta.vercel.app/api"
    static let fallbackGitHubRepo = "tim-kal/catalog"

    @Published var isRegistered = false
    @Published var userName: String = ""
    @Published var userEmail: String = ""
    @Published var registrationError: String?

    private let logger = Logger(subsystem: "com.catalog.app", category: "BetaService")
    private let defaults = UserDefaults.standard

    private init() {
        // Restore saved registration
        if let name = defaults.string(forKey: "beta_name"),
           let email = defaults.string(forKey: "beta_email"),
           defaults.bool(forKey: "beta_registered") {
            userName = name
            userEmail = email
            isRegistered = true
        }
    }

    // MARK: - Registration

    /// Register with a beta invite code, name, and email.
    func register(code: String, name: String, email: String) async {
        registrationError = nil
        do {
            let body: [String: Any] = [
                "code": code.trimmingCharacters(in: .whitespaces).uppercased(),
                "name": name.trimmingCharacters(in: .whitespaces),
                "email": email.trimmingCharacters(in: .whitespaces).lowercased(),
                "device_id": deviceId,
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "app_version": appVersion
            ]

            let result = try await post(endpoint: "/register", body: body)

            if let success = result["success"] as? Bool, success {
                userName = name
                userEmail = email
                isRegistered = true
                defaults.set(name, forKey: "beta_name")
                defaults.set(email, forKey: "beta_email")
                defaults.set(true, forKey: "beta_registered")
                defaults.set(code, forKey: "beta_code")
                logger.info("Beta registration successful: \(email)")
            } else {
                registrationError = result["error"] as? String ?? "Registration failed"
            }
        } catch {
            registrationError = "Connection failed — check your internet connection"
            logger.warning("Beta registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Heartbeat (tracks app opens)

    /// Send a heartbeat — call on each app launch.
    func sendHeartbeat() async {
        guard isRegistered else { return }
        let body: [String: Any] = [
            "email": userEmail,
            "device_id": deviceId,
            "app_version": appVersion,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "drives_count": 0,  // Will be updated with real count
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        _ = try? await post(endpoint: "/heartbeat", body: body)
    }

    // MARK: - Bug Report

    /// Submit a bug report with optional log attachment and recent error codes.
    /// Tries: (1) local backend → GitHub API, (2) Vercel backend, (3) browser GitHub draft.
    func submitBugReport(title: String, description: String, includeLog: Bool) async -> BugReportSubmissionResult {
        var body: [String: Any] = [
            "email": userEmail,
            "name": userName,
            "title": title,
            "description": description,
            "app_version": appVersion,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "device_id": deviceId,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        if includeLog {
            let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("DriveCatalog/backend.log")
            body["backend_log"] = (try? String(contentsOf: logURL, encoding: .utf8))?.suffix(5000).description
        }

        // Auto-include last 10 error codes
        if let errors = try? await APIService.shared.fetchErrors(limit: 10), !errors.isEmpty {
            body["recent_errors"] = errors.map { entry in
                [
                    "code": entry.code,
                    "title": entry.title,
                    "severity": entry.severity,
                    "timestamp": entry.timestamp
                ]
            }
        }

        // 1. Try local backend (routes through GitHub API via config token)
        do {
            let result = try await postLocal(path: "/bug-report", body: body)
            if result["status"] as? String == "created" {
                return .backend
            }
        } catch {
            logger.warning("Local bug report failed: \(error.localizedDescription)")
        }

        // 2. Try Vercel backend (legacy — may be broken)
        do {
            let result = try await post(endpoint: "/bug-report", body: body)
            if result["success"] as? Bool == true || result["status"] as? String == "created" {
                return .backend
            }
        } catch {
            logger.warning("Vercel bug report also failed: \(error.localizedDescription)")
        }

        // 3. Last resort — open prefilled GitHub issue in browser
        if openGitHubIssueDraft(title: title, description: description, payload: body) {
            return .githubDraft
        }

        return .failed
    }

    /// POST to the local FastAPI backend (same host as APIService).
    private func postLocal(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: APIService.baseURL + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let fallback = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let detail = fallback["detail"] as? String ?? "HTTP \(http.statusCode)"
            throw NSError(
                domain: "BetaService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func openGitHubIssueDraft(title: String, description: String, payload: [String: Any]) -> Bool {
        let appVersion = payload["app_version"] as? String ?? "unknown"
        let osVersion = payload["os_version"] as? String ?? "unknown"
        let deviceId = payload["device_id"] as? String ?? "unknown"
        let email = (payload["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let backendLog = payload["backend_log"] as? String ?? ""

        var issueBody = """
        ## Bug Report

        **Description:** \(description)

        ### Environment
        - **App Version:** \(appVersion)
        - **OS Version:** \(osVersion)
        - **Device ID:** \(deviceId)
        """

        if !email.isEmpty {
            issueBody += "\n- **Reporter email:** \(email)"
        }

        if let recentErrors = payload["recent_errors"] as? [[String: Any]], !recentErrors.isEmpty {
            issueBody += "\n\n### Recent Errors"
            for error in recentErrors.prefix(10) {
                let code = error["code"] as? String ?? "unknown"
                let errorTitle = error["title"] as? String ?? "unknown"
                issueBody += "\n- `\(code)`: \(errorTitle)"
            }
        }

        if !backendLog.isEmpty {
            issueBody += "\n\n### Backend Log Snippet\n```\n\(backendLog)\n```"
        }

        issueBody += "\n\n---\n*Submitted via in-app bug reporter (GitHub fallback path)*"

        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(Self.fallbackGitHubRepo)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: issueBody),
            URLQueryItem(name: "labels", value: "bug-report,from-app")
        ]

        guard let url = components.url else {
            logger.error("Failed to build GitHub issue draft URL")
            return false
        }

        return NSWorkspace.shared.open(url)
    }

    private func post(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: Self.apiURL + endpoint) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let fallback = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let detail = fallback["error"] as? String ?? "HTTP \(http.statusCode)"
            throw NSError(
                domain: "BetaService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Helpers

    private var deviceId: String {
        if let existing = defaults.string(forKey: "beta_device_id") {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: "beta_device_id")
        return id
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }
}
