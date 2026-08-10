import Foundation

/// Liveness check for session files, which are not reliably cleaned up when a
/// session dies. `kill(pid, 0)` alone is not enough because PIDs get reused, so
/// the process start time is compared against the `procStart` recorded in the file.
///
/// Claude Code writes `procStart` in UTC using ctime formatting
/// ("Tue Jul 28 00:39:41 2026"), which is exactly what `ps -o lstart=` prints when
/// it runs with TZ=UTC.
enum ProcessCheck {
    static func alive(_ candidates: [(pid: Int32, procStart: String?)]) -> Set<Int32> {
        let signalled = candidates.filter { respondsToSignal($0.pid) }
        guard !signalled.isEmpty else { return [] }

        let startTimes = processStartTimes(pids: signalled.map(\.pid))
        var alive: Set<Int32> = []
        for candidate in signalled {
            guard let expected = candidate.procStart, !expected.isEmpty else {
                alive.insert(candidate.pid)
                continue
            }
            if let actual = startTimes[candidate.pid], actual == normalized(expected) {
                alive.insert(candidate.pid)
            }
        }
        return alive
    }

    private static func respondsToSignal(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func processStartTimes(pids: [Int32]) -> [Int32: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,lstart=", "-p", pids.map(String.init).joined(separator: ",")]
        process.environment = ["TZ": "UTC", "PATH": "/bin:/usr/bin"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var result: [Int32: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
            result[pid] = normalized(String(fields[1]))
        }
        return result
    }

    /// ctime pads single-digit days with an extra space; collapse runs of blanks so
    /// the two formatters agree.
    private static func normalized(_ value: String) -> String {
        value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
