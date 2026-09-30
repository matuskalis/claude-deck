import Foundation
import Testing

@testable import ClaudeDeck

/// A throwaway home directory for tests.
///
/// The app reads `NSHomeDirectory()/.claude`, and several readers cache that path in a
/// static the first time they are used. `HOME` does not move it on macOS, but
/// `CFFIXED_USER_HOME` does, and it is read on every call. A suite that writes fixtures
/// calls `Hermetic.reset()` from its `init`, which Swift Testing runs before every test:
/// that redirects the home, empties it, and points the two paths the tests redirect by
/// hand into it. Every reader, spool and settings file then lives in one directory that is
/// deleted when the run ends, so nothing a test does can reach the developer's real
/// `~/.claude`.
///
/// If the redirect ever stops working, `reset` throws before the test body runs.
///
/// A custom `SuiteTrait` would be the tidier way to do this for a whole suite tree, but
/// the Swift 6.4 toolchain's test runner traps while planning any custom suite trait, so
/// the call is explicit.
enum Hermetic {
    struct NotRedirected: Error, CustomStringConvertible {
        let got: String
        var description: String { "NSHomeDirectory() is \(got), not the throwaway home; refusing to run" }
    }

    private static let created: URL = {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "claude-deck-test-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let resolved = base.resolvingSymlinksInPath()
        removeAtExit(resolved.path)
        return resolved
    }()

    /// Stands in for the user's home. Emptied before every test.
    static var root: URL { created }
    static var claude: URL { root.appending(path: ".claude") }

    /// Points `NSHomeDirectory()` at the throwaway home. Safe to call any number of times.
    static func redirect() throws {
        setenv("CFFIXED_USER_HOME", root.path, 1)
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        guard home == root.path else { throw NotRedirected(got: home) }
    }

    /// An empty home, with the two paths the tests redirect by hand pointed into it. Called
    /// from the `init` of every suite that writes fixtures, which Swift Testing runs once
    /// per test.
    static func reset() throws {
        try redirect()
        let manager = FileManager.default
        for item in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? manager.removeItem(at: item)
        }
        try manager.createDirectory(at: claude, withIntermediateDirectories: true)

        EventsSpool.directory = claude.appending(path: "claude-deck")
        HookInstaller.settingsURL = claude.appending(path: "settings.json")
    }

    // MARK: - Fixture files

    /// Writes `text` at a path under the throwaway home, creating the folders above it.
    @discardableResult
    static func write(_ text: String, to path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    static func append(_ text: String, to path: String) throws {
        let url = root.appending(path: path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    static func lines(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Time

    static var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }

    /// Transcript timestamps: fixed-width UTC with milliseconds.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `resets_at` as Claude Code writes it: six fractional digits and an explicit offset.
    static func sixDigitISO(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date) + ".123456+00:00"
    }

    static func epochMilliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - Transcript lines

    /// One line of a session transcript the way Claude Code writes it: snake_case keys, the
    /// `usage` repeated on every content block of a message.
    static func assistantLine(
        id: String?,
        at date: Date,
        model: String = "claude-opus-5",
        cwd: String = "/work/alpha",
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0
    ) -> String {
        let identifier = id.map { "\"id\":\"\($0)\"," } ?? ""
        return """
        {"type":"assistant","timestamp":"\(stamp(date))","cwd":"\(cwd)","message":{\(identifier)"model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    private static func removeAtExit(_ path: String) {
        cleanupPath = path
        atexit {
            if let path = cleanupPath { try? FileManager.default.removeItem(atPath: path) }
        }
    }
}

nonisolated(unsafe) private var cleanupPath: String?
