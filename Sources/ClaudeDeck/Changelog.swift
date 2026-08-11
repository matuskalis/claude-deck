import Foundation

/// What a changelog line does to you. Taken from the leading verb, which Claude Code's
/// changelog uses consistently: of 4318 entries, 53% begin "Fixed".
enum ChangeKind: String, Sendable {
    case added = "Added"
    case changed = "Changed"
    case removed = "Removed"
    case fixed = "Fixed"
    case improved = "Improved"
    case other = ""

    init(line: String) {
        switch line.prefix(while: { !$0.isWhitespace }) {
        case "Added": self = .added
        case "Changed": self = .changed
        case "Removed": self = .removed
        case "Fixed": self = .fixed
        case "Improved", "Reduced": self = .improved
        default: self = .other
        }
    }

    /// How far the detail slider has to be pushed before this kind of line appears.
    /// Fixes are the bulk of any changelog — 53% of entries here — and almost never change
    /// how you work, so they sit at the far end.
    var tier: Int {
        switch self {
        case .added, .changed, .removed, .other: 0
        case .improved: 1
        case .fixed: 2
        }
    }

    var label: String {
        switch self {
        case .other: "Note"
        default: rawValue
        }
    }
}

struct ChangelogEntry: Identifiable, Sendable, Equatable {
    let id: Int
    var kind: ChangeKind
    var text: String
}

struct Release: Identifiable, Sendable, Equatable {
    var id: String { version }
    var version: String
    var entries: [ChangelogEntry]

    func shown(upTo tier: Int) -> [ChangelogEntry] { entries.filter { $0.kind.tier <= tier } }
    func hiddenCount(upTo tier: Int) -> Int { entries.count { $0.kind.tier > tier } }
}

/// Reads the changelog Claude Code already keeps at ~/.claude/cache/changelog.md.
///
/// No network, no key, no summarising: the entries are already written, one line each, by
/// the people who made the change. The file carries versions but no dates, so "how far
/// back" is measured in releases rather than days.
actor ChangelogReader {
    static let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/cache/changelog.md")

    private var stamp = ""
    private var cached: [Release] = []

    func releases() -> [Release] {
        var info = stat()
        guard stat(Self.url.path, &info) == 0 else { return cached }
        let current = "\(info.st_size)-\(info.st_mtimespec.tv_sec)"
        guard current != stamp else { return cached }

        guard let data = try? Data(contentsOf: Self.url) else { return cached }
        stamp = current

        var releases: [Release] = []
        var identifier = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("## ") {
                releases.append(Release(version: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), entries: []))
            } else if line.hasPrefix("- "), !releases.isEmpty {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                identifier += 1
                releases[releases.count - 1].entries.append(
                    ChangelogEntry(id: identifier, kind: ChangeKind(line: text), text: text)
                )
            }
        }

        cached = releases
        return cached
    }
}
