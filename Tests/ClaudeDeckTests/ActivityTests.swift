import Darwin
import Foundation
import Testing

@testable import ClaudeDeck

/// The Machine row claims to agree with Activity Monitor. The two traps that made it
/// disagree, mach ticks read as nanoseconds and resident size read as footprint, are
/// checked here against the clock and against the kernel.
extension DeckTests {
    @Suite struct ActivityTests {
        init() throws { try Hermetic.reset() }

        @Test("CPU time is converted from mach ticks, not treated as nanoseconds")
        func machTicksConvertToSeconds() {
            // One interval measured twice: in the ticks the kernel reports CPU time in, and by the
            // wall clock. Read as nanoseconds on Apple silicon the ticks would come out about 40
            // times too small, and converted twice about 40 times too large. Comparing the two
            // measurements keeps the test honest on a machine that is too busy to sleep on time.
            let wallStart = Date()
            let start = mach_absolute_time()
            usleep(100_000)
            let ticks = mach_absolute_time() - start
            let wall = Date().timeIntervalSince(wallStart)

            let seconds = ActivityReader.seconds(machTicks: ticks)
            #expect(abs(seconds - wall) <= max(0.05, wall * 0.25), "ticks said \(seconds) s, the clock said \(wall) s")
        }

        @Test("no ticks is no time, and the conversion is linear")
        func conversionIsLinear() {
            #expect(ActivityReader.seconds(machTicks: 0) == 0)
            let one = ActivityReader.seconds(machTicks: 1_000_000)
            let ten = ActivityReader.seconds(machTicks: 10_000_000)
            #expect(abs(ten - 10 * one) < 1e-9)
        }

        @Test("a live process is measured by its physical footprint, and a gone one is skipped")
        func measuresTheFootprint() async throws {
            let reader = ActivityReader()
            let snapshot = await reader.sample(sessions: [
                (pid: getpid(), name: "this test process"),
                (pid: 2_000_000, name: "no such process"),
            ])

            #expect(snapshot.processes == 1)
            // A running Swift process has a footprint of at least a few megabytes, far from zero.
            #expect(snapshot.residentBytes > 1_000_000, "footprint was \(snapshot.residentBytes) bytes")
            // The first sample has nothing to difference against.
            #expect(snapshot.cpuPercent == 0)
        }

        /// CPU seconds this process has used so far, by the kernel's own accounting.
        private static func cpuSecondsUsed() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1e6 }
            return seconds(usage.ru_utime) + seconds(usage.ru_stime)
        }

        @Test("CPU is the change since the last sample, and agrees with the kernel's own accounting")
        func cpuIsDifferenced() async throws {
            let reader = ActivityReader()
            let me = [(pid: getpid(), name: "busy")]
            _ = await reader.sample(sessions: me)
            let startedCPU = Self.cpuSecondsUsed()
            let started = Date()

            // Burn CPU for longer than the half second the reader needs between samples. How much of
            // it this process is actually given depends on what else the machine is doing, so the
            // expectation is taken from `getrusage` over the same window rather than assumed.
            let deadline = started.addingTimeInterval(0.7)
            var sink = 0
            while Date() < deadline { sink &+= 1 }
            #expect(sink != 0)

            let snapshot = await reader.sample(sessions: me)
            let expected = (Self.cpuSecondsUsed() - startedCPU) / Date().timeIntervalSince(started) * 100

            #expect(snapshot.cpuPercent > 0)
            #expect(abs(snapshot.cpuPercent - expected) <= max(10, expected * 0.3),
                    "reported \(snapshot.cpuPercent)%, getrusage says \(expected)%")
            #expect(snapshot.busiest?.name == "busy")
        }

        @Test("with no sessions the machine row still reports the disk")
        func diskWithoutSessions() async throws {
            try Hermetic.write(String(repeating: "x", count: 200_000), to: ".claude/projects/p/s.jsonl")
            let snapshot = await ActivityReader().sample(sessions: [])

            #expect(snapshot.processes == 0)
            #expect(snapshot.freeBytes > 0)
            #expect(snapshot.claudeBytes >= 200_000)
        }

        @Test("CPU reads with a decimal under 10 percent and whole above")
        func cpuFormatting() async {
            await MainActor.run {
                #expect(ActivitySection.cpu(0) == "0.0%")
                #expect(ActivitySection.cpu(9.94) == "9.9%")
                #expect(ActivitySection.cpu(10) == "10%")
                #expect(ActivitySection.cpu(104.6) == "105%")
            }
        }

        @Test("sizes read in the largest unit that keeps them above one")
        func byteFormatting() async {
            await MainActor.run {
                #expect(ActivitySection.bytes(512) == "512 B")
                #expect(ActivitySection.bytes(2048) == "2 KB")
                #expect(ActivitySection.bytes(5 * 1_048_576) == "5 MB")
                #expect(ActivitySection.bytes(1_610_612_736) == "1.5 GB")
            }
        }
    }
}
