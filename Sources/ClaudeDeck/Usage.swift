import Foundation

/// One plan limit as Claude Code last saw it: the rolling session window, the weekly
/// all-model window, and a weekly window scoped to one model.
struct UsageLimit: Sendable, Equatable, Identifiable {
    var kind: String
    var group: String
    var percent: Int
    var severity: String
    var resetsAt: Date?
    var scope: String?
    var isActive: Bool

    var id: String { scope.map { "\(kind)-\($0)" } ?? kind }

    var title: String {
        switch kind {
        case "session": "Session"
        case "weekly_all": "Weekly"
        case "weekly_scoped": scope.map { "Weekly · \($0)" } ?? "Weekly · scoped"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var subtitle: String {
        switch kind {
        case "session": "5 hour window"
        default: "7 day window"
        }
    }
}

struct UsageSnapshot: Sendable, Equatable {
    var limits: [UsageLimit] = []
    var fetchedAt: Date?
    /// When each limit is on course to reach 100%, keyed by `UsageLimit.id`. Only present
    /// for limits that would get there before they reset.
    var forecast: [String: Date] = [:]

    /// The limit that decides the menu bar icon: whatever is closest to its ceiling.
    var worst: UsageLimit? { limits.max { $0.percent < $1.percent } }
}

/// Reads `cachedUsageUtilization` out of `~/.claude.json`.
///
/// Claude Code fetches the real numbers from its usage endpoint and caches them here, so
/// this is the only local copy of your plan limits — but it is only as fresh as the last
/// fetch, which is why `fetchedAt` is surfaced and shown in the menu.
actor UsageReader {
    private static let configURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude.json")

    private static var historyURL: URL { EventsSpool.directory.appending(path: "usage-history.jsonl") }
    /// Enough for a couple of weeks of samples at one every fetch.
    private static let maxSamples = 400

    private var stamp = ""
    private var cached = UsageSnapshot()
    private var samples: [Sample] = []
    private var loadedHistory = false

    func snapshot() -> UsageSnapshot {
        var info = stat()
        guard stat(Self.configURL.path, &info) == 0 else { return cached }
        let current = "\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        guard current != stamp else { return cached }

        // Claude Code rewrites this file in place while we may be reading it, so a failed
        // decode keeps the previous snapshot instead of blanking the section.
        guard let data = try? Data(contentsOf: Self.configURL) else { return cached }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let file = try? decoder.decode(ConfigFile.self, from: data) else { return cached }

        stamp = current
        loadHistory()
        let cache = file.cachedUsageUtilization
        cached = UsageSnapshot(
            limits: (cache?.utilization?.limits ?? []).compactMap { entry in
                guard let kind = entry.kind else { return nil }
                return UsageLimit(
                    kind: kind,
                    group: entry.group ?? kind,
                    percent: Int((entry.percent ?? 0).rounded()),
                    severity: entry.severity ?? "normal",
                    resetsAt: Self.date(entry.resetsAt),
                    scope: entry.scope?.model?.displayName,
                    isActive: entry.isActive ?? false
                )
            },
            fetchedAt: cache?.fetchedAtMs.map { Date(epochMilliseconds: $0) }
        )
        record(cached)
        cached.forecast = forecasts(for: cached.limits)
        return cached
    }

    // MARK: - Forecast

    /// The limits are percentages with no token denominator behind them, so the only rate
    /// that can be measured is percent per hour, and the only way to measure it is to watch
    /// them move. Samples are kept in the app's own directory.
    private struct Sample: Codable, Sendable {
        var at: Double
        var kind: String
        var percent: Int
    }

    private func loadHistory() {
        guard !loadedHistory else { return }
        loadedHistory = true
        guard let data = try? Data(contentsOf: Self.historyURL) else { return }
        let decoder = JSONDecoder()
        samples = data
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(Sample.self, from: Data($0)) }
            .suffix(Self.maxSamples)
    }

    private func record(_ snapshot: UsageSnapshot) {
        guard let at = snapshot.fetchedAt else { return }
        let stamp = at.timeIntervalSince1970
        // One sample per fetch: the file changes far more often than the figures in it do.
        guard !samples.contains(where: { $0.at == stamp }) else { return }

        samples.append(contentsOf: snapshot.limits.map {
            Sample(at: stamp, kind: $0.id, percent: $0.percent)
        })
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }

        let encoder = JSONEncoder()
        let lines = samples.compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        try? FileManager.default.createDirectory(at: EventsSpool.directory, withIntermediateDirectories: true)
        try? Data((lines + "\n").utf8).write(to: Self.historyURL, options: .atomic)
    }

    private func forecasts(for limits: [UsageLimit]) -> [String: Date] {
        var found: [String: Date] = [:]
        let now = Date()

        for limit in limits {
            // Sorted first: the reset test below reads a fall in percentage as a new window,
            // and a sample landing out of file order would read as one.
            let ordered = samples.filter { $0.kind == limit.id }.sorted { $0.at < $1.at }

            // Only samples since the last reset count. Averaging across a reset boundary
            // would halve every rate.
            var window: [Sample] = []
            for sample in ordered {
                if let last = window.last, sample.percent < last.percent { window = [] }
                window.append(sample)
            }

            guard window.count >= 3,
                  let first = window.first, let last = window.last,
                  case let hours = (last.at - first.at) / 3600, hours >= 1,
                  case let rate = Double(last.percent - first.percent) / hours, rate > 0,
                  limit.percent < 100 else { continue }

            let reaches = now.addingTimeInterval((100 - Double(limit.percent)) / rate * 3600)
            // A limit that resets before it fills is not news.
            guard let resets = limit.resetsAt, reaches < resets else { continue }
            found[limit.id] = reaches
        }
        return found
    }

    /// `resets_at` carries six fractional digits, which `ISO8601DateFormatter` rejects, so
    /// the fraction is cut to the three it accepts before parsing.
    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }

        if let dot = text.firstIndex(of: ".") {
            let rest = text[text.index(after: dot)...]
            let digits = rest.prefix { $0.isNumber }
            let trimmed = text[..<dot] + "." + digits.prefix(3) + rest.dropFirst(digits.count)
            if let parsed = formatter.date(from: String(trimmed)) { return parsed }

            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: String(text[..<dot] + rest.dropFirst(digits.count)))
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

private struct ConfigFile: Decodable {
    struct Cached: Decodable {
        var fetchedAtMs: Double?
        var utilization: Utilization?
    }
    struct Utilization: Decodable {
        var limits: [Entry]?
    }
    struct Entry: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { var displayName: String? }
            var model: Model?
        }
        var kind: String?
        var group: String?
        var percent: Double?
        var severity: String?
        var resetsAt: String?
        var scope: Scope?
        var isActive: Bool?
    }
    var cachedUsageUtilization: Cached?
}
