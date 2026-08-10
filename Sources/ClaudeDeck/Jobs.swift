import Foundation

/// One task a job has fanned out: a subagent, or a shell command it is waiting on.
struct JobFan: Identifiable, Sendable, Equatable {
    var id: String
    var kind: String
    var label: String
    var startedAt: Date?
}

/// One line of a job's timeline: the progress notes it writes as it goes.
struct JobEntry: Identifiable, Sendable, Equatable {
    var id: String { at.map { "\($0.timeIntervalSince1970)" } ?? UUID().uuidString }
    var at: Date?
    var state: String?
    var detail: String?
    var text: String?
}

/// A background job, from `~/.claude/jobs/<id>/`.
///
/// Background sessions are the ones nobody is sitting in front of, and their job directory
/// says far more than a session file does: what it is doing in a sentence, what it is
/// blocked on, what it has fanned out, and how many tokens it has spent getting there.
struct Job: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var state: String
    var tempo: String?
    var detail: String?
    /// What a blocked job is waiting for. This is the background equivalent of a
    /// permission prompt: nothing moves until it is answered.
    var needs: String?
    /// The pending question verbatim, when the job posed a structured one.
    var question: String?
    var options: [String] = []
    var intent: String?
    var cwd: String
    var tokens: Int
    var fan: [JobFan] = []
    var inFlight = 0
    var queued = 0
    var updatedAt: Date?
    var timeline: [JobEntry] = []

    /// Set by `SessionStore` from the live background sessions; a job directory outlives
    /// the process that wrote it.
    var running = false

    /// `state` alone is not enough: a job can hold a pending question while still reporting
    /// `working`, and it is just as stuck as one that says `blocked`.
    var isBlocked: Bool { state == "blocked" || tempo == "blocked" || question != nil }
    var isDone: Bool { state == "done" }

    /// The question if it posed one, otherwise its own prose description of what it needs.
    var waitingOn: String? { question ?? needs }

    var shortPath: String {
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}

actor JobsReader {
    private static let directory = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/jobs")
    /// Enough to hold the last few timeline lines, which carry a full message each.
    private static let timelineTailBytes = 96 * 1024

    private var stamps: [String: String] = [:]
    private var cached: [String: Job] = [:]

    /// Jobs worth showing: anything still running, plus anything unfinished that was
    /// touched recently. A finished job's directory sticks around for weeks.
    func snapshot() -> [Job] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var found: [String: Job] = [:]

        for directory in entries {
            let id = directory.lastPathComponent
            let state = directory.appending(path: "state.json")
            guard let stamp = Self.stamp(of: state) else { continue }

            if stamps[id] == stamp, let job = cached[id] {
                found[id] = job
                continue
            }
            guard let job = Self.read(id: id, state: state, timeline: directory.appending(path: "timeline.jsonl")) else { continue }
            stamps[id] = stamp
            found[id] = job
        }

        stamps = stamps.filter { found[$0.key] != nil }
        cached = found

        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return found.values
            .filter { !$0.isDone && ($0.updatedAt ?? .distantPast) > cutoff }
            .sorted { Self.order($0, $1) }
    }

    /// Blocked first — those are the ones that will sit there forever otherwise — then by
    /// how recently they moved.
    private static func order(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.isBlocked != rhs.isBlocked { return lhs.isBlocked }
        return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
    }

    private static func read(id: String, state: URL, timeline: URL) -> Job? {
        guard let data = try? Data(contentsOf: state) else { return nil }
        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(StateFile.self, from: data) else { return nil }

        return Job(
            id: id,
            name: file.name ?? file.sessionId.map { String($0.prefix(8)) } ?? id,
            state: file.state ?? "unknown",
            tempo: file.tempo,
            detail: file.detail,
            needs: file.needs,
            question: file.block?.questions?.first?.question,
            options: (file.block?.questions?.first?.options ?? []).compactMap(\.label),
            intent: file.intent,
            cwd: file.cwd ?? "",
            tokens: file.tokens ?? 0,
            fan: (file.fan ?? []).compactMap { entry in
                guard let id = entry.id else { return nil }
                return JobFan(
                    id: id,
                    kind: entry.kind ?? "task",
                    label: entry.label ?? "",
                    startedAt: entry.startedAt.map { Date(epochMilliseconds: $0) }
                )
            },
            inFlight: file.inFlight?.tasks ?? 0,
            queued: file.inFlight?.queued ?? 0,
            updatedAt: Self.date(file.updatedAt),
            timeline: entries(of: timeline)
        )
    }

    /// The last three lines only, read from the end of the file: a long-running job's
    /// timeline holds a full assistant message per line and grows without limit.
    private static func entries(of url: URL) -> [JobEntry] {
        guard let size = url.currentFileSize, size > 0 else { return [] }
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }

        let length = min(timelineTailBytes, size)
        var buffer = [UInt8](repeating: 0, count: length)
        let got = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, length, off_t(size - length)) }
        guard got > 0 else { return [] }

        let decoder = JSONDecoder()
        return Data(buffer[0..<got])
            .split(separator: UInt8(ascii: "\n"))
            .suffix(3)
            .compactMap { line -> JobEntry? in
                guard let entry = try? decoder.decode(TimelineLine.self, from: Data(line)) else { return nil }
                return JobEntry(at: date(entry.at), state: entry.state, detail: entry.detail, text: entry.text)
            }
    }

    private static func stamp(of url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }()
    }
}

private struct StateFile: Decodable {
    struct InFlight: Decodable {
        var tasks: Int?
        var queued: Int?
    }
    struct Fan: Decodable {
        var id: String?
        var kind: String?
        var label: String?
        var startedAt: Double?
    }
    struct Block: Decodable {
        struct Question: Decodable {
            struct Option: Decodable { var label: String? }
            var question: String?
            var options: [Option]?
        }
        var questions: [Question]?
    }
    var state: String?
    var tempo: String?
    var detail: String?
    var needs: String?
    var block: Block?
    var intent: String?
    var name: String?
    var cwd: String?
    var tokens: Int?
    var sessionId: String?
    var updatedAt: String?
    var inFlight: InFlight?
    var fan: [Fan]?
}

private struct TimelineLine: Decodable {
    var at: String?
    var state: String?
    var detail: String?
    var text: String?
}
