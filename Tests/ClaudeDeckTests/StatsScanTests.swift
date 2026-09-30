import Foundation
import Testing

@testable import ClaudeDeck

/// Today's token count is rebuilt from session transcripts on every minute tick, and the
/// lifetime row is Claude Code's own counter with those transcripts added on top. These
/// tests write transcripts into a throwaway home and read them back through the real
/// reader, including the ways Claude Code writes them that make a naive sum wrong.
extension DeckTests {
    @Suite struct StatsScanTests {
        private static let project = "-work-alpha"

        init() throws { try Hermetic.reset() }

        private static func transcript(_ name: String, project: String = StatsScanTests.project, lines: [String]) throws {
            try Hermetic.write(Hermetic.lines(lines), to: ".claude/projects/\(project)/\(name).jsonl")
        }

        private static func snapshot(_ reader: StatsReader = StatsReader()) async -> StatsSnapshot {
            await reader.snapshot(sessionIdsStartedToday: [], promptedToday: [])
        }

        private static var today: Date { Hermetic.startOfToday.addingTimeInterval(60) }

        // MARK: - One count per request

        @Test("a message written as several content blocks counts once, at its final size")
        func countsEachRequestOnce() async throws {
            let at = Self.today
            try Self.transcript("s1", lines: [
                // Claude Code writes one line per content block and repeats `usage` on each,
                // with output_tokens growing as the blocks stream in.
                Hermetic.assistantLine(id: "msg_1", at: at, input: 10, output: 40, cacheWrite: 1000, cacheRead: 50_000),
                Hermetic.assistantLine(id: "msg_1", at: at, input: 10, output: 90, cacheWrite: 1000, cacheRead: 50_000),
                Hermetic.assistantLine(id: "msg_1", at: at, input: 10, output: 220, cacheWrite: 1000, cacheRead: 50_000),
                Hermetic.assistantLine(id: "msg_2", at: at, input: 5, output: 30, cacheWrite: 0, cacheRead: 60_000),
            ])

            let stats = await Self.snapshot()
            #expect(stats.todayTotals == TokenTotals(input: 15, output: 250, cacheCreation: 1000, cacheRead: 110_000))
        }

        @Test("a forked session repeats another transcript's messages and they are counted once")
        func forksAreNotDoubleCounted() async throws {
            let shared = Hermetic.assistantLine(id: "msg_shared", at: Self.today, output: 100)
            try Self.transcript("original", lines: [shared])
            try Self.transcript("fork", lines: [shared, Hermetic.assistantLine(id: "msg_new", at: Self.today, output: 7)])

            let stats = await Self.snapshot()
            #expect(stats.todayTotals.output == 107)
        }

        @Test("lines with no message id cannot be folded, so each one counts once")
        func idlessLinesCountSeparately() async throws {
            try Self.transcript("s1", lines: [
                Hermetic.assistantLine(id: nil, at: Self.today, output: 1),
                Hermetic.assistantLine(id: nil, at: Self.today, output: 2),
            ])

            let reader = StatsReader()
            let first = await Self.snapshot(reader)
            #expect(first.todayTotals.output == 3)

            // Reading again must not count them a second time.
            let second = await Self.snapshot(reader)
            #expect(second.todayTotals.output == 3)
        }

        @Test("only assistant lines with usage count, and broken lines are skipped")
        func ignoresEverythingElse() async throws {
            try Self.transcript("s1", lines: [
                #"{"type":"user","timestamp":"\#(Hermetic.stamp(Self.today))","message":{"usage":{"output_tokens":999}}}"#,
                "this line is not json",
                #"{"type":"assistant","timestamp":"\#(Hermetic.stamp(Self.today))","message":{"id":"msg_nousage","model":"claude-opus-5"}}"#,
                Hermetic.assistantLine(id: "msg_ok", at: Self.today, output: 12),
            ])

            let stats = await Self.snapshot()
            #expect(stats.todayTotals.output == 12)
        }

        // MARK: - Today, and whose it is

        @Test("yesterday stays out of today")
        func todayStartsAtLocalMidnight() async throws {
            try Self.transcript("s1", lines: [
                Hermetic.assistantLine(id: "msg_old", at: Hermetic.startOfToday.addingTimeInterval(-3600), output: 500),
                Hermetic.assistantLine(id: "msg_new", at: Self.today, output: 5),
            ])

            let stats = await Self.snapshot()
            #expect(stats.todayTotals.output == 5)
        }

