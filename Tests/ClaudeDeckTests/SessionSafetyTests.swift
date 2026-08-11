import Foundation
import Testing

@testable import ClaudeDeck

/// Dormant is the set that "Quit all" sends SIGTERM to, so what falls into it is a safety
/// question, not a display one.
struct SessionSafetyTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func session(
        status: String?,
        idleHoursAgo: Double?,
        state: SessionState = .idle,
        procStart: String? = "Mon Aug 11 10:00:00 2026"
    ) -> Session {
        Session(
            id: "id",
            pid: 1234,
            procStart: procStart,
            name: "session",
            cwd: "/tmp",
            state: state,
            rawStatus: status,
            contextWindow: 200_000,
            idleSince: idleHoursAgo.map { now.addingTimeInterval(-$0 * 3600) }
        )
    }

    @Test("a long-idle session is dormant")
    func idleIsDormant() {
        #expect(Self.session(status: "idle", idleHoursAgo: 13).isDormant(now: Self.now))
    }

    @Test("recently idle is not dormant")
    func recentIsNotDormant() {
        #expect(!Self.session(status: "idle", idleHoursAgo: 11).isDormant(now: Self.now))
    }

    @Test("a session file with no status is never dormant, however old")
    func missingStatusIsNotDormant() {
        #expect(!Self.session(status: nil, idleHoursAgo: 500).isDormant(now: Self.now))
    }

    @Test("a status this build does not recognise is never dormant")
    func unknownStatusIsNotDormant() {
        // The failure this guards against: a future Claude Code writing, say, "compacting"
        // decodes as not-busy, and "not busy" must not imply "safe to terminate".
        #expect(!Self.session(status: "compacting", idleHoursAgo: 500).isDormant(now: Self.now))
        #expect(!Self.session(status: "waiting_input", idleHoursAgo: 500).isDormant(now: Self.now))
    }

    @Test("a busy session is never dormant")
    func busyIsNotDormant() {
        let busy = Self.session(status: "busy", idleHoursAgo: 500, state: .busy(since: Self.now))
        #expect(!busy.isDormant(now: Self.now))
    }

    @Test("a session waiting on a permission prompt is never dormant")
    func waitingIsNotDormant() {
        let waiting = Self.session(
            status: "idle",
            idleHoursAgo: 500,
            state: .waitingPermission(message: "Bash approval")
        )
        #expect(!waiting.isDormant(now: Self.now))
    }

    @Test("a failed session is never dormant")
    func failedIsNotDormant() {
        let failed = Self.session(status: "idle", idleHoursAgo: 500, state: .failed(message: "rate limited"))
        #expect(!failed.isDormant(now: Self.now))
    }

    @Test("a stale session is one that is idle while holding most of its context")
    func staleNeedsBothIdleAndContext() {
        var full = Self.session(status: "idle", idleHoursAgo: 1)
        full.usage = TranscriptUsage(model: "claude-opus-5", contextUsed: 150_000)
        #expect(full.isStale(now: Self.now))

        var empty = Self.session(status: "idle", idleHoursAgo: 1)
        empty.usage = TranscriptUsage(model: "claude-opus-5", contextUsed: 20_000)
        #expect(!empty.isStale(now: Self.now))

        var busy = Self.session(status: "busy", idleHoursAgo: nil, state: .busy(since: Self.now))
        busy.usage = TranscriptUsage(model: "claude-opus-5", contextUsed: 150_000)
        #expect(!busy.isStale(now: Self.now))
    }
}
