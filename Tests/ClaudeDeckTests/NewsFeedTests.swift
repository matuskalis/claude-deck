import Foundation
import Testing

@testable import ClaudeDeck

/// The News tab shows what a headless `claude -p` run wrote into a cache file. The run is
/// never exercised here (it spends plan usage), but everything after it is: pulling a JSON
/// array out of whatever prose the model wrapped it in, reading a cache written by an older
/// build, and choosing which of the three summaries to show.
extension DeckTests {
    @Suite struct NewsFeedTests {
        init() throws { try Hermetic.reset() }

        private static func item(title: String = "A headline", url: String = "https://example.com/post", balanced: String? = "balanced") -> NewsItem {
            NewsItem(
                title: title,
                source: "Example",
                url: url,
                published: "2026-08-06",
                plain: "plain",
                balanced: balanced,
                technical: "technical"
            )
        }

        // MARK: - Finding the array

        @Test("a bare array decodes")
        func bareArray() throws {
            let json = #"[{"title":"T","source":"S","url":"https://a.example/x","published":"2026-08-06","plain":"p","balanced":"b","technical":"t"}]"#
            let items = try #require(NewsStore.items(in: json))
            #expect(items.map(\.title) == ["T"])
        }

        @Test("prose and code fences around the array are ignored")
        func arrayInsideProse() throws {
            let wrapped = """
            Here is the list you asked for:

            ```json
            [{"title":"T","source":"S","url":"https://a.example/x","published":"2026-08-06","plain":"p","technical":"t"}]
            ```

            Let me know if you want more.
            """
            let items = try #require(NewsStore.items(in: wrapped))
            #expect(items.count == 1)
            #expect(items[0].balanced == nil)
        }

        @Test("text with no array, or an array that is not the list, gives nothing")
        func noUsableArray() {
            #expect(NewsStore.items(in: "I could not find anything.") == nil)
            #expect(NewsStore.items(in: "[1, 2, 3]") == nil)
            #expect(NewsStore.items(in: "] backwards [") == nil)
            #expect(NewsStore.items(in: #"[{"title":"missing the rest"}]"#) == nil)
        }

        // MARK: - The cache

        @Test("a cache round-trips, and the cost of the run comes back with it")
        func cacheRoundTrip() async throws {
            let feed = NewsFeed(generatedAt: Date(timeIntervalSince1970: 1_786_000_000), items: [Self.item()], costUSD: 0.88)
            EventsSpool.prepareDirectory()
            try JSONEncoder().encode(feed).write(to: NewsStore.url)

            let loaded = await NewsStore().load()
            #expect(loaded == feed)
        }

        @Test("a cache written before the middle depth existed still loads")
        func oldCacheLoads() async throws {
            let old = #"{"items":[{"title":"T","source":"S","url":"https://a.example/x","published":"2026-08-06","plain":"p","technical":"t"}]}"#
            try Hermetic.write(old, to: ".claude/claude-deck/news.json")

            let loaded = await NewsStore().load()
            #expect(loaded.items.count == 1)
            #expect(loaded.items[0].summary(depth: 1) == "p")
        }

        @Test("no cache, or a broken one, loads as an empty feed")
        func missingOrBrokenCache() async throws {
            #expect(await NewsStore().load().items.isEmpty)

            try Hermetic.write("{ broken", to: ".claude/claude-deck/news.json")
            #expect(await NewsStore().load().items.isEmpty)
        }

        // MARK: - Reading an item

        @Test("the detail slider picks a summary, and the middle one falls back to plain")
        func summaryDepth() {
            let full = Self.item(balanced: "balanced")
            #expect(full.summary(depth: 0) == "plain")
            #expect(full.summary(depth: 1) == "balanced")
            #expect(full.summary(depth: 2) == "technical")

            let old = Self.item(balanced: nil)
            #expect(old.summary(depth: 1) == "plain")
        }

        @Test("the publication date and host are read from the item")
        func dateAndHost() throws {
            let item = Self.item(url: "https://www.claude.com/blog/self-hosted")
            #expect(item.host == "claude.com")
            let date = try #require(item.date)
            #expect(Hermetic.day(date) == "2026-08-06")

            var unparsable = item
            unparsable.published = "last week"
            #expect(unparsable.date == nil)
        }

        @Test("an item is identified by its link")
        func identity() {
            #expect(Self.item(title: "one", url: "https://a.example/1").id == "https://a.example/1")
        }
    }
}