        @Test("today's tokens are split by the project the transcript says it ran in")
        func splitsByProjectFromCwd() async throws {
            try Self.transcript("s1", lines: [
                Hermetic.assistantLine(id: "msg_a", at: Self.today, cwd: "/Users/someone/dev/alpha", output: 10),
            ])
            try Self.transcript("s2", project: "-other", lines: [
                Hermetic.assistantLine(id: "msg_b", at: Self.today, cwd: "/Users/someone/dev/beta", output: 20),
                Hermetic.assistantLine(id: "msg_c", at: Self.today, cwd: "/Users/someone/dev/beta", output: 1),
            ])

            let stats = await Self.snapshot()
            #expect(stats.todayByProject["alpha"]?.output == 10)
            #expect(stats.todayByProject["beta"]?.output == 21)
            #expect(stats.todayByProject.count == 2)
        }

        @Test("today is split by model, and the day starts at its first message")
        func splitsByModel() async throws {
            let early = Self.today
            let late = Self.today.addingTimeInterval(1800)
            try Self.transcript("s1", lines: [
                Hermetic.assistantLine(id: "msg_1", at: late, model: "claude-sonnet-5", output: 4),
                Hermetic.assistantLine(id: "msg_2", at: early, model: "claude-opus-5", output: 9),
            ])

            let stats = await Self.snapshot()
            #expect(stats.today["claude-sonnet-5"]?.output == 4)
            #expect(stats.today["claude-opus-5"]?.output == 9)
            let started = try #require(stats.todayStarted)
            #expect(abs(started.timeIntervalSince(early)) < 1)
        }

        @Test("the session count is the union of sessions started and sessions prompted today")
        func countsSessionsFromBothSources() async {
            let stats = await StatsReader().snapshot(
                sessionIdsStartedToday: ["a", "b"],
                promptedToday: ["b", "c"]
            )
            #expect(stats.todaySessions == 3)
        }

        // MARK: - Incremental reads

        @Test("a line still being written is left for the next read")
        func partialLineIsNotConsumed() async throws {
            let complete = Hermetic.assistantLine(id: "msg_1", at: Self.today, output: 1)
            let second = Hermetic.assistantLine(id: "msg_2", at: Self.today, output: 2)
            let cut = second.index(second.startIndex, offsetBy: 40)

            try Hermetic.write(complete + "\n" + second[..<cut], to: ".claude/projects/\(Self.project)/s1.jsonl")
            let reader = StatsReader()
            let before = await Self.snapshot(reader)
            #expect(before.todayTotals.output == 1)

            try Hermetic.append(String(second[cut...]) + "\n", to: ".claude/projects/\(Self.project)/s1.jsonl")
            let after = await Self.snapshot(reader)
            #expect(after.todayTotals.output == 3)
        }

        @Test("a later line for a known message replaces the earlier one")
        func laterLineReplacesEarlier() async throws {
            let path = ".claude/projects/\(Self.project)/s1.jsonl"
            try Hermetic.write(
                Hermetic.lines([Hermetic.assistantLine(id: "msg_1", at: Self.today, output: 10)]),
                to: path
            )
            let reader = StatsReader()
            let first = await Self.snapshot(reader)
            #expect(first.todayTotals.output == 10)

            // The same message streams a few more tokens after the first read.
            try Hermetic.append(
                Hermetic.lines([Hermetic.assistantLine(id: "msg_1", at: Self.today, output: 80)]),
                to: path
            )
            let second = await Self.snapshot(reader)
            #expect(second.todayTotals.output == 80)
        }

        @Test("a transcript that shrinks is read again from the start")
        func shrunkFileIsRescanned() async throws {
            let path = ".claude/projects/\(Self.project)/s1.jsonl"
            try Hermetic.write(
                Hermetic.lines([
                    Hermetic.assistantLine(id: "msg_1", at: Self.today, output: 100),
                    Hermetic.assistantLine(id: "msg_2", at: Self.today, output: 100),
                ]),
                to: path
            )
            let reader = StatsReader()
            let first = await Self.snapshot(reader)
            #expect(first.todayTotals.output == 200)

            try Hermetic.write(Hermetic.lines([Hermetic.assistantLine(id: "msg_3", at: Self.today, output: 7)]), to: path)
            let second = await Self.snapshot(reader)
            #expect(second.todayTotals.output == 7)
        }

        // MARK: - Lifetime

