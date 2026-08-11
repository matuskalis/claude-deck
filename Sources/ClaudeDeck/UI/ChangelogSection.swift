import SwiftUI

/// What changed in the tool you are using, from the changelog Claude Code already keeps on
/// disk. Two controls, because the file has exactly two useful axes: how much of each
/// release to show, and how far back to go.
struct ChangelogSection: View {
    let releases: [Release]
    let installedVersion: String?

    @AppStorage("changelog.simplified") private var simplified = true
    @AppStorage("changelog.depth") private var depth = 5

    private static let depths = [5, 20, 60]

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(releases.prefix(depth)) { release in
                            entry(release)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 420)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 5) {
            Picker("", selection: $simplified) {
                Text("Simplified").tag(true)
                Text("Full").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("", selection: $depth) {
                ForEach(Self.depths, id: \.self) { count in
                    Text("\(count) releases").tag(count)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .controlSize(.small)
        .font(.system(size: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func entry(_ release: Release) -> some View {
        let shown = simplified ? release.noteworthy : release.entries
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(release.version)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                if release.version == installedVersion {
                    Text("yours")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Severity.normal.color.opacity(0.16), in: Capsule())
                        .foregroundStyle(Severity.normal.color)
                }
                Spacer(minLength: 4)
                if simplified, release.quietCount > 0 {
                    Text("+\(release.quietCount) fixes")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            if shown.isEmpty {
                Text(simplified ? "Fixes only." : "No entries.")
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
                        .lineLimit(simplified ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The verb is already shown as the tag beside it, so repeating it in the sentence
    /// wastes a line of a 360pt panel.
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
