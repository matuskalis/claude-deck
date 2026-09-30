import Foundation
import Testing

@testable import ClaudeDeck

/// The numbers in the menu are the product. These are the small functions that turn a count
/// of tokens, a length of time or a date stamp into the text next to a label.
@MainActor
struct FormattingTests {
    // MARK: - Tokens and money

    @Test("token counts shorten to k, M and B")
    func compactTokens() {
        #expect(StatsSection.compact(0) == "0")
        #expect(StatsSection.compact(999) == "999")
        #expect(StatsSection.compact(1_000) == "1k")
        #expect(StatsSection.compact(12_345) == "12k")
        #expect(StatsSection.compact(1_500_000) == "1.5M")
        #expect(StatsSection.compact(6_800_000_000) == "6.8B")
    }

    @Test("money shows cents under a hundred dollars and whole dollars above")
    func money() {
        #expect(StatsSection.money(0) == "$0.00")
        #expect(StatsSection.money(4.1) == "$4.10")
        #expect(StatsSection.money(99.4) == "$99.40")
        #expect(StatsSection.money(100) == "$100")
        #expect(StatsSection.money(1234.56) == "$1235")
    }

    @Test("a stored date reads as month and day, and an odd one is shown as it is")
    func shortDay() {
        #expect(StatsSection.shortDay("2026-08-03") == "Aug 3")
        #expect(StatsSection.shortDay("2026-12-25") == "Dec 25")
        #expect(StatsSection.shortDay("someday") == "someday")
        #expect(StatsSection.shortDay(nil) == "")
    }

    // MARK: - Durations

    @Test("durations read in seconds, then minutes and seconds, then hours and minutes")
    func duration() {
        #expect(SessionRow.duration(0) == "0s")
        #expect(SessionRow.duration(59) == "59s")
        #expect(SessionRow.duration(60) == "1m00s")
        #expect(SessionRow.duration(252) == "4m12s")
        #expect(SessionRow.duration(3599) == "59m59s")
        #expect(SessionRow.duration(3600) == "1h00m")
        #expect(SessionRow.duration(7260) == "2h01m")
    }

    @Test("a clock that ran backwards never shows a negative time")
    func negativeDuration() {
        #expect(SessionRow.duration(-30) == "0s")
    }
}