        private static func statsCache(computed: Date, sessions: Int = 100) -> String {
            """
            {
              "lastComputedDate": "\(Hermetic.day(computed))",
              "totalSessions": \(sessions),
              "modelUsage": {
                "claude-opus-5": {
                  "inputTokens": 1000, "outputTokens": 2000,
                  "cacheReadInputTokens": 3000, "cacheCreationInputTokens": 4000
                }
              },
              "dailyModelTokens": [
                {"date": "2026-01-01", "tokensByModel": {"claude-opus-5": 10, "claude-sonnet-5": 5}},
                {"date": "2026-01-02", "tokensByModel": {"claude-opus-5": 20}}
              ]
            }
            """
        }

        @Test("lifetime is Claude Code's counter plus the transcript days it is missing")
        func lifetimeIsCachePlusTopUp() async throws {
            let twoDaysAgo = Hermetic.startOfToday.addingTimeInterval(-2 * 86400 + 12 * 3600)
            try Hermetic.write(Self.statsCache(computed: twoDaysAgo, sessions: 239), to: ".claude/stats-cache.json")

            let yesterday = Hermetic.startOfToday.addingTimeInterval(-12 * 3600)
            try Self.transcript("s1", lines: [
                Hermetic.assistantLine(id: "msg_y", at: yesterday, input: 10, output: 20),
                Hermetic.assistantLine(id: "msg_t", at: Self.today, input: 1, output: 2),
            ])

            let stats = await Self.snapshot()
            #expect(stats.lifetimeSessions == 239)
            #expect(stats.lifetimeAsOf == Hermetic.day(twoDaysAgo))
            #expect(stats.lifetimeIncludesLive)
            let opus = try #require(stats.lifetime["claude-opus-5"])
            #expect(opus == TokenTotals(input: 1000 + 10 + 1, output: 2000 + 20 + 2, cacheCreation: 4000, cacheRead: 3000))
            // Today is only today's part of the same scan.
            #expect(stats.todayTotals == TokenTotals(input: 1, output: 2))
        }

        @Test("with no cache to build on, lifetime stays empty rather than reporting a few days as one")
        func lifetimeNeedsACache() async throws {
            try Self.transcript("s1", lines: [Hermetic.assistantLine(id: "msg_1", at: Self.today, output: 50)])

            let stats = await Self.snapshot()
            #expect(stats.lifetime.isEmpty)
            #expect(stats.lifetimeAsOf == nil)
            #expect(!stats.lifetimeIncludesLive)
            #expect(stats.todayTotals.output == 50)
        }

        @Test("the cache alone, with nothing newer, is shown as it is")
        func cacheWithoutTopUp() async throws {
            let longAgo = Hermetic.startOfToday.addingTimeInterval(-30 * 86400)
            try Hermetic.write(Self.statsCache(computed: longAgo), to: ".claude/stats-cache.json")

            let stats = await Self.snapshot()
            #expect(stats.lifetimeTotals.all == 10_000)
            #expect(!stats.lifetimeIncludesLive)
        }

        @Test("recent days keep the last seven and sum their models")
        func recentDaysSumModels() async throws {
            try Hermetic.write(Self.statsCache(computed: Date()), to: ".claude/stats-cache.json")

            let stats = await Self.snapshot()
            #expect(stats.recentDays == [
                DayTokens(date: "2026-01-01", tokens: 15),
                DayTokens(date: "2026-01-02", tokens: 20),
            ])
        }

        // MARK: - Prices

        @Test("the price file is written with defaults on first run, then read back as edited")
        func pricesFileLifecycle() async throws {
            let reader = StatsReader()
            let first = await Self.snapshot(reader)
            #expect(FileManager.default.fileExists(atPath: StatsReader.pricesURL.path))
            #expect(first.prices.rate(for: "claude-opus-5") != nil)

            let edited = #"{"models":{"claude-opus-5":{"input":1,"output":2}}}"#
            try Data(edited.utf8).write(to: StatsReader.pricesURL)
            let second = await Self.snapshot(reader)
            #expect(second.prices.rate(for: "claude-opus-5") == ModelPrice(input: 1, output: 2))
            #expect(second.prices.rate(for: "claude-sonnet-5") == nil)
        }

        @Test("a price file that no longer parses falls back to the defaults")
        func brokenPricesFallBack() async throws {
            try Hermetic.write("{ not json", to: ".claude/claude-deck/prices.json")

            let stats = await Self.snapshot()
            #expect(stats.prices == Prices.fallback)
        }
    }
}
