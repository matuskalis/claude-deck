import SwiftUI

struct StatsSection: View {
    let stats: StatsSnapshot
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Today").fontWeight(.medium)
                Spacer(minLength: 4)
                Text(todaySummary).monospacedDigit()
            }

            HStack(spacing: 6) {
                Text("Lifetime").fontWeight(.medium)
                Spacer(minLength: 4)
                Text("\(stats.lifetimeSessions) sessions · \(Self.compact(stats.lifetimeTotals.all)) tok")
                    .monospacedDigit()
                Text(asOf)
                    .foregroundStyle(.tertiary)
            }

            if stats.recentDays.count > 1 {
                VStack(alignment: .leading, spacing: 1) {
                    Sparkline(values: stats.recentDays.map(\.tokens), color: Severity.normal.color)
                        .frame(height: 20)
                    HStack {
                        Text(Self.shortDay(stats.recentDays.first?.date))
                        Spacer()
                        Text("last \(stats.recentDays.count) days")
                        Spacer()
                        Text(Self.shortDay(stats.recentDays.last?.date))
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                }
                .padding(.top, 2)
            }

            if unpricedToday > 0 {
                Text("\(unpricedToday) model\(unpricedToday == 1 ? "" : "s") unpriced — edit prices.json")
                    .foregroundStyle(.tertiary)
            }

            DisclosureGroup(isExpanded: $showingDetail) {
                // The longest thing in the app: four token rows, a row per model, five
                // projects, seven days and three paragraphs of caveat. It gets a scrollbar
                // of its own so the page around it stays the size it was.
                ScrollView {
                    detail
                }
                .frame(maxHeight: 210)
            } label: {
                Text(showingDetail ? "Hide breakdown" : "Show breakdown")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10))
            .padding(.top, 1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 2) {
            let today = stats.todayTotals
            Text("Today, live from transcripts, one count per request")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            row("in", today.input)
            row("out", today.output)
            row("cache write", today.cacheCreation)
            row("cache read", today.cacheRead)
            ForEach(stats.today.keys.sorted(), id: \.self) { model in
                row(model, stats.today[model]?.all ?? 0)
            }

            if !stats.todayByProject.isEmpty {
                Text("Today by project")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(topProjects, id: \.name) { project in
                    row(project.name, project.tokens)
                }
            }

            Text(stats.lifetimeIncludesLive
                 ? "Lifetime per model, Claude Code's counter \(asOfDate) plus transcripts since"
                 : "Lifetime per model, Claude Code's own counter \(asOf)")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(stats.lifetime.keys.sorted(), id: \.self) { model in
                row(model, stats.lifetime[model]?.all ?? 0)
            }

            if !stats.recentDays.isEmpty {
                Text("Recent days, input + output only, no cache, as of \(asOfDate)")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(stats.recentDays, id: \.date) { day in
                    row(day.date, day.tokens)
                }
            }

            Text("Lifetime and recent days come from Claude Code, which counts every content block, so they are not on the same basis as today; the days added on top of the cache are counted once per request, like today. Cost is an estimate from ~/.claude/claude-deck/prices.json, not a bill.")
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10))
    }

    private func row(_ label: String, _ tokens: Int) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(Self.compact(tokens)).monospacedDigit()
        }
    }

    private var todaySummary: String {
        let estimate = stats.prices.estimate(stats.today)
        let sessions = "\(stats.todaySessions) session\(stats.todaySessions == 1 ? "" : "s")"
        var summary = "\(sessions) · \(Self.compact(stats.todayTotals.all)) tok · ~\(Self.money(estimate.usd)) est"
        if let burn = stats.burnRate { summary += " · \(Self.money(burn))/h" }
        return summary
    }

    private var topProjects: [(name: String, tokens: Int)] {
        stats.todayByProject
            .map { (name: $0.key, tokens: $0.value.all) }
            .sorted { $0.tokens > $1.tokens }
            .prefix(5)
            .map { $0 }
    }

    private var unpricedToday: Int {
        stats.prices.estimate(stats.today).unpricedModels
    }

    private var asOf: String {
        guard !asOfDate.isEmpty else { return "" }
        return stats.lifetimeIncludesLive ? "\(asOfDate) + live" : "as of \(asOfDate)"
    }

    private var asOfDate: String {
        Self.shortDay(stats.lifetimeAsOf)
    }

    /// `2026-08-03` as it is stored, `Aug 3` as it is read.
    static func shortDay(_ date: String?) -> String {
        guard let date else { return "" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let parsed = parser.date(from: date) else { return date }
        let display = DateFormatter()
        display.locale = Locale(identifier: "en_US_POSIX")
        display.dateFormat = "MMM d"
        return display.string(from: parsed)
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...: String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }

    static func money(_ usd: Double) -> String {
        usd >= 100 ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
    }
}
