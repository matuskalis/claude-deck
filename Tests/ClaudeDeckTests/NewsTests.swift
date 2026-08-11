import Foundation
import Testing

@testable import ClaudeDeck

/// The News tab is only as good as the prompt it sends, and the prompt is assembled from a
/// file the user owns. Both halves of that are worth pinning down.
@Suite(.serialized)
struct NewsTests {
    private static func inSandbox(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "claude-deck-news-\(UUID().uuidString)")
        let previous = EventsSpool.directory
        EventsSpool.directory = root
        defer {
            EventsSpool.directory = previous
            try? FileManager.default.removeItem(at: root)
        }
        try await body(root)
    }

    @Test("writes a topics file on first use, and it names people as well as tools")
    func writesDefaults() async throws {
        try await Self.inSandbox { _ in
            let topics = await NewsStore().topics()

            #expect(FileManager.default.fileExists(atPath: NewsStore.topicsURL.path))
            #expect(topics.contains("Boris Cherny"))
            #expect(topics.contains("Anthropic and Claude Code"))
            // Comments and blank lines are guidance for the reader, not for the model.
            #expect(!topics.contains("#"))
            #expect(!topics.contains("\n\n"))
        }
    }

    @Test("an edited topics file is used as written, and never overwritten")
    func respectsEdits() async throws {
        try await Self.inSandbox { _ in
            EventsSpool.prepareDirectory()
            let mine = "# mine\n\nAda Lovelace\n\n  Grace Hopper  \n"
            try Data(mine.utf8).write(to: NewsStore.topicsURL)

            let topics = await NewsStore().topics()
            #expect(topics == "Ada Lovelace\nGrace Hopper")

            let onDisk = try String(contentsOf: NewsStore.topicsURL, encoding: .utf8)
            #expect(onDisk == mine)
        }
    }

    @Test("an emptied topics file does not produce a promptless prompt")
    func survivesAnEmptyFile() async throws {
        try await Self.inSandbox { _ in
            EventsSpool.prepareDirectory()
            try Data("# everything commented out\n".utf8).write(to: NewsStore.topicsURL)

            let topics = await NewsStore().topics()
            #expect(!topics.isEmpty)
        }
    }

    @Test("the prompt carries the topics and keeps its source rules")
    func promptComposition() {
        let prompt = NewsStore.prompt(topics: "Boris Cherny\nCursor")

        #expect(prompt.contains("Boris Cherny"))
        #expect(prompt.contains("Cursor"))
        // A named person's own words are allowed; reporting about them is not.
        #expect(prompt.contains("their blog, their talk, their repository, their post"))
        #expect(prompt.contains("No aggregators"))
        // The schema the decoder expects has to survive edits to the prose around it.
        for key in ["title", "source", "url", "published", "plain", "balanced", "technical"] {
            #expect(prompt.contains("\"\(key)\""))
        }
    }
}
