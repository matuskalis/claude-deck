import Foundation

struct TokenTotals: Sendable, Equatable {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0

    var all: Int { input + output + cacheCreation + cacheRead }

    static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }
}

struct ModelPrice: Sendable, Equatable {
    var input: Double
    var output: Double
}

/// USD per million tokens. Cache tokens are not billed at the input rate, hence the
/// multipliers.
struct Prices: Sendable, Equatable {
    var models: [String: ModelPrice] = [:]
    var cacheReadMultiplier = 0.1
    var cacheWriteMultiplier = 1.25

    /// Transcript ids (`claude-opus-4-8`) and stats-cache ids
    /// (`claude-opus-4-5-20251101`) both resolve by longest matching prefix.
    func rate(for model: String) -> ModelPrice? {
        models.keys
            .filter { model.hasPrefix($0) }
            .max { $0.count < $1.count }
            .flatMap { models[$0] }
    }

    func estimate(_ totals: [String: TokenTotals]) -> (usd: Double, unpricedModels: Int) {
        var usd = 0.0
        var unpriced = 0
        for (model, tokens) in totals where tokens.all > 0 {
            guard let rate = rate(for: model) else {
                unpriced += 1
                continue
            }
            usd += (Double(tokens.input) * rate.input
                + Double(tokens.output) * rate.output
                + Double(tokens.cacheCreation) * rate.input * cacheWriteMultiplier
                + Double(tokens.cacheRead) * rate.input * cacheReadMultiplier) / 1_000_000
        }
        return (usd, unpriced)
    }
}

struct DayTokens: Sendable, Equatable {
    var date: String
    var tokens: Int
}

struct StatsSnapshot: Sendable, Equatable {
    var today: [String: TokenTotals] = [:]
    var todaySessions = 0
    var lifetime: [String: TokenTotals] = [:]
    var lifetimeSessions = 0
    var lifetimeAsOf: String?
    /// True once transcripts have contributed the days `stats-cache.json` is missing.
    var lifetimeIncludesLive = false
    var recentDays: [DayTokens] = []
    var prices = Prices()
    /// First assistant message of the local day, which is what the burn rate divides by.
    var todayStarted: Date?

    var todayTotals: TokenTotals { today.values.reduce(TokenTotals(), +) }
    var lifetimeTotals: TokenTotals { lifetime.values.reduce(TokenTotals(), +) }

    /// USD per hour since the day's first message. The floor stops a single request in the
    /// last minute from reporting a four-figure rate.
    var burnRate: Double? {
        guard let todayStarted else { return nil }
        let hours = max(0.25, Date().timeIntervalSince(todayStarted) / 3600)
        let usd = prices.estimate(today).usd
        return usd > 0 ? usd / hours : nil
    }
}

