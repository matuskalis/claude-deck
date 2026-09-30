import Foundation
import Testing

@testable import ClaudeDeck

/// Background jobs have no terminal window, so the job directory is the only place to see
/// that one is stuck on a question. The rules for what counts as blocked, what is worth
/// showing and what order it goes in are the whole feature.
extension DeckTests {
    @Suite struct BackgroundJobTests {
        init() throws { try Hermetic.reset() }

        private static func iso(_ date: Date, fraction: Bool = true) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = fraction ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            return formatter.string(from: date)
        }

        /// Writes `.claude/jobs/<id>/state.json`, touched `minutesAgo` minutes ago unless told otherwise.
        @discardableResult
        private static func job(
            _ id: String,
            minutesAgo: Double? = 1,
            _ fields: [String: Any] = [:]
        ) throws -> URL {
            var state = fields
            if let minutesAgo { state["updatedAt"] = iso(Date().addingTimeInterval(-minutesAgo * 60)) }
            let data = try JSONSerialization.data(withJSONObject: state)
            return try Hermetic.write(String(decoding: data, as: UTF8.self), to: ".claude/jobs/\(id)/state.json")
        }

        private static func snapshot() async -> [Job] {
            await JobsReader().snapshot()
        }

        // MARK: - Blocked

        @Test("blocked means state, tempo or a pending question, whatever the state says")
        func blockedHasThreeSignals() async throws {
            try Self.job("a", ["name": "by-state", "state": "blocked"])
            try Self.job("b", ["name": "by-tempo", "state": "working", "tempo": "blocked"])
            try Self.job("c", [
                "name": "by-question",
                "state": "working",
                "block": ["questions": [["question": "Which branch?", "options": [["label": "main"], ["label": "dev"]]]]],
            ])
            try Self.job("d", ["name": "fine", "state": "working", "tempo": "steady"])

            let jobs = await Self.snapshot()
            let blocked = Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, $0.isBlocked) })
            #expect(blocked == ["by-state": true, "by-tempo": true, "by-question": true, "fine": false])
        }

        @Test("a pending question is printed verbatim, with its options, ahead of the prose")
        func questionBeatsNeeds() async throws {
            try Self.job("a", [
                "state": "blocked",
                "needs": "Waiting for input",
                "block": ["questions": [["question": "Migrate 43 rows, skip them, or flag them?", "options": [["label": "Migrate"], ["label": "Skip"], ["label": "Flag"]]]]],
            ])

            let job = try #require(await Self.snapshot().first)
            #expect(job.waitingOn == "Migrate 43 rows, skip them, or flag them?")
            #expect(job.options == ["Migrate", "Skip", "Flag"])
        }

        @Test("without a structured question the prose description stands in")
        func needsIsTheFallback() async throws {
            try Self.job("a", ["state": "blocked", "needs": "Waiting for a review"])

            let job = try #require(await Self.snapshot().first)
            #expect(job.waitingOn == "Waiting for a review")
            #expect(job.question == nil)
        }

        // MARK: - What is worth showing

        @Test("finished jobs, day-old jobs and jobs with no timestamp are dropped")
        func dropsWhatIsNotLive() async throws {
            try Self.job("done", ["name": "done", "state": "done"])
            try Self.job("stale", minutesAgo: 25 * 60, ["name": "stale", "state": "working"])
            try Self.job("undated", minutesAgo: nil, ["name": "undated", "state": "working"])
            try Self.job("live", minutesAgo: 23 * 60, ["name": "live", "state": "working"])

            let names = await Self.snapshot().map(\.name)
            #expect(names == ["live"])
        }

        @Test("blocked jobs come first, then the most recently moved")
        func ordering() async throws {
            try Self.job("old-blocked", minutesAgo: 300, ["name": "old-blocked", "state": "blocked"])
            try Self.job("fresh", minutesAgo: 1, ["name": "fresh", "state": "working"])
            try Self.job("older", minutesAgo: 60, ["name": "older", "state": "working"])
            try Self.job("new-blocked", minutesAgo: 2, ["name": "new-blocked", "state": "blocked"])

            let names = await Self.snapshot().map(\.name)
            #expect(names == ["new-blocked", "old-blocked", "fresh", "older"])
        }

        @Test("a directory that is not a job, or a state file that is not JSON, is skipped")
        func skipsBrokenDirectories() async throws {
            try Hermetic.write("{ broken", to: ".claude/jobs/broken/state.json")
            try Hermetic.write("hello", to: ".claude/jobs/no-state/notes.txt")
            try Self.job("good", ["name": "good", "state": "working"])

            let names = await Self.snapshot().map(\.name)
            #expect(names == ["good"])
        }

        // MARK: - Fields

        @Test("the name falls back to the session id, then to the directory")
        func nameFallbacks() async throws {
            try Self.job("dir-only", ["state": "working"])
            try Self.job("has-session", ["state": "working", "sessionId": "0123456789abcdef"])

            let names = Set(await Self.snapshot().map(\.name))
            #expect(names == ["dir-only", "01234567"])
        }

        @Test("fan-out, in-flight counts, tokens and start times are read")
        func readsFanOut() async throws {
            let started = Date().addingTimeInterval(-120)
            try Self.job("a", [
                "name": "fanned",
                "state": "working",
                "tokens": 1_900_000,
                "inFlight": ["tasks": 2, "queued": 3],
                "fan": [
                    ["id": "t1", "kind": "shell", "label": "npm test", "startedAt": started.timeIntervalSince1970 * 1000],
                    ["id": "t2", "label": "review the diff"],
                    ["kind": "shell", "label": "no id, so it is dropped"],
                ],
            ])

            let job = try #require(await Self.snapshot().first)
            #expect(job.tokens == 1_900_000)
            #expect(job.inFlight == 2)
            #expect(job.queued == 3)
            #expect(job.fan.map(\.id) == ["t1", "t2"])
            #expect(job.fan.map(\.kind) == ["shell", "task"])
            #expect(job.fan[0].label == "npm test")
            let begun = try #require(job.fan[0].startedAt)
            #expect(abs(begun.timeIntervalSince(started)) < 1)
            #expect(job.fan[1].startedAt == nil)
        }

        @Test("timestamps parse with or without fractional seconds")
        func datesBothWays() async throws {
            let moment = Date().addingTimeInterval(-300)
            try Self.job("frac", minutesAgo: nil, ["name": "frac", "state": "working", "updatedAt": Self.iso(moment)])
            try Self.job("whole", minutesAgo: nil, ["name": "whole", "state": "working", "updatedAt": Self.iso(moment, fraction: false)])

            let jobs = await Self.snapshot()
            #expect(jobs.count == 2)
            for job in jobs {
                let updated = try #require(job.updatedAt)
                #expect(abs(updated.timeIntervalSince(moment)) < 1.5)
            }
        }

        @Test("a path under home is shown with a tilde")
        func shortPath() async throws {
            try Self.job("a", ["name": "a", "state": "working", "cwd": NSHomeDirectory() + "/projects/harbor-api"])
            try Self.job("b", ["name": "b", "state": "working", "cwd": "/srv/elsewhere"])

            let paths = Dictionary(uniqueKeysWithValues: await Self.snapshot().map { ($0.name, $0.shortPath) })
            #expect(paths == ["a": "~/projects/harbor-api", "b": "/srv/elsewhere"])
        }

        @Test("a changed state file is picked up on the next read")
        func rereadsChangedState() async throws {
            let reader = JobsReader()
            try Self.job("a", ["name": "a", "state": "working"])
            #expect(await reader.snapshot().first?.isBlocked == false)

            try Self.job("a", ["name": "a", "state": "blocked", "needs": "a decision"])
            #expect(await reader.snapshot().first?.isBlocked == true)
        }

        // MARK: - Timeline

        private static func timeline(_ count: Int, padding: Int = 0) -> String {
            (1...count).map { number in
                let note = "note \(number)" + String(repeating: "x", count: padding)
                return "{\"at\":\"\(iso(Date().addingTimeInterval(Double(number - count) * 60)))\",\"state\":\"working\",\"detail\":\"\(note)\"}"
            }.joined(separator: "\n") + "\n"
        }

        @Test("the last three timeline notes are kept, oldest of them first")
        func keepsTheLastThree() async throws {
            try Self.job("a", ["name": "a", "state": "working"])
            try Hermetic.write(Self.timeline(6), to: ".claude/jobs/a/timeline.jsonl")

            let job = try #require(await Self.snapshot().first)
            #expect(job.timeline.compactMap(\.detail) == ["note 4", "note 5", "note 6"])
        }

        @Test("a long-running job's timeline is read from its end, and the cut line is ignored")
        func readsALargeTimelineFromTheEnd() async throws {
            try Self.job("a", ["name": "a", "state": "working"])
            // About 300 KB: far more than the 96 KB read from the end, so the window opens mid-line.
            try Hermetic.write(Self.timeline(300, padding: 1000), to: ".claude/jobs/a/timeline.jsonl")

            let job = try #require(await Self.snapshot().first)
            let notes = job.timeline.compactMap(\.detail).map { String($0.prefix(8)) }
            #expect(notes == ["note 298", "note 299", "note 300"])
        }
    }
}
