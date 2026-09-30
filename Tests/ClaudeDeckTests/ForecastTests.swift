import Foundation
import Testing

@testable import ClaudeDeck

/// "On course to hit 100% Tue 03:04" is a straight line fitted through readings the app has
/// taken itself, since the limits arrive as bare percentages. The line is only worth
/// drawing under conditions, and each of them is a separate way to print a confident wrong
/// time.
extension DeckTests {
    @Suite struct ForecastTests {
        init() throws { try Hermetic.reset() }

        private static let hour: TimeInterval = 3600

        /// One earlier reading, as the app appends it to `usage-history.jsonl`.
        private static func sample(_ kind: String, hoursAgo: Double, percent: Int, now: Date) -> String {
            let at = now.addingTimeInterval(-hoursAgo * hour).timeIntervalSince1970
            return "{\"at\":\(at),\"kind\":\"\(kind)\",\"percent\":\(percent)}"
        }

        private static func writeHistory(_ lines: [String]) throws {
            try Hermetic.write(Hermetic.lines(lines), to: ".claude/claude-deck/usage-history.jsonl")
        }

        /// The reading the app sees right now.
        private static func writeConfig(
            kind: String = "weekly_all",
            percent: Int,
            resetsIn hours: Double,
            now: Date
        ) throws {
            let resets = Hermetic.sixDigitISO(now.addingTimeInterval(hours * hour))
            try Hermetic.write("""
            {"cachedUsageUtilization":{"fetched_at_ms":\(Hermetic.epochMilliseconds(now)),"utilization":{"limits":[
            {"kind":"\(kind)","percent":\(percent),"severity":"normal","resets_at":"\(resets)"}
            ]}}}
            """, to: ".claude.json")
        }

        private static func forecast(_ kind: String = "weekly_all") async -> Date? {
            await UsageReader().snapshot().forecast[kind]
        }

        // MARK: - The line

        @Test("three readings over more than an hour project when the limit fills")
        func projectsALine() async throws {
            let now = Date()
            // 60, 65, 70 and now 75: 3 percent an hour, 25 points to go.
            try Self.writeHistory([
                Self.sample("weekly_all", hoursAgo: 5, percent: 60, now: now),
                Self.sample("weekly_all", hoursAgo: 3, percent: 65, now: now),
                Self.sample("weekly_all", hoursAgo: 1, percent: 70, now: now),
            ])
            try Self.writeConfig(percent: 75, resetsIn: 72, now: now)

            let reaches = try #require(await Self.forecast())
            let expected = now.addingTimeInterval(25.0 / 3.0 * Self.hour)
            #expect(abs(reaches.timeIntervalSince(expected)) < 30)
        }

        @Test("the order of the history file does not matter")
        func sortsBeforeFitting() async throws {
            let now = Date()
            try Self.writeHistory([
                Self.sample("weekly_all", hoursAgo: 1, percent: 70, now: now),
                Self.sample("weekly_all", hoursAgo: 5, percent: 60, now: now),
                Self.sample("weekly_all", hoursAgo: 3, percent: 65, now: now),
            ])
            try Self.writeConfig(percent: 75, resetsIn: 72, now: now)

            let reaches = try #require(await Self.forecast())
            let expected = now.addingTimeInterval(25.0 / 3.0 * Self.hour)
            #expect(abs(reaches.timeIntervalSince(expected)) < 30)
        }

        @Test("only readings since the last reset count")
        func fitsOnlyTheCurrentWindow() async throws {
            let now = Date()
            // 90 and 95, then the window resets and climbs 10, 14, 18. Fitted across the reset
            // the slope is negative and nothing would show; fitted since it, 2 percent an hour.
            try Self.writeHistory([
                Self.sample("weekly_all", hoursAgo: 6, percent: 90, now: now),
                Self.sample("weekly_all", hoursAgo: 5, percent: 95, now: now),
                Self.sample("weekly_all", hoursAgo: 4, percent: 10, now: now),
                Self.sample("weekly_all", hoursAgo: 2, percent: 14, now: now),
            ])
            try Self.writeConfig(percent: 18, resetsIn: 120, now: now)

            let reaches = try #require(await Self.forecast())
            let expected = now.addingTimeInterval(82.0 / 2.0 * Self.hour)
            #expect(abs(reaches.timeIntervalSince(expected)) < 30)
        }

        // MARK: - When to say nothing

        @Test("nothing is shown for a limit that resets before it would fill")
        func silentWhenTheWindowResetsFirst() async throws {
            let now = Date()
            try Self.writeHistory([
                Self.sample("weekly_all", hoursAgo: 5, percent: 60, now: now),
                Self.sample("weekly_all", hoursAgo: 3, percent: 65, now: now),
                Self.sample("weekly_all", hoursAgo: 1, percent: 70, now: now),
            ])
            // Fills in about eight hours; resets in two.
            try Self.writeConfig(percent: 75, resetsIn: 2, now: now)

            #expect(await Self.forecast() == nil)
        }

        @Test("nothing is shown from fewer than three readings")
        func silentWithTwoReadings() async throws {
            let now = Date()
            try Self.writeHistory([Self.sample("weekly_all", hoursAgo: 3, percent: 60, now: now)])
            try Self.writeConfig(percent: 75, resetsIn: 72, now: now)

            #expect(await Self.forecast() == nil)
        }

