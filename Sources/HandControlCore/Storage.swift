import Foundation

public struct StorageError: Error, CustomStringConvertible {
    public let description: String
}

/// Recorded samples. Raw joints are stored rather than feature vectors, so changing
/// the normalization does not force re-recording.
public struct GestureStore: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = GestureStore.currentVersion
    public var samples: [String: [[Point]]] = [:]

    public init() {}

    public static func load(from url: URL) throws -> GestureStore {
        guard FileManager.default.fileExists(atPath: url.path) else { return GestureStore() }
        let store = try JSONDecoder().decode(GestureStore.self, from: Data(contentsOf: url))
        guard store.version == currentVersion else {
            throw StorageError(description:
                "\(url.path): version \(store.version), expected \(currentVersion)")
        }
        return store
    }

    public func save(to url: URL) throws {
        try writeJSON(self, to: url)
    }
}

extension Config {
    public static func load(from url: URL) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try writeJSON(self, to: url)
    }
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(value).write(to: url, options: .atomic)
}
