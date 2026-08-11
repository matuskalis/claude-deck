import Foundation

/// Tails ~/.claude/claude-deck/events.jsonl, the file our hooks append to.
/// Only lines appended after launch are reported, so a stale spool never replays
/// old notifications.
actor EventsSpool {
    /// Redirected by the tests; see `HookInstaller.settingsURL`.
    nonisolated(unsafe) static var directory = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/claude-deck")
    static var url: URL { directory.appending(path: "events.jsonl") }

    private var offset = 0

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let size = Self.currentSize(), size > 5 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: Self.url)
        } else {
            offset = Self.currentSize() ?? 0
        }
        // Created up front so the file watcher has something to attach to.
        if !FileManager.default.fileExists(atPath: Self.url.path) {
            FileManager.default.createFile(atPath: Self.url.path, contents: nil)
        }
    }

    func newEvents() -> [DeckEvent] {
        guard let size = Self.currentSize() else {
            offset = 0
            return []
        }
        if offset > size { offset = 0 }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: Self.url) else { return [] }
        defer { try? handle.close() }

        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        // Leave a trailing partial line in place for the next read.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        offset += data.distance(from: data.startIndex, to: lastNewline) + 1

        let decoder = JSONDecoder()
        return data[data.startIndex...lastNewline]
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(DeckEvent.self, from: Data($0)) }
    }

    private nonisolated static func currentSize() -> Int? {
        url.currentFileSize
    }
}

/// Tails ~/.claude/claude-deck/tools.jsonl, which the spool helper writes on every
/// PreToolUse and PostToolUse.
///
/// Kept apart from `EventsSpool` because the volume is completely different: one line per
/// tool call, each carrying the whole `tool_input`. The helper rotates the file with
/// `tail -c` once it passes a megabyte, which makes it shorter than the offset we are
/// holding; that rewinds this reader and replays the tail. Harmless — a replayed
/// PreToolUse only re-sets a label the next PostToolUse clears.
actor ToolSpool {
    static var url: URL { EventsSpool.directory.appending(path: "tools.jsonl") }

    private var offset = 0

    init() {
        offset = Self.url.currentFileSize ?? 0
    }

    func newEvents() -> [DeckEvent] {
        guard let size = Self.url.currentFileSize else {
            offset = 0
            return []
        }
        if offset > size { offset = 0 }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: Self.url) else { return [] }
        defer { try? handle.close() }

        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        offset += data.distance(from: data.startIndex, to: lastNewline) + 1

        let decoder = JSONDecoder()
        return data[data.startIndex...lastNewline]
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(DeckEvent.self, from: Data($0)) }
    }
}

/// Tails ~/.claude/history.jsonl for the most recent prompt of each session.
/// The whole file is read once (a couple of megabytes), then only appended bytes.
actor HistoryTail {
    private static let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/history.jsonl")

    private var offset = 0
    private var prompts: [String: String] = [:]
    /// Project directories in order of last use, oldest first.
    private var projects: [String] = []
    private var promptedDay = ""
    private var promptedToday: Set<String> = []

    /// The most recently used project directories, most recent first.
    func recentProjects(limit: Int) -> [String] {
        projects.suffix(limit).reversed()
    }

    /// Sessions that submitted a prompt today, empty if none has.
    func sessionsPromptedToday() -> Set<String> {
        promptedDay == Self.dayKey(Date()) ? promptedToday : []
    }

    func latestPrompts() -> [String: String] {
        guard let size = Self.url.currentFileSize else { return prompts }
        if offset > size {
            offset = 0
            prompts = [:]
            projects = []
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: Self.url) else { return prompts }
        defer { try? handle.close() }

        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return prompts }
        offset += data.distance(from: data.startIndex, to: lastNewline) + 1

        let decoder = JSONDecoder()
        for line in data[data.startIndex...lastNewline].split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(HistoryLine.self, from: Data(line)) else { continue }

            if let project = entry.project {
                projects.removeAll { $0 == project }
                projects.append(project)
            }
            guard let sessionId = entry.sessionId else { continue }
            if let display = entry.display {
                prompts[sessionId] = display
            }
            if let timestamp = entry.timestamp {
                // Lines are chronological, so a new day simply replaces the set.
                let day = Self.dayKey(Date(epochMilliseconds: timestamp))
                if day != promptedDay {
                    promptedDay = day
                    promptedToday = []
                }
                promptedToday.insert(sessionId)
            }
        }
        return prompts
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct HistoryLine: Decodable {
    var display: String?
    var sessionId: String?
    var project: String?
    var timestamp: Double?
}
