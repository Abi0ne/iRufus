// Application log: readable, exportable, without personal data.

import Foundation

public struct LogEntry: Identifiable, Sendable, Hashable {
    public enum Level: String, Sendable { case info, warning, error }
    public let id: Int
    public let date: Date
    public let level: Level
    public let message: String
}

@MainActor
public final class LogStore {
    public private(set) var entries: [LogEntry] = []
    public var onAppend: ((LogEntry) -> Void)?
    private var nextID = 0
    private let maxEntries = 20_000
    /// Strings that must never appear in the log (e.g. a Windows account name).
    private var secrets: Set<String> = []

    public init() {}

    public func registerSecret(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2 { secrets.insert(t) }
    }

    public func clearSecrets() {
        secrets.removeAll()
    }

    public func add(_ message: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(id: nextID, date: Date(), level: level, message: Self.redact(message, secrets: secrets))
        nextID += 1
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        onAppend?(entry)
    }

    public func clear() {
        entries.removeAll()
    }

    /// Replace the user's home directory by "~", user name occurrences in paths
    /// by "<user>", and registered secrets by "<redacted>".
    public nonisolated static func redact(_ s: String, secrets: Set<String> = [], home: String = NSHomeDirectory(),
                                          user: String = NSUserName()) -> String {
        // The home folder becomes "~" only where a path starts (not inside /Volumes/X/Users/...).
        let pattern = "(^|[\\s'\"(=:])" + NSRegularExpression.escapedPattern(for: home) + "(?=/|$|[\\s'\")])"
        var out = (try? NSRegularExpression(pattern: pattern))
            .map { $0.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1~") } ?? s
        if user.count >= 2 {
            out = out.replacingOccurrences(of: "/Users/\(user)/", with: "/Users/<user>/")
        }
        for secret in secrets.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return out
    }

    public func exportText(appVersion: String, engineVersion: String) -> String {
        let f = ISO8601DateFormatter()
        var lines = ["iRufus \(appVersion) — engine \(engineVersion) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        lines.append(contentsOf: entries.map { "\(f.string(from: $0.date)) [\($0.level.rawValue.uppercased())] \($0.message)" })
        return lines.joined(separator: "\n") + "\n"
    }
}
