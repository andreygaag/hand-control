import Foundation

/// Fixed set of OS commands. Deliberately not a free-form shell command: the config
/// file can only name effects this code knows how to perform.
public enum SystemCommand: String, Codable, CaseIterable, Sendable {
    case sleep
    case displaySleep
}

/// What a gesture does. New effect types are added as cases here; the performer's
/// exhaustive switch then forces every consumer to handle them.
public enum Action: Equatable, Sendable {
    case hotkey(KeyCombo)
    case system(SystemCommand)
}

extension Action: CustomStringConvertible {
    public var description: String {
        switch self {
        case .hotkey(let combo): "hotkey \(combo)"
        case .system(let command): "system \(command.rawValue)"
        }
    }
}

extension Action: Codable {
    // JSON shape: {"hotkey": "ctrl+right"} or {"system": "sleep"} — exactly one key naming
    // the action type.
    private struct Key: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "action must have exactly one key, e.g. {\"hotkey\": \"ctrl+right\"}"))
        }
        switch key.stringValue {
        case "hotkey":
            self = .hotkey(try c.decode(KeyCombo.self, forKey: key))
        case "system":
            let raw = try c.decode(String.self, forKey: key)
            guard let command = SystemCommand(rawValue: raw) else {
                let known = SystemCommand.allCases.map(\.rawValue).joined(separator: ", ")
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: c, debugDescription: "unknown system command '\(raw)'; known: \(known)")
            }
            self = .system(command)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c, debugDescription: "unknown action type '\(key.stringValue)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .hotkey(let combo):
            try c.encode(combo, forKey: Key(stringValue: "hotkey"))
        case .system(let command):
            try c.encode(command, forKey: Key(stringValue: "system"))
        }
    }
}

public struct Config: Codable, Equatable, Sendable {
    /// How long a pose must be held before it fires.
    public var holdMs: Int = 300
    /// How long a fired pose must be absent before it can fire again. Also bounds how long
    /// Vision may lose a held hand entirely without re-firing it.
    public var releaseMs: Int = 300
    /// Reject threshold: RMS per-joint distance in palm lengths (see Features.distance).
    /// Uncalibrated default; tune with `run --debug` and `list`.
    public var maxDistance: Double = 0.25
    public var bindings: [String: Action] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case holdMs, releaseMs, maxDistance, bindings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        holdMs = try c.decodeIfPresent(Int.self, forKey: .holdMs) ?? d.holdMs
        releaseMs = try c.decodeIfPresent(Int.self, forKey: .releaseMs) ?? d.releaseMs
        maxDistance = try c.decodeIfPresent(Double.self, forKey: .maxDistance) ?? d.maxDistance
        bindings = try c.decodeIfPresent([String: Action].self, forKey: .bindings) ?? d.bindings
    }
}