/// Two sources: Claude Code's own `stats-cache.json`, which is only recomputed when its
/// stats screen is opened, and a live tail of transcripts. The tail starts the day after
/// the cache was computed, so one scan both feeds today and tops the cache up to now.
actor StatsReader {
    static let pricesURL = EventsSpool.directory.appending(path: "prices.json")

    private static let chunkSize = 256 * 1024
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    private static let projectsDirectory = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/projects")
    private static let statsCacheURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/stats-cache.json")

    /// One entry per assistant message, not per line: Claude Code writes a line per
    /// content block and repeats the identical `usage` on each, so summing lines
    /// overcounts a day by roughly 2x.
    private struct MessageUsage {
        var model: String
        var timestamp: String
        var totals: TokenTotals
    }

    /// UTC stamp the scan starts at, and the thing that invalidates it: it moves only when
    /// Claude Code recomputes its cache, or, with no cache to read, at midnight.
    private var window = ""
    private var offsets: [String: Int] = [:]
    /// Kept per file so that a rewritten file can drop its old contribution, then folded
    /// into one entry per message id, because a forked session repeats another
    /// transcript's messages verbatim.
    private var perFile: [String: [String: MessageUsage]] = [:]

    private var prices = Prices.fallback
    private var pricesStamp = ""

    private var cacheLifetime: [String: TokenTotals] = [:]
    private var lifetimeSessions = 0
    private var lifetimeAsOf: String?
    private var recentDays: [DayTokens] = []
    private var lifetimeStamp = ""

    func snapshot(sessionIdsStartedToday: Set<String>, promptedToday: Set<String>) -> StatsSnapshot {
        loadPrices()
        loadLifetime()
        tailTranscripts()

        var requests: [String: MessageUsage] = [:]
        for messages in perFile.values {
            requests.merge(messages) { existing, _ in existing }
        }
        let startOfToday = Self.utcStamp(Calendar.current.startOfDay(for: Date()))
        var today: [String: TokenTotals] = [:]
        var live: [String: TokenTotals] = [:]
        var firstToday: String?
        for request in requests.values {
            live[request.model] = (live[request.model] ?? TokenTotals()) + request.totals
            guard request.timestamp >= startOfToday else { continue }
            today[request.model] = (today[request.model] ?? TokenTotals()) + request.totals
            if firstToday == nil || request.timestamp < firstToday! { firstToday = request.timestamp }
        }

        // With no cache to build on, transcripts alone are not a lifetime — old ones get
        // deleted — so the row stays empty rather than quietly reporting a few days as one.
        var lifetime = cacheLifetime
        let toppedUp = lifetimeAsOf != nil && !live.isEmpty
        if toppedUp {
            for (model, totals) in live {
                lifetime[model] = (lifetime[model] ?? TokenTotals()) + totals
            }
        }

        return StatsSnapshot(
            today: today,
            todaySessions: sessionIdsStartedToday.union(promptedToday).count,
            lifetime: lifetime,
            lifetimeSessions: lifetimeSessions,
            lifetimeAsOf: lifetimeAsOf,
            lifetimeIncludesLive: toppedUp,
            recentDays: recentDays,
            prices: prices,
            todayStarted: firstToday.flatMap(Self.parse)
        )
    }

    private static func parse(_ stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.date(from: stamp)
    }

    // MARK: - Live tail of transcripts

    private func tailTranscripts() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let start = min(Self.dayAfter(lifetimeAsOf) ?? startOfDay, startOfDay)
        let boundary = Self.utcStamp(start)
        if boundary != window {
            window = boundary
            offsets = [:]
            perFile = [:]
        }

        for url in Self.transcripts(modifiedSince: start) {
            guard let size = url.currentFileSize else { continue }
            var offset = offsets[url.path] ?? 0
            if offset > size {
                offset = 0
                perFile[url.path] = nil
            }
            guard size > offset else { continue }

            let (found, consumed) = Self.scan(url: url, from: offset, to: size, since: boundary)
            offsets[url.path] = consumed
            // Later lines of a message carry a larger running `output_tokens`, and the
            // last one is the finished request, so a repeat replaces what came before.
            perFile[url.path, default: [:]].merge(found) { _, latest in latest }
        }
    }

    private static func transcripts(modifiedSince date: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: projectsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let modified = url.currentModified, modified >= date else { continue }
            found.append(url)
        }
        return found
    }

    /// Streams complete lines and reports how many bytes were consumed, so a line that is
    /// still being written is read again next time instead of being dropped.
    ///
    /// Reads with `pread` into one reused buffer: `FileHandle.read(upToCount:)` grows the
    /// process footprint by roughly the number of bytes read and never gives it back,
    /// which costs tens of megabytes on a day's worth of transcripts.
    private static func scan(url: URL, from offset: Int, to size: Int, since boundary: String) -> (found: [String: MessageUsage], consumed: Int) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return ([:], offset) }
        defer { close(descriptor) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var found: [String: MessageUsage] = [:]
        var consumed = offset
        var position = offset
        var carry: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: chunkSize)

        while position < size {
            let want = min(chunkSize, size - position)
            let got = scratch.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, want, off_t(position)) }
            guard got > 0 else { break }
            position += got

            var lineStart = 0
            for index in 0..<got where scratch[index] == UInt8(ascii: "\n") {
                let line = carry.isEmpty ? Array(scratch[lineStart..<index]) : carry + scratch[lineStart..<index]
                carry = []
                let lineOffset = consumed
                consumed += line.count + 1
                if let entry = usage(in: line, since: boundary, decoder: decoder) {
                    // Lines without a message id cannot be deduplicated, so they are keyed
                    // by where they sit in the file and each one counts once.
                    found[entry.id ?? "\(url.path)#\(lineOffset)"] = entry.usage
                }
                lineStart = index + 1
            }
            if lineStart < got { carry.append(contentsOf: scratch[lineStart..<got]) }
        }
        return (found, consumed)
    }

    private static func usage(in line: [UInt8], since boundary: String, decoder: JSONDecoder) -> (id: String?, usage: MessageUsage)? {
        let data = Data(line)
        guard data.range(of: assistantMarker) != nil,
              let entry = try? decoder.decode(AssistantLine.self, from: data),
              entry.type == "assistant",
              let timestamp = entry.timestamp, timestamp >= boundary,
              let usage = entry.message?.usage else { return nil }

        return (entry.message?.id, MessageUsage(
            model: entry.message?.model ?? "unknown",
            timestamp: timestamp,
            totals: TokenTotals(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheCreation: usage.cacheCreationInputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0
            )
        ))
    }

    // MARK: - stats-cache.json

    private func loadLifetime() {
        let stamp = Self.stamp(of: Self.statsCacheURL)
        guard stamp != lifetimeStamp, !stamp.isEmpty else { return }
        lifetimeStamp = stamp

        guard let data = try? Data(contentsOf: Self.statsCacheURL),
              let file = try? JSONDecoder().decode(StatsCacheFile.self, from: data) else { return }

        lifetimeSessions = file.totalSessions ?? 0
        lifetimeAsOf = file.lastComputedDate
        cacheLifetime = (file.modelUsage ?? [:]).mapValues {
            TokenTotals(
                input: $0.inputTokens ?? 0,
                output: $0.outputTokens ?? 0,
                cacheCreation: $0.cacheCreationInputTokens ?? 0,
                cacheRead: $0.cacheReadInputTokens ?? 0
            )
        }
        recentDays = (file.dailyModelTokens ?? [])
            .suffix(7)
            .compactMap { day in
                guard let date = day.date else { return nil }
                return DayTokens(date: date, tokens: (day.tokensByModel ?? [:]).values.reduce(0, +))
            }
    }

    // MARK: - prices.json

    private func loadPrices() {
        if Self.pricesURL.currentFileSize == nil {
            try? FileManager.default.createDirectory(at: EventsSpool.directory, withIntermediateDirectories: true)
            try? Data(Prices.defaultFile.utf8).write(to: Self.pricesURL, options: .atomic)
        }

        let stamp = Self.stamp(of: Self.pricesURL)
        guard stamp != pricesStamp else { return }
        pricesStamp = stamp

        guard let data = try? Data(contentsOf: Self.pricesURL), let parsed = Prices(data) else {
            prices = .fallback
            return
        }
        prices = parsed
    }

    private static func stamp(of url: URL) -> String {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return "" }
        return "\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
    }

    /// `lastComputedDate` is the last day the cache covers, so the transcript top-up has to
    /// start at the one after it.
    private static func dayAfter(_ date: String?) -> Date? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: date) else { return nil }
        return Calendar.current.date(byAdding: .day, value: 1, to: parsed)
    }

    /// Transcript timestamps are fixed-width UTC, so the start of the local day can be
    /// compared as a string instead of parsing a date out of every line.
    private static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}

