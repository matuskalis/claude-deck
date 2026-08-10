import Foundation

/// One file in ~/.claude/sessions/<pid>.json. Every field is optional: these are
/// undocumented Claude Code internals and a schema change must not drop the row.
struct SessionFile: Decodable, Sendable {
    var pid: Int32?
    var sessionId: String?
    var cwd: String?
    var startedAt: Double?
    var procStart: String?
    var version: String?
    var kind: String?
    var name: String?
    var status: String?
    var updatedAt: Double?
    var statusUpdatedAt: Double?
}

/// One line in ~/.claude/claude-deck/events.jsonl, spooled by our hooks.
struct DeckEvent: Decodable, Sendable {
    var hookEventName: String?
    var sessionId: String?
    var cwd: String?
    var message: String?
    var toolName: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd
        case message
        case toolName = "tool_name"
    }
}

struct TranscriptUsage: Sendable, Equatable {
    var model: String?
    var contextUsed: Int
}

enum SessionState: Sendable, Equatable {
    case idle
    case busy(since: Date)
    case waitingPermission(message: String)
}

struct Session: Identifiable, Sendable, Equatable {
    var id: String
    var pid: Int32
    var name: String
    var cwd: String
    var state: SessionState
    var lastPrompt: String?
    var usage: TranscriptUsage?
    var contextWindow: Int
    var tool: String?

    var project: String { (cwd as NSString).lastPathComponent }

    var shortPath: String {
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    var contextPercent: Int? {
        guard let used = usage?.contextUsed, contextWindow > 0 else { return nil }
        return used * 100 / contextWindow
    }
}

extension Date {
    init(epochMilliseconds: Double) {
        self.init(timeIntervalSince1970: epochMilliseconds / 1000)
    }
}

extension URL {
    /// `resourceValues(forKeys:)` caches per URL instance and would keep reporting
    /// the size a file had when it was first queried, so these files are stat'd.
    var currentFileSize: Int? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Int(info.st_size)
    }

    var currentModified: Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
    }
}
