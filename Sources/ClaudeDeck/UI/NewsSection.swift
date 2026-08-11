import SwiftUI

/// Ecosystem news, summarised by the Claude Code on this machine and cached, with the two
/// controls that decide how it reads: how technical, and how far back.
struct NewsSection: View {
    let feed: NewsFeed
    let refreshing: Bool
    let error: String?
    /// The tightest plan limit, so the button can say what it will cost you.
    let worstLimit: UsageLimit?
    let refresh: () -> Void

    @AppStorage("news.detail") private var detail = 0.0
    @AppStorage("news.age") private var age = 30.0

    private static let detailNames = ["Plain", "Balanced", "Technical"]

    private var depth: Int { Int(detail.rounded()) }
    private var days: Int { max(1, Int(age.rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            content
        }
    }

    private var controls: some View {
        VStack(spacing: 7) {
            StopSlider(
                title: "Detail",
                value: $detail,
                range: 0...2,
                caption: Self.detailNames[min(depth, 2)]
            )
            // Continuous rather than stepped: the cache holds ninety days of dated items,
            // so any cut-off in that span is a real one and none of them costs a fetch.
            StopSlider(
                title: "How far back",
                value: $age,
                range: 1...90,
                caption: days == 1 ? "24 hours" : "\(days) days"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        let shown = visible

        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Severity.critical.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if feed.items.isEmpty, !refreshing, error == nil {
                    Text("Nothing fetched yet. Refresh asks the Claude Code on this machine to read the vendors' own release notes and blogs, and caches what it finds.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if shown.isEmpty, !feed.items.isEmpty {
                    Text("Nothing in the last \(days) day\(days == 1 ? "" : "s"). \(feed.items.count) item\(feed.items.count == 1 ? "" : "s") cached over 90 days.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(shown) { item in
                    article(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 380)

        Divider()
        footer
    }

    private func article(_ item: NewsItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Link(destination: URL(string: item.url) ?? URL(fileURLWithPath: "/")) {
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)

            HStack(spacing: 5) {
                Text(item.host)
                Text("·")
                Text(item.published)
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .monospacedDigit()

            Text(item.summary(depth: depth))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if refreshing {
                    Text("Reading… this takes a minute or two")
                        .foregroundStyle(.secondary)
                } else if let generated = feed.generatedAt {
                    Text("as of \(generated.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.tertiary)
                } else {
                    Text("never fetched")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if let cost = feed.costUSD, cost > 0 {
                    Text(String(format: "last cost $%.2f", cost))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Button(refreshing ? "Reading…" : "Refresh") { refresh() }
                    .controlSize(.small)
                    .disabled(refreshing || blocked)
            }
            .font(.system(size: 10))

            // The rest of this app exists to show how close the plan limits are; a button
            // that spends them has to say so rather than quietly draw them down.
            Text(note)
                .font(.system(size: 9))
                .foregroundStyle(blocked ? AnyShapeStyle(Severity.critical.color) : AnyShapeStyle(.tertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var blocked: Bool {
        guard let worstLimit else { return false }
        return Severity(api: worstLimit.severity, percent: worstLimit.percent) == .critical
    }

    private var note: String {
        if let worstLimit, blocked {
            return "\(worstLimit.title) is at \(worstLimit.percent)%. Refresh is held back until it resets, rather than spending what is left of it on a news panel."
        }
        return "Refresh runs a separate headless Claude Code session on this machine and spends your plan usage. Summaries are written by a model from the pages it fetched; open the link to check anything that matters."
    }

    private var visible: [NewsItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return feed.items
            .filter { ($0.date ?? .distantPast) >= cutoff }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
