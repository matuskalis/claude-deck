import Foundation
import Testing

@testable import ClaudeDeck

/// The menu learns about permission prompts, finished turns and tool use by tailing files
/// that hook scripts append to, and about each row's last prompt by tailing Claude Code's
/// history. These readers are cursors into files that other processes write, rotate and
/// truncate, so the tests are about where the cursor is after each of those.
extension DeckTests {
    @Suite struct SpoolTests {
        init() throws { try Hermetic.reset() }

        private static func event(_ name: String, session: String = "s1", tool: String? = nil, message: String? = nil) -> String {
            var fields = ["\"hook_event_name\":\"\(name)\"", "\"session_id\":\"\(session)\""]
            if let tool { fields.append("\"tool_name\":\"\(tool)\"") }
            if let message { fields.append("\"message\":\"\(message)\"") }
            return "{" + fields.joined(separator: ",") + "}"
        }

        private static var eventsPath: String { ".claude/claude-deck/events.jsonl" }
        private static var toolsPath: String { ".claude/claude-deck/tools.jsonl" }

        private static func permissions(of url: URL) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }

        // MARK: - events.jsonl

        @Test("the spool directory and file are created private")
        func createsPrivateSpool() throws {
            _ = EventsSpool()
            #expect(try Self.permissions(of: EventsSpool.directory) == 0o700)
            #expect(try Self.permissions(of: EventsSpool.url) == 0o600)
        }

        @Test("a spool left world-readable by an older version is tightened")
        func tightensAnOldSpool() throws {
            try Hermetic.write("", to: Self.eventsPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: EventsSpool.url.path)

            _ = EventsSpool()
            #expect(try Self.permissions(of: EventsSpool.url) == 0o600)
        }

        @Test("only lines appended after launch are reported, so a stale spool never replays")
        func ignoresWhatWasThereAtLaunch() async throws {
            try Hermetic.write(Hermetic.lines([Self.event("Notification", message: "old")]), to: Self.eventsPath)
            let spool = EventsSpool()
            #expect(await spool.newEvents().isEmpty)

            try Hermetic.append(Hermetic.lines([Self.event("Stop"), Self.event("Notification", message: "new")]), to: Self.eventsPath)
            let events = await spool.newEvents()
            #expect(events.map(\.hookEventName) == ["Stop", "Notification"])
            #expect(events.last?.message == "new")

            // Read once, reported once.
            #expect(await spool.newEvents().isEmpty)
        }

        @Test("a line still being written waits for its newline")
        func partialLineWaits() async throws {
            let spool = EventsSpool()
            let line = Self.event("Notification", message: "Claude needs your permission to run Bash")
            let cut = line.index(line.startIndex, offsetBy: 30)

            try Hermetic.append(Hermetic.lines([Self.event("Stop")]) + line[..<cut], to: Self.eventsPath)
            #expect(await spool.newEvents().map(\.hookEventName) == ["Stop"])

            try Hermetic.append(String(line[cut...]) + "\n", to: Self.eventsPath)
            let rest = await spool.newEvents()
            #expect(rest.map(\.hookEventName) == ["Notification"])
            #expect(rest.first?.message == "Claude needs your permission to run Bash")
        }

        @Test("lines that do not parse are dropped and the rest still arrive")
        func dropsGarbage() async throws {
            let spool = EventsSpool()
            try Hermetic.append(
                Hermetic.lines(["{ torn by a parallel writer", Self.event("Stop"), "", "42"]),
                to: Self.eventsPath
            )
            #expect(await spool.newEvents().map(\.hookEventName) == ["Stop"])
        }

        @Test("a spool that shrinks under the cursor is read again from the start")
        func rewindsWhenTruncated() async throws {
            let spool = EventsSpool()
            try Hermetic.append(Hermetic.lines([Self.event("Stop"), Self.event("Stop"), Self.event("Stop")]), to: Self.eventsPath)
            #expect(await spool.newEvents().count == 3)

            try Hermetic.write(Hermetic.lines([Self.event("SessionEnd")]), to: Self.eventsPath)
            #expect(await spool.newEvents().map(\.hookEventName) == ["SessionEnd"])
        }

        @Test("a spool over 5 MB at launch is thrown away, not replayed")
        func dropsAnOversizedSpool() async throws {
            let filler = String(repeating: "x", count: 1024 * 1024)
            try Hermetic.write(String(repeating: filler + "\n", count: 6), to: Self.eventsPath)

            let spool = EventsSpool()
            #expect(await spool.newEvents().isEmpty)
            #expect((EventsSpool.url.currentFileSize ?? 0) == 0)
        }

        @Test("an event decodes the four fields the menu uses, and tolerates others")
        func decodesEvents() throws {
            let line = #"{"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/work/x","tool_name":"Bash","extra":{"a":1}}"#
            let event = try JSONDecoder().decode(DeckEvent.self, from: Data(line.utf8))
            #expect(event.hookEventName == "PreToolUse")
            #expect(event.sessionId == "abc")
            #expect(event.toolName == "Bash")
            #expect(event.cwd == "/work/x")
            #expect(event.message == nil)
        }

        // MARK: - tools.jsonl

        @Test("the tool spool reports lines appended after launch, and nothing when there is no file")
        func toolSpool() async throws {
            let absent = ToolSpool()
            #expect(await absent.newEvents().isEmpty)

            try Hermetic.write(Hermetic.lines([Self.event("PreToolUse", tool: "Edit")]), to: Self.toolsPath)
            let spool = ToolSpool()
            #expect(await spool.newEvents().isEmpty)

            try Hermetic.append(Hermetic.lines([Self.event("PreToolUse", tool: "Bash"), Self.event("PostToolUse", tool: "Bash")]), to: Self.toolsPath)
            let events = await spool.newEvents()
            #expect(events.map(\.hookEventName) == ["PreToolUse", "PostToolUse"])
            #expect(events.map(\.toolName) == ["Bash", "Bash"])
        }

