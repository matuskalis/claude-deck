import Foundation
import Testing

@testable import ClaudeDeck

/// Every context ring in the session list comes from the newest assistant message in a
/// transcript that can be tens of megabytes. The reader seeks backwards from the end in
/// 64 KB chunks and gives up after 2 MB, so the interesting cases are the edges of that
/// scan: a line cut by a chunk boundary, and a file with nothing to find.
extension DeckTests {
    @Suite struct TranscriptTailTests {
        init() throws { try Hermetic.reset() }

        private static let chunk = 64 * 1024
        private static let scanLimit = 2 * 1024 * 1024

        @discardableResult
        private static func transcript(_ session: String, project: String = "-work-alpha", lines: [String]) throws -> URL {
            try Hermetic.write(Hermetic.lines(lines), to: ".claude/projects/\(project)/\(session).jsonl")
        }

        private static func assistant(
            _ id: String,
            model: String = "claude-opus-5",
            input: Int = 0,
            output: Int = 0,
            cacheWrite: Int = 0,
            cacheRead: Int = 0
        ) -> String {
            Hermetic.assistantLine(
                id: id,
                at: Date(),
                model: model,
                input: input,
                output: output,
                cacheWrite: cacheWrite,
                cacheRead: cacheRead
            )
        }

        /// A line that is not an assistant message, exactly `bytes` long before its newline.
        private static func filler(bytes: Int) -> String {
            let prefix = #"{"type":"user","pad":""#
            let suffix = #""}"#
            return prefix + String(repeating: "x", count: max(0, bytes - prefix.utf8.count - suffix.utf8.count)) + suffix
        }

        private static func usage(of session: String, reader: TranscriptTail = TranscriptTail()) async -> TranscriptUsage? {
            await reader.usage(for: session)
        }

        // MARK: - What counts

        @Test("context used is input plus cache writes plus cache reads, and never output")
        func contextExcludesOutput() async throws {
            try Self.transcript("s1", lines: [
                Self.assistant("m1", input: 100, output: 50, cacheRead: 1000),
                #"{"type":"user","message":{"content":"next"}}"#,
                Self.assistant("m2", model: "claude-sonnet-5", input: 5, output: 9999, cacheWrite: 200, cacheRead: 140_000),
                #"{"type":"user","message":{"content":"tool result"}}"#,
            ])

            let usage = try #require(await Self.usage(of: "s1"))
            #expect(usage.contextUsed == 140_205)
            #expect(usage.model == "claude-sonnet-5")
        }

        @Test("a newest assistant line that used nothing is skipped for the one before it")
        func skipsEmptyUsage() async throws {
            try Self.transcript("s1", lines: [
                Self.assistant("m1", input: 10, cacheRead: 40_000),
                Self.assistant("m2"),
            ])

            let usage = try #require(await Self.usage(of: "s1"))
            #expect(usage.contextUsed == 40_010)
        }

        @Test("the transcript is found under whichever project folder holds it")
        func findsTheFileInAnyProject() async throws {
            try Self.transcript("other", project: "-work-alpha", lines: [Self.assistant("m1", input: 1)])
            try Self.transcript("wanted", project: "-work-beta", lines: [Self.assistant("m2", input: 2)])

            #expect(await Self.usage(of: "wanted")?.contextUsed == 2)
            #expect(await Self.usage(of: "unknown") == nil)
        }

