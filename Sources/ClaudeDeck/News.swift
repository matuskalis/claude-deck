import Foundation

struct NewsItem: Identifiable, Codable, Sendable, Equatable {
    var title: String
    var source: String
    var url: String
    var published: String
    var plain: String
    /// Optional because a cache written before the middle depth existed still has to load.
    var balanced: String?
    var technical: String

    var id: String { url }

    /// 0 plain, 1 balanced, 2 technical. Falls back rather than showing an empty panel.
    func summary(depth: Int) -> String {
        switch depth {
        case 0: plain
        case 1: balanced ?? plain
        default: technical
        }
    }

    var date: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: published)
    }

    var host: String {
        URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? source
    }
}

struct NewsFeed: Codable, Sendable, Equatable {
    var generatedAt: Date?
    var items: [NewsItem] = []
    /// What the last refresh cost, reported by Claude Code itself, so the price of the
    /// button is never a mystery.
    var costUSD: Double?
}

/// The one place this app reaches beyond the disk — and it does so by asking the Claude
/// Code already installed and logged in on this machine, rather than holding a key of its
/// own.
///
/// Consequences worth being explicit about, because they are the whole design:
///
/// - **No credential ever belongs to Claude Deck.** It runs the `claude` binary the user
///   already trusts, in a separate headless session.
/// - **It spends the user's plan budget**, which the rest of this app exists to display.
///   So it never runs on a timer, only when asked, and it refuses when a limit is already
///   in its critical band.
/// - **It does not speak into any existing session.** A fresh `claude -p` is its own
///   conversation; the boundary in the README still holds.
/// - **The result is a model summary of pages it fetched**, not a feed from a publisher.
///   Every item carries its primary-source URL so the claim can be checked.
actor NewsStore {
    static var url: URL { EventsSpool.directory.appending(path: "news.json") }

    private static let candidates = [
        ".local/bin/claude",
        ".claude/local/claude",
    ]
    private static let systemCandidates = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    /// A GUI app inherits no useful PATH, so the binary is found by looking rather than by
    /// asking the shell.
    static func executable() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let paths = candidates.map { home.appending(path: $0).path } + systemCandidates
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static let prompt = """
    Find recent, verifiable news about AI coding assistants and the models behind them: \
    Anthropic and Claude Code, OpenAI and Codex, Google and Gemini CLI, Cursor, GitHub Copilot.

    Use official primary sources only: vendor blogs, engineering posts, changelogs, release \
    notes, model cards, research papers. No aggregators, no speculation, no rumour posts.

    Only items published in the last 90 days. If you cannot establish both a publication \
    date and a working URL for an item, leave it out entirely.

    Output STRICTLY a JSON array, no prose, no code fences. Each element:
    {
      "title": "short factual headline, max 80 chars",
      "source": "organisation name",
      "url": "direct link to the primary source",
      "published": "YYYY-MM-DD",
      "plain": "2 sentences, no jargon at all, what it means for someone who writes code daily",
      "balanced": "2-3 sentences for a working developer: name the feature, the model and the practical consequence, but no benchmark tables",
      "technical": "3-4 sentences, precise, include version numbers, model names, benchmarks, limits or API details where they exist"
    }

    Return at most 8 items, newest first. Nothing else.
    """

    func load() -> NewsFeed {
        guard let data = try? Data(contentsOf: Self.url),
              let feed = try? JSONDecoder().decode(NewsFeed.self, from: data) else { return NewsFeed() }
        return feed
    }

    enum RefreshError: LocalizedError {
        case noClaude
        case failed(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noClaude: "Could not find the claude command. Claude Deck asks the Claude Code on this machine to do the reading; without it there is nothing to ask."
            case .failed(let message): message
            case .unreadable: "Claude Code replied, but not with the list that was asked for."
            }
        }
    }

    func refresh(generatedAt: Date) throws -> NewsFeed {
        guard let executable = Self.executable() else { throw RefreshError.noClaude }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-p", Self.prompt,
            "--output-format", "json",
            "--model", "claude-sonnet-5",
            "--allowed-tools", "WebSearch", "WebFetch",
            // A measured run takes 20 turns and about 90 cents. The cap is a backstop
            // against a search loop quietly spending a great deal more than that.
            "--max-turns", "30",
        ]
        // A GUI app's environment is nearly empty, and the CLI needs at least these.
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(executable.deletingLastPathComponent().path)",
        ]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw RefreshError.failed(error.localizedDescription)
        }

        // Reading to EOF blocks until the process exits, so the deadline has to be enforced
        // by something else. A measured run is around two and a half minutes.
        DispatchQueue.global().asyncAfter(deadline: .now() + 420) {
            if process.isRunning { process.terminate() }
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RefreshError.failed(problem.isEmpty ? "claude exited with status \(process.terminationStatus)" : problem)
        }

        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        guard let text = envelope?.result, let items = Self.items(in: text) else { throw RefreshError.unreadable }

        let feed = NewsFeed(generatedAt: generatedAt, items: items, costUSD: envelope?.totalCostUsd)
        EventsSpool.prepareDirectory()
        if let encoded = try? JSONEncoder().encode(feed) {
            try? encoded.write(to: Self.url, options: .atomic)
            EventsSpool.restrict(Self.url)
        }
        return feed
    }

    /// Models add prose or fences around JSON however firmly they are told not to, so the
    /// array is taken from the first bracket to the last rather than assumed to be alone.
    private static func items(in text: String) -> [NewsItem]? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return nil }
        let slice = String(text[start...end])
        return try? JSONDecoder().decode([NewsItem].self, from: Data(slice.utf8))
    }
}

private struct Envelope: Decodable {
    var result: String?
    var totalCostUsd: Double?

    enum CodingKeys: String, CodingKey {
        case result
        case totalCostUsd = "total_cost_usd"
    }
}