extension Prices {
    static let defaultFile = """
    {
      "note": "Anthropic first-party API list prices in USD per million tokens. A Max or Pro subscription is not billed per token, so this is a usage-equivalent estimate and not a bill. Cache reads and cache writes are billed as multiples of the input rate.",
      "cacheReadMultiplier": 0.1,
      "cacheWriteMultiplier": 1.25,
      "models": {
        "claude-fable-5": { "input": 10.00, "output": 50.00 },
        "claude-mythos-5": { "input": 10.00, "output": 50.00 },
        "claude-opus-5": { "input": 5.00, "output": 25.00 },
        "claude-opus-4-8": { "input": 5.00, "output": 25.00 },
        "claude-opus-4-7": { "input": 5.00, "output": 25.00 },
        "claude-opus-4-6": { "input": 5.00, "output": 25.00 },
        "claude-opus-4-5": { "input": 5.00, "output": 25.00 },
        "claude-sonnet-5": { "input": 3.00, "output": 15.00 },
        "claude-sonnet-4-6": { "input": 3.00, "output": 15.00 },
        "claude-sonnet-4-5": { "input": 3.00, "output": 15.00 },
        "claude-haiku-4-5": { "input": 1.00, "output": 5.00 }
      }
    }

    """

    static let fallback = Prices(Data(defaultFile.utf8)) ?? Prices()

    init?(_ data: Data) {
        guard let file = try? JSONDecoder().decode(PricesFile.self, from: data) else { return nil }
        self.init(
            models: (file.models ?? [:]).compactMapValues { rate in
                guard let input = rate.input, let output = rate.output else { return nil }
                return ModelPrice(input: input, output: output)
            },
            cacheReadMultiplier: file.cacheReadMultiplier ?? 0.1,
            cacheWriteMultiplier: file.cacheWriteMultiplier ?? 1.25
        )
    }
}

private struct StatsCacheFile: Decodable {
    struct ModelUsage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreationInputTokens: Int?
    }
    struct DailyModelTokens: Decodable {
        var date: String?
        var tokensByModel: [String: Int]?
    }
    var lastComputedDate: String?
    var totalSessions: Int?
    var modelUsage: [String: ModelUsage]?
    var dailyModelTokens: [DailyModelTokens]?
}

private struct PricesFile: Decodable {
    struct Rate: Decodable {
        var input: Double?
        var output: Double?
    }
    var models: [String: Rate]?
    var cacheReadMultiplier: Double?
    var cacheWriteMultiplier: Double?
}