        @Test("a transcript with no assistant message yields nothing")
        func noAssistantLines() async throws {
            try Self.transcript("s1", lines: [#"{"type":"user","message":{"content":"hello"}}"#, "garbage"])
            #expect(await Self.usage(of: "s1") == nil)
        }

        @Test("a longer transcript is read again, and an unchanged one comes from the cache")
        func cacheFollowsFileSize() async throws {
            let reader = TranscriptTail()
            let url = try Self.transcript("s1", lines: [Self.assistant("m1", input: 10)])
            #expect(await Self.usage(of: "s1", reader: reader)?.contextUsed == 10)
            #expect(await Self.usage(of: "s1", reader: reader)?.contextUsed == 10)

            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((Self.assistant("m2", input: 77) + "\n").utf8))
            try handle.close()
            #expect(await Self.usage(of: "s1", reader: reader)?.contextUsed == 77)
        }

        // MARK: - The edges of the backwards scan

        @Test("an assistant line far from the end is found across many chunks")
        func findsAcrossChunks() async throws {
            var lines = [Self.assistant("target", input: 4242)]
            lines += Array(repeating: Self.filler(bytes: 1000), count: 400)   // about 400 KB after it
            try Self.transcript("s1", lines: lines)

            #expect(await Self.usage(of: "s1")?.contextUsed == 4242)
        }

        @Test("a line cut by a chunk boundary is reassembled")
        func reassemblesALineSplitAtTheBoundary() async throws {
            let target = Self.assistant("target", input: 31337)
            let targetBytes = target.utf8.count + 1
            // Put the boundary 64 KB from the end in the middle of the target line.
            let tail = Self.chunk - targetBytes / 2
            var lines = [Self.filler(bytes: 300), target]
            var remaining = tail
            while remaining > 0 {
                let size = min(remaining, 1000)
                lines.append(Self.filler(bytes: max(size, 30)))
                remaining -= max(size, 30) + 1
            }
            let url = try Self.transcript("s1", lines: lines)

            // Sanity check on the fixture itself: the boundary really does fall inside the line.
            let data = try Data(contentsOf: url)
            let boundary = data.count - Self.chunk
            let start = try #require(data.range(of: Data(target.utf8))).lowerBound
            #expect(start < boundary && boundary < start + target.utf8.count)

            #expect(await Self.usage(of: "s1")?.contextUsed == 31337)
        }

        @Test("the scan gives up after 2 MB rather than reading a whole huge transcript")
        func givesUpAfterTwoMegabytes() async throws {
            let target = Self.assistant("target", input: 99)
            let filler = Self.filler(bytes: 10_000)
            let perLine = filler.utf8.count + 1

            // Just inside the limit: found.
            try Self.transcript("inside", lines: [target] + Array(repeating: filler, count: (Self.scanLimit - 300 * 1024) / perLine))
            #expect(await Self.usage(of: "inside")?.contextUsed == 99)

            // Well past it: not found, and not an error.
            try Self.transcript("beyond", lines: [target] + Array(repeating: filler, count: (Self.scanLimit + 300 * 1024) / perLine))
            #expect(await Self.usage(of: "beyond") == nil)
        }

        // MARK: - Context window

        @Test("the window is 200k unless a 1M model is configured or usage already exceeds 200k")
        func contextWindowInference() {
            #expect(TranscriptTail.contextWindow(used: 150_000, oneMillionConfigured: false) == 200_000)
            #expect(TranscriptTail.contextWindow(used: 200_000, oneMillionConfigured: false) == 200_000)
            #expect(TranscriptTail.contextWindow(used: 200_001, oneMillionConfigured: false) == 1_000_000)
            #expect(TranscriptTail.contextWindow(used: 10, oneMillionConfigured: true) == 1_000_000)
        }

        @Test("a [1m] model in settings.json switches the window")
        func readsTheConfiguredModel() throws {
            #expect(!TranscriptTail.oneMillionConfigured())

            try Hermetic.write(#"{"model":"claude-opus-5[1m]"}"#, to: ".claude/settings.json")
            #expect(TranscriptTail.oneMillionConfigured())

            try Hermetic.write(#"{"model":"claude-opus-5"}"#, to: ".claude/settings.json")
            #expect(!TranscriptTail.oneMillionConfigured())

            try Hermetic.write(#"{"model":42}"#, to: ".claude/settings.json")
            #expect(!TranscriptTail.oneMillionConfigured())

            try Hermetic.write("not json", to: ".claude/settings.json")
            #expect(!TranscriptTail.oneMillionConfigured())
        }

        @Test("the ring shows whole percent of the window, and nothing without a reading")
        func contextPercent() {
            func session(used: Int?, window: Int) -> Session {
                Session(
                    id: "id", pid: 1, name: "s", cwd: "/tmp", state: .idle,
                    usage: used.map { TranscriptUsage(model: nil, contextUsed: $0) },
                    contextWindow: window
                )
            }
            #expect(session(used: 142_803, window: 200_000).contextPercent == 71)
            #expect(session(used: 250_000, window: 1_000_000).contextPercent == 25)
            #expect(session(used: 0, window: 200_000).contextPercent == 0)
            #expect(session(used: nil, window: 200_000).contextPercent == nil)
            #expect(session(used: 5, window: 0).contextPercent == nil)
        }
    }
}