        @Test("nothing is shown when the readings span less than an hour")
        func silentOnAShortSpan() async throws {
            let now = Date()
            try Self.writeHistory([
                Self.sample("weekly_all", hoursAgo: 0.6, percent: 70, now: now),
                Self.sample("weekly_all", hoursAgo: 0.3, percent: 72, now: now),
            ])
            try Self.writeConfig(percent: 75, resetsIn: 72, now: now)

            #expect(await Self.forecast() == nil)
        }

        @Test("a flat or falling line projects nothing")
        func silentWhenNotRising() async throws {
            let now = Date()
            try Self.writeHistory([
                Self.sample("weekly_all", hoursAgo: 5, percent: 75, now: now),
                Self.sample("weekly_all", hoursAgo: 3, percent: 75, now: now),
                Self.sample("weekly_all", hoursAgo: 1, percent: 75, now: now),
            ])
            try Self.writeConfig(percent: 75, resetsIn: 72, now: now)

            #expect(await Self.forecast() == nil)
        }

        @Test("a limit that is already full projects nothing")
        func silentAtOneHundred() async throws {
            let now = Date()
            try Self.writeHistory([
                Self.sample("weekly_all", hoursAgo: 5, percent: 90, now: now),
                Self.sample("weekly_all", hoursAgo: 3, percent: 95, now: now),
                Self.sample("weekly_all", hoursAgo: 1, percent: 99, now: now),
            ])
            try Self.writeConfig(percent: 100, resetsIn: 72, now: now)

            #expect(await Self.forecast() == nil)
        }

        @Test("each limit is fitted on its own readings")
        func limitsAreIndependent() async throws {
            let now = Date()
            try Self.writeHistory([
                Self.sample("weekly_all", hoursAgo: 5, percent: 60, now: now),
                Self.sample("weekly_all", hoursAgo: 3, percent: 65, now: now),
                Self.sample("weekly_all", hoursAgo: 1, percent: 70, now: now),
                // A different limit, flat, must not borrow the first one's slope.
                Self.sample("session", hoursAgo: 5, percent: 20, now: now),
                Self.sample("session", hoursAgo: 3, percent: 20, now: now),
                Self.sample("session", hoursAgo: 1, percent: 20, now: now),
            ])
            let resets = Hermetic.sixDigitISO(now.addingTimeInterval(72 * Self.hour))
            try Hermetic.write("""
            {"cachedUsageUtilization":{"fetched_at_ms":\(Hermetic.epochMilliseconds(now)),"utilization":{"limits":[
            {"kind":"weekly_all","percent":75,"severity":"normal","resets_at":"\(resets)"},
            {"kind":"session","percent":20,"severity":"normal","resets_at":"\(resets)"}
            ]}}}
            """, to: ".claude.json")

            let forecast = await UsageReader().snapshot().forecast
            #expect(forecast["weekly_all"] != nil)
            #expect(forecast["session"] == nil)
        }

        // MARK: - The history file

        @Test("one reading is recorded once, however often the file is re-read")
        func oneSamplePerFetch() async throws {
            let now = Date()
            try Self.writeConfig(percent: 40, resetsIn: 72, now: now)
            _ = await UsageReader().snapshot()

            func lines() throws -> Int {
                let text = try String(contentsOf: EventsSpool.directory.appending(path: "usage-history.jsonl"), encoding: .utf8)
                return text.split(separator: "\n").count
            }
            #expect(try lines() == 1)

            // Claude Code rewrites the file more often than the figures move. Same fetch time,
            // different bytes: a second reader must not add a second sample.
            try Hermetic.write("""
            {"cachedUsageUtilization":{"fetched_at_ms":\(Hermetic.epochMilliseconds(now)),"utilization":{"limits":[
            {"kind":"weekly_all","percent":40,"severity":"normal","note":"padding so the size differs"}
            ]}}}
            """, to: ".claude.json")
            _ = await UsageReader().snapshot()
            #expect(try lines() == 1)
        }

        @Test("the history is capped at 400 readings and keeps the newest")
        func historyIsCapped() async throws {
            let now = Date()
            let old = (0..<450).map { index in
                "{\"at\":\(now.addingTimeInterval(Double(index - 500) * 60).timeIntervalSince1970),\"kind\":\"weekly_all\",\"percent\":\(index % 90)}"
            }
            try Self.writeHistory(old)
            try Self.writeConfig(percent: 77, resetsIn: 72, now: now)
            _ = await UsageReader().snapshot()

            let text = try String(contentsOf: EventsSpool.directory.appending(path: "usage-history.jsonl"), encoding: .utf8)
            let kept = text.split(separator: "\n")
            #expect(kept.count == 400)
            #expect(kept.last?.contains("\"percent\":77") == true)
        }

        @Test("the history file is written private")
        func historyIsPrivate() async throws {
            try Self.writeConfig(percent: 40, resetsIn: 72, now: Date())
            _ = await UsageReader().snapshot()

            let url = EventsSpool.directory.appending(path: "usage-history.jsonl")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
        }
    }
}
