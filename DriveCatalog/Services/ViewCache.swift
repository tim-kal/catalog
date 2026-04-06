import Foundation

/// Simple disk cache for view data — shows last-known state instantly on launch
/// while the backend starts up, then replaces with fresh data.
enum ViewCache {
    private static let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DriveCatalog/ViewCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    /// Save a Codable value to the cache.
    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    /// Load a cached value, or nil if not available.
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Delete all cached view data.
    static func clearAll() {
        if let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in contents {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
