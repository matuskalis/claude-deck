import Foundation
import Testing

@testable import ClaudeDeck

/// The plan-limit meters are read from a cache file that Claude Code owns, rewrites in
/// place, and does not document. The shape used here is the one the decoder expects:
/// `cachedUsageUtilization.utilization.limits`, snake_case keys, `resets_at` with six
/// fractional digits. Everything is optional because a schema change must not blank the
/// menu.
extension DeckTests {
    @Suite struct PlanLimitTests {
        init() throws { try Hermetic.reset() }

        private static func entry(
            kind: String?,
            percent: Double? = nil,
            severity: String? = nil,
            resetsAt: String? = nil,
            scope: String? = nil,
            active: Bool? = nil
        ) -> String {
            var fields: [String] = []
            if let kind { fields.append("\"kind\":\"\(kind)\"") }
            if let percent { fields.append("\"percent\":\(percent)") }
            if let severity { fields.append("\"severity\":\"\(severity)\"") }
            if let resetsAt { fields.append("\"resets_at\":\"\(resetsAt)\"") }
            if let scope { fields.append("\"scope\":{\"model\":{\"display_name\":\"\(scope)\"}}") }
            if let active { fields.append("\"is_active\":\(active)") }
            return "{" + fields.joined(separator: ",") + "}"
        }

        private static func config(fetchedAt: Date?, _ entries: [String]) -> String {
            let fetched = fetchedAt.map { "\"fetched_at_ms\":\(Hermetic.epochMilliseconds($0))," } ?? ""
            return "{\"cachedUsageUtilization\":{\(fetched)\"utilization\":{\"limits\":[\(entries.joined(separator: ","))]}}}"
        }

        private static func read() async throws -> UsageSnapshot {
            await UsageReader().snapshot()
        }

        // MARK: - Reading the cache

        @Test("reads each limit with its title, rounded percent and reset time")
        func readsLimits() async throws {
            let now = Date()
            let resets = now.addingTimeInterval(4 * 3600)
            try Hermetic.write(Self.config(fetchedAt: now, [
                Self.entry(kind: "session", percent: 24.4, severity: "normal", resetsAt: Hermetic.sixDigitISO(resets), active: true),
                Self.entry(kind: "weekly_all", percent: 82.6, severity: "warning", resetsAt: Hermetic.sixDigitISO(resets)),
                Self.entry(kind: "weekly_scoped", percent: 12, scope: "Fable"),
            ]), to: ".claude.json")

            let usage = try await Self.read()
            #expect(usage.limits.map(\.title) == ["Session", "Weekly", "Weekly · Fable"])
            #expect(usage.limits.map(\.percent) == [24, 83, 12])
            #expect(usage.limits.map(\.subtitle) == ["5 hour window", "7 day window", "7 day window"])
            #expect(usage.limits.map(\.id) == ["session", "weekly_all", "weekly_scoped-Fable"])
            #expect(usage.limits.map(\.isActive) == [true, false, false])
            #expect(usage.limits[0].severity == "normal")
            #expect(usage.limits[1].severity == "warning")

            let reset = try #require(usage.limits[0].resetsAt)
            #expect(abs(reset.timeIntervalSince(resets)) < 1)
            let fetched = try #require(usage.fetchedAt)
            #expect(abs(fetched.timeIntervalSince(now)) < 1)
        }

        @Test("the tightest limit is the one that decides the menu bar icon")
        func worstIsTheFullest() async throws {
            try Hermetic.write(Self.config(fetchedAt: Date(), [
                Self.entry(kind: "session", percent: 24),
                Self.entry(kind: "weekly_all", percent: 82),
                Self.entry(kind: "weekly_scoped", percent: 12, scope: "Fable"),
            ]), to: ".claude.json")

            let usage = try await Self.read()
            #expect(usage.worst?.id == "weekly_all")
        }

        @Test("a limit kind this build has never seen still gets a title")
        func unknownKindsAreTitled() async throws {
            try Hermetic.write(Self.config(fetchedAt: nil, [
                Self.entry(kind: "monthly_credits", percent: 5),
            ]), to: ".claude.json")

            let usage = try await Self.read()
            #expect(usage.limits.map(\.title) == ["Monthly Credits"])
            #expect(usage.limits.map(\.subtitle) == ["7 day window"])
            #expect(usage.fetchedAt == nil)
        }

