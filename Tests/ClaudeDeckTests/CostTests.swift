import Foundation
import Testing

@testable import ClaudeDeck

/// The dollar figure in the Usage tab is arithmetic over four token counts and a price file
/// the user can edit. Each step of it is pinned here, because a wrong multiplier looks
/// exactly like a right one on screen.
extension DeckTests {
    @Suite struct CostTests {
        private static let opus = ModelPrice(input: 5, output: 25)

        private static func close(_ actual: Double, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
            abs(actual - expected) <= tolerance
        }

        // MARK: - Billing

        @Test("each kind of token is billed at its own rate")
        func billsEachKindSeparately() {
            let prices = Prices(models: ["claude-opus-5": Self.opus])
            func usd(_ tokens: TokenTotals) -> Double { prices.estimate(["claude-opus-5": tokens]).usd }

            #expect(Self.close(usd(TokenTotals(input: 1_000_000)), 5.00))
            #expect(Self.close(usd(TokenTotals(output: 1_000_000)), 25.00))
            // Writing the cache costs a quarter more than reading it fresh; reading it back is a tenth.
            #expect(Self.close(usd(TokenTotals(cacheCreation: 1_000_000)), 6.25))
            #expect(Self.close(usd(TokenTotals(cacheRead: 1_000_000)), 0.50))
            #expect(Self.close(
                usd(TokenTotals(input: 1_000_000, output: 1_000_000, cacheCreation: 1_000_000, cacheRead: 1_000_000)),
                36.75
            ))
        }

        @Test("the cache multipliers come from the price file, not from constants")
        func usesConfiguredMultipliers() {
            let prices = Prices(
                models: ["claude-opus-5": Self.opus],
                cacheReadMultiplier: 0.2,
                cacheWriteMultiplier: 2
            )
            let usd = prices.estimate(["claude-opus-5": TokenTotals(cacheCreation: 1_000_000, cacheRead: 1_000_000)]).usd
            #expect(Self.close(usd, 10.00 + 1.00))
        }

        @Test("a model with no price is left out of the total and counted as unpriced")
        func unpricedModelsAreReportedNotGuessed() {
            let prices = Prices(models: ["claude-opus-5": Self.opus])
            let estimate = prices.estimate([
                "claude-opus-5": TokenTotals(input: 1_000_000),
                "claude-mystery-9": TokenTotals(input: 9_000_000, output: 9_000_000),
            ])
            #expect(Self.close(estimate.usd, 5.00))
            #expect(estimate.unpricedModels == 1)
        }

        @Test("a model that used no tokens is neither priced nor reported")
        func idleModelsAreIgnored() {
            let prices = Prices(models: [:])
            let estimate = prices.estimate(["claude-mystery-9": TokenTotals()])
            #expect(estimate.usd == 0)
            #expect(estimate.unpricedModels == 0)
        }

        // MARK: - Model ids

        @Test("a dated id from the stats cache resolves to its family")
        func datedIdsResolveByPrefix() {
            let prices = Prices(models: ["claude-opus-4-5": Self.opus])
            #expect(prices.rate(for: "claude-opus-4-5-20251101") == Self.opus)
            #expect(prices.rate(for: "claude-opus-4-5") == Self.opus)
            #expect(prices.rate(for: "claude-sonnet-4-5") == nil)
        }

        @Test("the longest matching prefix wins")
        func longestPrefixWins() {
            let broad = ModelPrice(input: 15, output: 75)
            let prices = Prices(models: ["claude-opus-4": broad, "claude-opus-4-5": Self.opus])
            #expect(prices.rate(for: "claude-opus-4-5-20251101") == Self.opus)
            #expect(prices.rate(for: "claude-opus-4-1-20250805") == broad)
        }

        // MARK: - The price file

        @Test("the shipped defaults parse, and every model costs more to write than to read")
        func defaultsAreSane() throws {
            let prices = try #require(Prices(Data(Prices.defaultFile.utf8)))
            #expect(prices.models.count >= 5)
            #expect(prices.cacheReadMultiplier == 0.1)
            #expect(prices.cacheWriteMultiplier == 1.25)
            for (model, rate) in prices.models {
                #expect(rate.input > 0, "\(model) input")
                #expect(rate.output > rate.input, "\(model) output should cost more than input")
            }
        }

        @Test("missing multipliers fall back to the documented ones")
        func missingMultipliersDefault() throws {
            let file = #"{"models":{"claude-opus-5":{"input":5,"output":25}}}"#
            let prices = try #require(Prices(Data(file.utf8)))
            #expect(prices.cacheReadMultiplier == 0.1)
            #expect(prices.cacheWriteMultiplier == 1.25)
        }

        @Test("a model entry missing one of its rates is dropped, not priced at zero")
        func incompleteEntriesAreDropped() throws {
            let file = #"{"models":{"claude-opus-5":{"input":5,"output":25},"claude-half":{"input":3}}}"#
            let prices = try #require(Prices(Data(file.utf8)))
            #expect(prices.models.keys.sorted() == ["claude-opus-5"])
        }

        @Test("a file that is not JSON is rejected so the caller can fall back")
        func garbageIsRejected() {
            #expect(Prices(Data("not json".utf8)) == nil)
            #expect(Prices(Data("[1,2,3]".utf8)) == nil)
        }

        // MARK: - Burn rate

        private static func snapshot(spentOver hours: Double, totals: TokenTotals) -> StatsSnapshot {
            StatsSnapshot(
                today: ["claude-opus-5": totals],
                prices: Prices(models: ["claude-opus-5": opus]),
                todayStarted: Date().addingTimeInterval(-hours * 3600)
            )
        }

        @Test("the burn rate is today's estimate over the hours since the first message")
        func burnRateDividesByElapsedHours() throws {
            // 1M output tokens at $25 is $25, spent over two hours.
            let stats = Self.snapshot(spentOver: 2, totals: TokenTotals(output: 1_000_000))
            let rate = try #require(stats.burnRate)
            #expect(Self.close(rate, 12.5, tolerance: 0.05))
        }

        @Test("a day that has only just started does not report a four-figure rate")
        func burnRateHasAFloor() throws {
            // A minute in, the divisor is held at a quarter of an hour: $25 reads as $100/h, not $1500/h.
            let stats = Self.snapshot(spentOver: 1.0 / 60, totals: TokenTotals(output: 1_000_000))
            let rate = try #require(stats.burnRate)
            #expect(Self.close(rate, 100, tolerance: 0.5))
        }

        @Test("there is no burn rate before the first message or without a price")
        func burnRateNeedsSomethingToDivide() {
            var stats = Self.snapshot(spentOver: 2, totals: TokenTotals(output: 1_000_000))
            stats.todayStarted = nil
            #expect(stats.burnRate == nil)

            let unpriced = StatsSnapshot(
                today: ["claude-mystery-9": TokenTotals(output: 1_000_000)],
                prices: Prices(models: [:]),
                todayStarted: Date().addingTimeInterval(-7200)
            )
            #expect(unpriced.burnRate == nil)
        }

        @Test("totals add across models")
        func totalsSumAcrossModels() {
            let stats = StatsSnapshot(
                today: [
                    "a": TokenTotals(input: 1, output: 2, cacheCreation: 3, cacheRead: 4),
                    "b": TokenTotals(input: 10, output: 20, cacheCreation: 30, cacheRead: 40),
                ]
            )
            #expect(stats.todayTotals == TokenTotals(input: 11, output: 22, cacheCreation: 33, cacheRead: 44))
            #expect(stats.todayTotals.all == 110)
        }
    }
}
