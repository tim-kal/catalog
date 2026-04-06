import AppKit
import Foundation
import os

/// Manages beta access: invite codes, registration, usage tracking, and bug reports.
@MainActor
final class BetaService: ObservableObject {
    static let shared = BetaService()

    /// Backend URL for beta management. Set to your actual endpoint.
    static let apiURL = "https://catalog-beta.vercel.app/api"

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
    func submitBugReport(title: String, description: String, includeLog: Bool) async -> Bool {
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

        do {
            let result = try await post(endpoint: "/bug-report", body: body)
            return result["success"] as? Bool ?? false
        } catch {
            return false
        }
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

    private func post(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: Self.apiURL + endpoint) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
