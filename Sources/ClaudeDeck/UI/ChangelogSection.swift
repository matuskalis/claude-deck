import SwiftUI

/// What changed in the tool you are using, from the changelog Claude Code already keeps on
/// disk.
///
/// Master and detail rather than one long list, because a fixed panel cannot scroll and 360
/// releases will never fit in one: the top picks a release, the bottom shows it.
struct ChangelogSection: View {
    let releases: [Release]
    let installedVersion: String?

    @AppStorage("changelog.detail") private var detail = 0.0
    @AppStorage("changelog.position") private var position = 0.0
    @State private var selected: String?

    private static let detailNames = ["Highlights", "Notable", "Everything"]
    private static let visibleReleases = 7
    private static let visibleEntries = 7

    private var tier: Int { Int(detail.rounded()) }
    private var start: Int { max(0, min(Int(position.rounded()), max(0, releases.count - Self.visibleReleases))) }
    private var page: [Release] { Array(releases.dropFirst(start).prefix(Self.visibleReleases)) }
    private var current: Release? { page.first { $0.version == selected } ?? page.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()

            if releases.isEmpty {
                Text("No changelog cached yet. Claude Code writes one to ~/.claude/cache/changelog.md.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                list
                Divider()
                entries
            }
            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        VStack(spacing: 7) {
            StopSlider(
                title: "Detail",
                value: $detail,
                range: 0...2,
                caption: Self.detailNames[min(tier, 2)]
            )
            StopSlider(
                title: "How far back",
                value: $position,
                range: 0...Double(max(1, releases.count - Self.visibleReleases)),
                caption: page.last.map { "to \($0.version)" } ?? ""
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(page) { release in
                let isCurrent = release.version == current?.version
                Button {
                    selected = release.version
                } label: {
                    HStack(spacing: 6) {
                        Text(release.version)
                            .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                            .monospacedDigit()
                        if release.version == installedVersion {
                            Text("yours")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Severity.normal.color)
                        }
                        Spacer(minLength: 4)
                        Text("\(release.shown(upTo: tier).count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if release.hiddenCount(upTo: tier) > 0 {
                            Text("+\(release.hiddenCount(upTo: tier))")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isCurrent ? Color.primary.opacity(0.07) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }

    private var entries: some View {
        let release = current
        let shown = release.map { Array($0.shown(upTo: tier).prefix(Self.visibleEntries)) } ?? []
        let over = (release?.shown(upTo: tier).count ?? 0) - shown.count

        return VStack(alignment: .leading, spacing: 3) {
            if shown.isEmpty {
                Text(release.map { $0.hiddenCount(upTo: tier) > 0 ? "Nothing at this level of detail." : "No entries." } ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            ForEach(shown) { line in
                HStack(alignment: .top, spacing: 5) {
                    Text(line.kind.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(color(for: line.kind))
                        .frame(width: 48, alignment: .leading)
                    Text(strip(line.text, of: line.kind))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if over > 0 {
                Text("+\(over) more in this release — raise Detail or pick it alone")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// The verb is already shown as the tag beside it, so repeating it in the sentence
    /// wastes a line of a narrow panel.
    private func strip(_ text: String, of kind: ChangeKind) -> String {
        guard kind != .other, text.hasPrefix(kind.rawValue + " ") else { return text }
        return String(text.dropFirst(kind.rawValue.count + 1))
    }

    private func color(for kind: ChangeKind) -> Color {
        switch kind {
        case .added: Severity.normal.color
        case .changed, .removed: Severity.warning.color
        default: .secondary
        }
    }
}
