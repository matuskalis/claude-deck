import SwiftUI

/// Ecosystem news, summarised by the Claude Code on this machine and cached.
///
/// Master and detail: headlines above, the selected one written out below. A fixed panel
/// cannot scroll, and eight items at three sentences each was never going to fit.
struct NewsSection: View {
    let feed: NewsFeed
    let refreshing: Bool
    let error: String?
    /// The tightest plan limit, so the button can say what it will cost you.
    let worstLimit: UsageLimit?
    let refresh: () -> Void

    @AppStorage("news.detail") private var detail = 0.0
    @AppStorage("news.age") private var age = 30.0
    @State private var selected: String?

    private static let detailNames = ["Plain", "Balanced", "Technical"]
    private static let visibleItems = 6

    private var depth: Int { Int(detail.rounded()) }
    private var days: Int { max(1, Int(age.rounded())) }
    private var current: NewsItem? { visible.first { $0.id == selected } ?? visible.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()

            if let error {
                message(error, Severity.critical.color)
            } else if feed.items.isEmpty {
                message("Nothing fetched yet. Refresh asks the Claude Code on this machine to read the vendors' own release notes and blogs, and caches what it finds.", nil)
            } else if visible.isEmpty {
                message("Nothing in the last \(days) day\(days == 1 ? "" : "s"). \(feed.items.count) item\(feed.items.count == 1 ? "" : "s") cached over 90 days.", nil)
            } else {
                headlines
                Divider()
                article
            }

            Spacer(minLength: 0)
            Divider()
            footer
        }
    }

    private func message(_ text: String, _ color: Color?) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private var controls: some View {
        VStack(spacing: 7) {
            StopSlider(
                title: "Detail",
                value: $detail,
                range: 0...2,
                caption: Self.detailNames[min(depth, 2)]
            )
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

    private var headlines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visible.prefix(Self.visibleItems)) { item in
                let isCurrent = item.id == current?.id
                Button {
                    selected = item.id
                } label: {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(item.published)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isCurrent ? Color.primary.opacity(0.07) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if visible.count > Self.visibleItems {
                Text("+\(visible.count - Self.visibleItems) older — narrow the range")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var article: some View {
        if let item = current {
            VStack(alignment: .leading, spacing: 3) {
                Link(destination: URL(string: item.url) ?? URL(fileURLWithPath: "/")) {
                    HStack(spacing: 4) {
                        Text(item.host)
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)

                Text(item.summary(depth: depth))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
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
                .lineLimit(2)
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
            return "\(worstLimit.title) is at \(worstLimit.percent)%. Refresh is held back until it resets."
        }
        return "Refresh runs a headless Claude Code session here and spends your plan usage. Summaries are a model's reading of the pages it fetched; open the link to check anything that matters."
    }

    private var visible: [NewsItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return feed.items
            .filter { ($0.date ?? .distantPast) >= cutoff }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
