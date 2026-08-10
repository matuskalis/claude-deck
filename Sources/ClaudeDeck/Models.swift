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
    /// Set on a background session; the directory under ~/.claude/jobs is named after it.
    var jobId: String?
    /// Set on an interactive session that backgrounded a job and is waiting on it.
    var parkedJobId: String?
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
    /// The turn ended on an API error rather than finishing. Sticks until the next prompt,
    /// because otherwise a rate-limited session is indistinguishable from a finished one.
    case failed(message: String)
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
    /// Present when this session backgrounded a job and is waiting on it.
    var parkedJobId: String?
    /// When an idle session went idle. Nil while it is working.
    var idleSince: Date?

    /// An idle session holding most of a context window is one to finish or restart
    /// deliberately, rather than discover at 100% mid-task.
    func isStale(now: Date) -> Bool {
        guard let idleSince, let percent = contextPercent, percent >= 70 else { return false }
        return now.timeIntervalSince(idleSince) > 30 * 60
    }

    /// A terminal tab left open days ago. A fixed 12 hours rather than "not today",
    /// which would collapse the whole list the moment midnight passed.
    static let dormantAfter: TimeInterval = 12 * 3600

    func isDormant(now: Date) -> Bool {
        guard case .idle = state, let idleSince else { return false }
        return now.timeIntervalSince(idleSince) > Self.dormantAfter
    }

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