        @Test("rotation by the helper rewinds the tool spool, which replays the tail")
        func toolSpoolRotation() async throws {
            try Hermetic.write(Hermetic.lines([Self.event("PreToolUse", tool: "Read")]), to: Self.toolsPath)
            let spool = ToolSpool()
            try Hermetic.append(Hermetic.lines([Self.event("PreToolUse", tool: "Bash"), Self.event("PostToolUse", tool: "Bash")]), to: Self.toolsPath)
            #expect(await spool.newEvents().count == 2)

            // `tail -c` leaves a shorter file, so the cursor is past the end.
            try Hermetic.write(Hermetic.lines([Self.event("PostToolUse", tool: "Bash")]), to: Self.toolsPath)
            #expect(await spool.newEvents().map(\.hookEventName) == ["PostToolUse"])
        }

        // MARK: - history.jsonl

        private static func prompt(_ text: String?, session: String?, at date: Date) -> String {
            var fields: [String] = []
            if let text { fields.append("\"display\":\"\(text)\"") }
            if let session { fields.append("\"sessionId\":\"\(session)\"") }
            fields.append("\"timestamp\":\(Hermetic.epochMilliseconds(date))")
            return "{" + fields.joined(separator: ",") + "}"
        }

        private static let historyPath = ".claude/history.jsonl"

        @Test("each session's row shows its most recent prompt")
        func lastPromptPerSession() async throws {
            let now = Date()
            try Hermetic.write(Hermetic.lines([
                Self.prompt("first", session: "a", at: now.addingTimeInterval(-300)),
                Self.prompt("for b", session: "b", at: now.addingTimeInterval(-200)),
                Self.prompt("second", session: "a", at: now.addingTimeInterval(-100)),
            ]), to: Self.historyPath)

            let prompts = await HistoryTail().latestPrompts()
            #expect(prompts == ["a": "second", "b": "for b"])
        }

        @Test("only lines appended since the last read are processed")
        func historyIsIncremental() async throws {
            let now = Date()
            try Hermetic.write(Hermetic.lines([Self.prompt("one", session: "a", at: now)]), to: Self.historyPath)
            let tail = HistoryTail()
            #expect(await tail.latestPrompts() == ["a": "one"])

            try Hermetic.append(Hermetic.lines([Self.prompt("two", session: "a", at: now), Self.prompt("hello", session: "c", at: now)]), to: Self.historyPath)
            #expect(await tail.latestPrompts() == ["a": "two", "c": "hello"])
        }

        @Test("a half-written history line is left for the next read")
        func historyPartialLine() async throws {
            let now = Date()
            let whole = Self.prompt("complete", session: "a", at: now)
            let torn = Self.prompt("torn", session: "b", at: now)
            let cut = torn.index(torn.startIndex, offsetBy: 25)

            try Hermetic.write(Hermetic.lines([whole]) + torn[..<cut], to: Self.historyPath)
            let tail = HistoryTail()
            #expect(await tail.latestPrompts() == ["a": "complete"])

            try Hermetic.append(String(torn[cut...]) + "\n", to: Self.historyPath)
            #expect(await tail.latestPrompts() == ["a": "complete", "b": "torn"])
        }

        @Test("lines with no session, and entries with no text, are handled")
        func historyToleratesOddLines() async throws {
            let now = Date()
            try Hermetic.write(Hermetic.lines([
                Self.prompt("orphan", session: nil, at: now),
                Self.prompt("kept", session: "a", at: now),
                Self.prompt(nil, session: "a", at: now),   // no text: the earlier prompt stays
                "not json",
            ]), to: Self.historyPath)

            #expect(await HistoryTail().latestPrompts() == ["a": "kept"])
        }

        @Test("sessions that prompted today are counted, and yesterday's are not")
        func promptedToday() async throws {
            let now = Date()
            let yesterday = Hermetic.startOfToday.addingTimeInterval(-3600)
            try Hermetic.write(Hermetic.lines([
                Self.prompt("old", session: "yesterday-only", at: yesterday),
                Self.prompt("both", session: "both", at: yesterday),
                Self.prompt("both again", session: "both", at: now),
                Self.prompt("new", session: "today-only", at: now),
            ]), to: Self.historyPath)

            let tail = HistoryTail()
            _ = await tail.latestPrompts()
            #expect(await tail.sessionsPromptedToday() == ["both", "today-only"])
        }

        @Test("a history that is only from yesterday counts nobody today")
        func promptedTodayIsEmptyOnANewDay() async throws {
            let yesterday = Hermetic.startOfToday.addingTimeInterval(-3600)
            try Hermetic.write(Hermetic.lines([Self.prompt("old", session: "a", at: yesterday)]), to: Self.historyPath)

            let tail = HistoryTail()
            _ = await tail.latestPrompts()
            #expect(await tail.sessionsPromptedToday().isEmpty)
        }

        @Test("a history that shrinks is read again from the start and forgets what was removed")
        func historyRewinds() async throws {
            let now = Date()
            try Hermetic.write(Hermetic.lines([
                Self.prompt("a long first prompt to make the file big", session: "a", at: now),
                Self.prompt("another long prompt so that shrinking is certain", session: "b", at: now),
            ]), to: Self.historyPath)
            let tail = HistoryTail()
            #expect(await tail.latestPrompts().count == 2)

            try Hermetic.write(Hermetic.lines([Self.prompt("new", session: "c", at: now)]), to: Self.historyPath)
            #expect(await tail.latestPrompts() == ["c": "new"])
        }
    }
}