        @Test("an entry with no kind is skipped and missing fields take their defaults")
        func toleratesMissingFields() async throws {
            try Hermetic.write(Self.config(fetchedAt: nil, [
                Self.entry(kind: nil, percent: 50),
                Self.entry(kind: "session"),
            ]), to: ".claude.json")

            let usage = try await Self.read()
            let limit = try #require(usage.limits.first)
            #expect(usage.limits.count == 1)
            #expect(limit.percent == 0)
            #expect(limit.severity == "normal")
            #expect(limit.group == "session")
            #expect(limit.resetsAt == nil)
            #expect(!limit.isActive)
        }

        @Test("a config with no usage cache yields no limits rather than an error")
        func noCacheNoLimits() async throws {
            try Hermetic.write(#"{"theme":"dark","numStartups":12}"#, to: ".claude.json")
            let usage = try await Self.read()
            #expect(usage.limits.isEmpty)
        }

        @Test("a missing config file yields an empty snapshot")
        func missingFile() async throws {
            let usage = try await Self.read()
            #expect(usage.limits.isEmpty)
            #expect(usage.fetchedAt == nil)
        }

        @Test("a half-written file keeps the previous reading instead of blanking the section")
        func keepsTheLastGoodReading() async throws {
            try Hermetic.write(Self.config(fetchedAt: Date(), [Self.entry(kind: "session", percent: 40)]), to: ".claude.json")
            let reader = UsageReader()
            let good = await reader.snapshot()
            #expect(good.limits.count == 1)

            // Claude Code rewrites the file in place, so a read can land mid-write.
            try Hermetic.write(#"{"cachedUsageUtilization":{"utilization":{"limits":[{"kind":"sess"#, to: ".claude.json")
            let during = await reader.snapshot()
            #expect(during == good)
        }

        // MARK: - Dates

        @Test("resets_at parses with six, three or no fractional digits")
        func parsesEveryFractionLength() async throws {
            let base = "2026-08-11T12:00:00"
            let whole = try #require(ISO8601DateFormatter().date(from: base + "Z"))
            let cases: [(text: String, fraction: Double)] = [
                (base + ".123456+00:00", 0.123456),
                (base + ".123+00:00", 0.123),
                (base + "Z", 0),
            ]
            for (text, fraction) in cases {
                try Hermetic.write(Self.config(fetchedAt: nil, [Self.entry(kind: "session", percent: 1, resetsAt: text)]), to: ".claude.json")
                let usage = await UsageReader().snapshot()
                let parsed = try #require(usage.limits.first?.resetsAt, "\(text) did not parse")
                #expect(abs(parsed.timeIntervalSince(whole) - fraction) < 0.01, "\(text)")
            }
        }

        @Test("an offset other than UTC is honoured")
        func honoursOffsets() async throws {
            let utc = try #require(ISO8601DateFormatter().date(from: "2026-08-11T10:00:00Z"))
            try Hermetic.write(
                Self.config(fetchedAt: nil, [Self.entry(kind: "session", percent: 1, resetsAt: "2026-08-11T12:00:00.250000+02:00")]),
                to: ".claude.json"
            )
            let usage = try await Self.read()
            let parsed = try #require(usage.limits.first?.resetsAt)
            #expect(abs(parsed.timeIntervalSince(utc) - 0.25) < 0.01)
        }

        // MARK: - Severity

        @Test("without an API severity the colour comes from 75 and 90 percent")
        func severityFromPercent() {
            #expect(Severity(percent: 0) == .normal)
            #expect(Severity(percent: 74) == .normal)
            #expect(Severity(percent: 75) == .warning)
            #expect(Severity(percent: 89) == .warning)
            #expect(Severity(percent: 90) == .critical)
            #expect(Severity(percent: 100) == .critical)
        }

        @Test("the API's own severity wins, because the thresholds are Anthropic's")
        func apiSeverityIsAuthoritative() {
            #expect(Severity(api: "critical", percent: 10) == .critical)
            #expect(Severity(api: "exceeded", percent: 10) == .critical)
            #expect(Severity(api: "warning", percent: 10) == .warning)
            #expect(Severity(api: "normal", percent: 99) == .normal)
            // A word this build has never heard falls back to the percentage.
            #expect(Severity(api: "elevated", percent: 80) == .warning)
        }
    }
}
