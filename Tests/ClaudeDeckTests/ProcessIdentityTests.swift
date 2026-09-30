import Darwin
import Foundation
import Testing

@testable import ClaudeDeck

/// A session file outlives its process and a pid outlives its owner, so "is this session
/// alive" is a signal check plus a match of the recorded start time. "Quit all" signals
/// whatever this says is alive, which makes a false positive the expensive mistake.
extension DeckTests {
    @Suite struct ProcessIdentityTests {
        init() throws { try Hermetic.reset() }

        /// The start time of a process the way Claude Code records it: `ps` in UTC.
        private static func startTime(of pid: Int32) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-o", "lstart=", "-p", "\(pid)"]
            process.environment = ["TZ": "UTC", "PATH": "/bin:/usr/bin"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static var me: Int32 { getpid() }

        @Test("a live pid with the start time on record is alive")
        func matchingStartTimeIsAlive() throws {
            let recorded = try Self.startTime(of: Self.me)
            #expect(!recorded.isEmpty)
            #expect(ProcessCheck.alive([(pid: Self.me, procStart: recorded)]) == [Self.me])
        }

        @Test("a live pid with a different start time is a reused pid, and is not alive")
        func reusedPidIsNotAlive() {
            let recorded = "Mon Jan  1 00:00:00 2001"
            #expect(ProcessCheck.alive([(pid: Self.me, procStart: recorded)]).isEmpty)
        }

        @Test("padding in the recorded start time does not matter")
        func whitespaceIsNormalised() throws {
            let recorded = try Self.startTime(of: Self.me)
            // ctime pads a single-digit day with an extra space, and other writers may pad more.
            let padded = "  " + recorded.replacingOccurrences(of: " ", with: "   ")
            #expect(ProcessCheck.alive([(pid: Self.me, procStart: padded)]) == [Self.me])
        }

        @Test("a session file with no recorded start time is checked by signal alone")
        func missingStartTimeFallsBackToTheSignal() {
            #expect(ProcessCheck.alive([(pid: Self.me, procStart: nil)]) == [Self.me])
            #expect(ProcessCheck.alive([(pid: Self.me, procStart: "")]) == [Self.me])
        }

        @Test("a pid that has exited is not alive")
        func exitedPidIsNotAlive() throws {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try child.run()
            child.waitUntilExit()
            #expect(ProcessCheck.alive([(pid: child.processIdentifier, procStart: nil)]).isEmpty)
        }

        @Test("zero and negative pids are never alive, since kill would signal a whole group")
        func nonPositivePids() {
            #expect(ProcessCheck.alive([(pid: 0, procStart: nil), (pid: -1, procStart: nil)]).isEmpty)
        }

        @Test("a process owned by someone else still counts as responding")
        func permissionDeniedStillMeansAlive() {
            // launchd is always running and is not ours, so this is EPERM rather than success.
            #expect(ProcessCheck.alive([(pid: 1, procStart: nil)]) == [1])
        }

        @Test("a mixed list comes back with only the live, correctly identified ones")
        func mixedList() throws {
            let recorded = try Self.startTime(of: Self.me)
            let alive = ProcessCheck.alive([
                (pid: Self.me, procStart: recorded),
                (pid: 2_000_000, procStart: recorded),
                (pid: 1, procStart: "Mon Jan  1 00:00:00 2001"),
            ])
            #expect(alive == [Self.me])
        }
    }
}
