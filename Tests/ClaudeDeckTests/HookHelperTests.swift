import Foundation
import Testing

@testable import ClaudeDeck

/// The spool helper is the one place hook payloads are handled, and a payload is arbitrary
/// text written by a model: a permission message can hold quotes, line breaks and escape
/// sequences. The helper builds a line of JSON out of shell strings, so everything that goes
/// in has to come out as one valid line, and nothing beyond the few kept fields may come out
/// at all.
extension DeckTests {
    @Suite struct HookHelperTests {
        init() throws {
            try Hermetic.reset()
            try HookInstaller.install()
        }

        private static func payload(_ fields: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        }

        /// Runs the installed helper with the payload on stdin, in a home of its own.
        @discardableResult
        private static func run(_ kind: String, _ event: String, stdin text: String) throws -> Int32 {
            let process = Process()
            process.executableURL = HookInstaller.helperURL
            process.arguments = [kind, event]
            process.environment = ["HOME": Hermetic.root.path, "PATH": "/bin:/usr/bin"]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data(text.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        }

        private static func spool(_ kind: String) throws -> String {
            try String(contentsOf: Hermetic.root.appending(path: ".claude/claude-deck/\(kind).jsonl"), encoding: .utf8)
        }

        private static func lastEvent(_ kind: String) throws -> DeckEvent {
            let line = try #require(try spool(kind).split(separator: "\n").last)
            return try JSONDecoder().decode(DeckEvent.self, from: Data(line.utf8))
        }

        // MARK: - The free-text field

        @Test("a message with quotes and backslashes still makes one valid line, and survives")
        func messageIsEscaped() throws {
            let message = #"Claude needs your permission to run "rm -rf build" in C:\work\app"#
            try Self.run("events", "Notification", stdin: Self.payload(["hook_event_name": "Notification", "session_id": "s1", "message": message]))

            let written = try Self.spool("events")
            #expect(written.split(separator: "\n").count == 1)
            #expect(try Self.lastEvent("events").message == message, "spool was: \(written)")
        }

        @Test("a message is cut to 200 characters")
        func messageIsCapped() throws {
            let message = String(repeating: "a", count: 300)
            try Self.run("events", "StopFailure", stdin: Self.payload(["hook_event_name": "StopFailure", "session_id": "s1", "message": message]))

            #expect(try Self.lastEvent("events").message == String(repeating: "a", count: 200))
        }

        @Test("line breaks become spaces and control characters are removed")
        func messageIsFlattened() throws {
            let message = "line one\nline two\r\ntabbed\there\u{07}bell\u{1B}[31mred"
            try Self.run("events", "Notification", stdin: Self.payload(["hook_event_name": "Notification", "session_id": "s1", "message": message]))

            #expect(try Self.spool("events").split(separator: "\n").count == 1)
            let kept = try #require(try Self.lastEvent("events").message)
            #expect(kept.unicodeScalars.allSatisfy { $0.value >= 0x20 })
            #expect(kept.hasPrefix("line one line two"))
            #expect(kept.contains("tabbed here"))
        }

        // MARK: - What is never kept

        @Test("only the two events that carry Claude Code's own message keep one")
        func messageOnlyWhereItIsWanted() throws {
            for event in ["Stop", "UserPromptSubmit", "SessionEnd"] {
                try Self.run("events", event, stdin: Self.payload(["hook_event_name": event, "session_id": "s1", "message": "kept?", "prompt": "a private prompt"]))
            }
            try Self.run("tools", "PreToolUse", stdin: Self.payload(["hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash", "message": "kept?"]))

            let text = try Self.spool("events") + Self.spool("tools")
            #expect(!text.contains("kept?"))
            #expect(!text.contains("private prompt"))
            #expect(text.contains("\"tool_name\":\"Bash\""))
        }

        @Test("a prompt or tool input that rides along with a notification is not recorded")
        func payloadExtrasAreDropped() throws {
            try Self.run("events", "Notification", stdin: Self.payload([
                "hook_event_name": "Notification",
                "session_id": "s1",
                "message": "Claude needs your permission to use Write",
                "prompt": "rotate the production key",
                "tool_input": ["file_path": "/secrets/prod.env", "content": "TOKEN=abc123"],
                "transcript_path": "/Users/someone/.claude/projects/x/s1.jsonl",
            ]))

            let text = try Self.spool("events")
            for leaked in ["production key", "prod.env", "abc123", "transcript_path", "someone"] {
                #expect(!text.contains(leaked), "\(leaked)")
            }
            #expect(try Self.lastEvent("events").message == "Claude needs your permission to use Write", "spool was: \(text)")
        }

        // MARK: - Failing safe

        @Test("a payload that is not JSON still exits 0, and records only the event name")
        func garbageExitsZero() throws {
            let status = try Self.run("events", "Stop", stdin: "this is not json at all")
            #expect(status == 0)
            #expect(try Self.spool("events") == "{\"hook_event_name\":\"Stop\"}\n")
        }

        @Test("a payload with no session id records no session id")
        func missingSessionId() throws {
            let status = try Self.run("events", "SessionEnd", stdin: "{}")
            #expect(status == 0)
            let event = try Self.lastEvent("events")
            #expect(event.hookEventName == "SessionEnd")
            #expect(event.sessionId == nil)
        }

        @Test("the spool the helper creates is private to its owner")
        func spoolIsPrivate() throws {
            try Self.run("events", "Stop", stdin: Self.payload(["hook_event_name": "Stop", "session_id": "s1"]))

            let url = Hermetic.root.appending(path: ".claude/claude-deck/events.jsonl")
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }

        // MARK: - Rotation

        @Test("past 256 KB the spool is cut to its last 64 KB, newest line last")
        func rotation() throws {
            let filler = try Self.payload(["hook_event_name": "Stop", "session_id": "filler-\(String(repeating: "x", count: 60))"])
            try Hermetic.write(String(repeating: filler + "\n", count: 4000), to: ".claude/claude-deck/events.jsonl")
            #expect((Hermetic.root.appending(path: ".claude/claude-deck/events.jsonl").currentFileSize ?? 0) > 262_144)

            try Self.run("events", "SessionEnd", stdin: Self.payload(["hook_event_name": "SessionEnd", "session_id": "the-newest"]))

            let size = Hermetic.root.appending(path: ".claude/claude-deck/events.jsonl").currentFileSize ?? 0
            #expect(size <= 65_536 && size > 60_000)
            let newest = try Self.lastEvent("events")
            #expect(newest.sessionId == "the-newest")
        }
    }
}
