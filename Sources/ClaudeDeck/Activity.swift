import Foundation

/// What the sessions are costing the machine.
struct ActivitySnapshot: Sendable, Equatable {
    /// Share of one core, summed across sessions. 250 means two and a half cores busy.
    var cpuPercent: Double = 0
    var residentBytes: Int = 0
    var processes: Int = 0
    /// Busiest session, by the same measure.
    var busiest: (name: String, cpuPercent: Double)?
    /// Size of ~/.claude — mostly transcripts, and it grows without anyone deciding to.
    var claudeBytes: Int = 0
    var freeBytes: Int = 0

    static func == (lhs: ActivitySnapshot, rhs: ActivitySnapshot) -> Bool {
        lhs.cpuPercent == rhs.cpuPercent
            && lhs.residentBytes == rhs.residentBytes
            && lhs.processes == rhs.processes
            && lhs.busiest?.name == rhs.busiest?.name
            && lhs.busiest?.cpuPercent == rhs.busiest?.cpuPercent
            && lhs.claudeBytes == rhs.claudeBytes
            && lhs.freeBytes == rhs.freeBytes
    }
}

/// Samples CPU, memory and disk for the running sessions.
///
/// **`ps -o %cpu` is not usable here.** It reports CPU averaged over the whole life of the
/// process, so a session that has been open for a fortnight reads 0.1% while it is pinning
/// a core. Real CPU comes from the cumulative CPU time in `ps -o time`, differenced against
/// the previous sample — which is why this has to hold state between calls.
///
/// Energy and per-process network are deliberately absent: `top -stats power` costs about
/// 1.5 seconds per sample and reports 0.0 without a sampling window, and `nettop` costs 5
/// seconds and returns nothing useful without privileges this app has no business holding.
actor ActivityReader {
    private struct Sample {
        var cpuSeconds: Double
        var at: Date
    }

    private var previous: [Int32: Sample] = [:]
    private var diskBytes = 0
    private var diskCheckedAt = Date.distantPast

    func sample(sessions: [(pid: Int32, name: String)]) -> ActivitySnapshot {
        var snapshot = ActivitySnapshot()
        snapshot.freeBytes = Self.freeBytes()
        snapshot.claudeBytes = diskSize()

        guard !sessions.isEmpty else {
            previous = [:]
            return snapshot
        }

        let now = Date()
        let measured = Self.measure(pids: sessions.map(\.pid))
        var current: [Int32: Sample] = [:]
        var busiest: (name: String, cpuPercent: Double)?

        for session in sessions {
            guard let row = measured[session.pid] else { continue }
            snapshot.residentBytes += row.residentBytes
            snapshot.processes += 1
            current[session.pid] = Sample(cpuSeconds: row.cpuSeconds, at: now)

            guard let last = previous[session.pid] else { continue }
            let elapsed = now.timeIntervalSince(last.at)
            guard elapsed > 0.5 else { continue }
            // A restarted pid can report less CPU than last time; clamp rather than
            // report a negative load.
            let used = max(0, row.cpuSeconds - last.cpuSeconds)
            let percent = used / elapsed * 100
            snapshot.cpuPercent += percent
            if percent > (busiest?.cpuPercent ?? 0) {
                busiest = (session.name, percent)
            }
        }

        previous = current
        snapshot.busiest = busiest.map { ($0.name, $0.cpuPercent) }
        return snapshot
    }

    /// ~/.claude is a gigabyte of transcripts on a well-used machine, and `du` walks it in
    /// about a tenth of a second — cheap, but not every fifteen seconds.
    private func diskSize() -> Int {
        if Date().timeIntervalSince(diskCheckedAt) < 300, diskBytes > 0 { return diskBytes }
        diskCheckedAt = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude").path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return diskBytes }

        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        if let kilobytes = Int(text.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "") {
            diskBytes = kilobytes * 1024
        }
        return diskBytes
    }

    private static func freeBytes() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private static func measure(pids: [Int32]) -> [Int32: (cpuSeconds: Double, residentBytes: Int)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,rss=,time=", "-p", pids.map(String.init).joined(separator: ",")]
        process.environment = ["PATH": "/bin:/usr/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }

        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        var found: [Int32: (cpuSeconds: Double, residentBytes: Int)] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let kilobytes = Int(fields[1]) else { continue }
            found[pid] = (Self.seconds(String(fields[2])), kilobytes * 1024)
        }
        return found
    }

    /// `ps` prints cumulative CPU as `mm:ss.ss`, growing to `hh:mm:ss` and `dd-hh:mm:ss`.
    static func seconds(_ text: String) -> Double {
        var rest = text
        var total = 0.0
        if let dash = rest.firstIndex(of: "-") {
            total += (Double(rest[..<dash]) ?? 0) * 86_400
            rest = String(rest[rest.index(after: dash)...])
        }
        for part in rest.split(separator: ":") {
            total = total * 60 + (Double(part) ?? 0)
        }
        return total
    }
}
