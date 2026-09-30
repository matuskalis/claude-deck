import Foundation
import Testing

@testable import ClaudeDeck

/// The Changelog tab reads a markdown file Claude Code already keeps: a `## version`
/// heading per release and one `- ` line per change, newest first, no dates. The detail
/// slider is a filter on the leading verb, so the classification is the feature.
extension DeckTests {
    @Suite struct ChangelogTests {
        init() throws { try Hermetic.reset() }

        private static func releases(_ text: String) async throws -> [Release] {
            try Hermetic.write(text, to: ".claude/cache/changelog.md")
            return await ChangelogReader().releases()
        }

        // MARK: - Parsing

        @Test("one release per heading, one entry per bullet, in file order")
        func parsesReleasesAndEntries() async throws {
            let releases = try await Self.releases("""
            # Changelog

            ## 2.1.10

            - Added a thing
            - Fixed a crash when the terminal resized

            ## 2.1.9

            - Changed the default

            """)

            #expect(releases.map(\.version) == ["2.1.10", "2.1.9"])
            #expect(releases[0].entries.map(\.text) == ["Added a thing", "Fixed a crash when the terminal resized"])
            #expect(releases[1].entries.map(\.text) == ["Changed the default"])
            #expect(releases[0].entries.map(\.kind) == [.added, .fixed])
        }

        @Test("bullets before the first heading, and prose between bullets, are not entries")
        func ignoresWhatIsNotAnEntry() async throws {
            let releases = try await Self.releases("""
            - Orphan bullet before any release
            Some prose that explains nothing.
            ## 1.0.0
            Intro sentence.
            - Added the first thing
            Trailing prose.

            """)

            #expect(releases.count == 1)
            #expect(releases[0].entries.map(\.text) == ["Added the first thing"])
        }

        @Test("whitespace around versions and entries is trimmed")
        func trimsWhitespace() async throws {
            let releases = try await Self.releases("##   3.0.0   \n-   Removed the old flag   \n")
            #expect(releases.map(\.version) == ["3.0.0"])
            #expect(releases[0].entries.map(\.text) == ["Removed the old flag"])
            #expect(releases[0].entries.map(\.kind) == [.removed])
        }

        @Test("entry ids are unique across releases, so a list can key on them")
        func idsAreUnique() async throws {
            let releases = try await Self.releases("## 2\n- Added a\n- Added b\n## 1\n- Added c\n")
            let ids = releases.flatMap(\.entries).map(\.id)
            #expect(Set(ids).count == ids.count)
        }

        @Test("a release with no bullets is kept, and an empty file gives no releases")
        func emptyReleasesAndFiles() async throws {
            let releases = try await Self.releases("## 1.0.0\n## 0.9.0\n- Added x\n")
            #expect(releases.map(\.version) == ["1.0.0", "0.9.0"])
            #expect(releases[0].entries.isEmpty)
            #expect(try await Self.releases("").isEmpty)
        }

        @Test("a missing changelog gives no releases rather than an error")
        func missingFile() async {
            #expect(await ChangelogReader().releases().isEmpty)
        }

        @Test("a changed file is re-read, an unchanged one is not")
        func rereadsOnChange() async throws {
            let reader = ChangelogReader()
            try Hermetic.write("## 1.0.0\n- Added a\n", to: ".claude/cache/changelog.md")
            #expect(await reader.releases().map(\.version) == ["1.0.0"])

            try Hermetic.write("## 2.0.0\n- Added a\n- Added b\n", to: ".claude/cache/changelog.md")
            #expect(await reader.releases().map(\.version) == ["2.0.0"])
        }

        // MARK: - Kinds and the detail slider

        @Test("the leading verb decides the kind")
        func classifiesByLeadingVerb() {
            #expect(ChangeKind(line: "Added a new command") == .added)
            #expect(ChangeKind(line: "Changed the default model") == .changed)
            #expect(ChangeKind(line: "Removed the deprecated flag") == .removed)
            #expect(ChangeKind(line: "Fixed a crash") == .fixed)
            #expect(ChangeKind(line: "Improved startup time") == .improved)
            #expect(ChangeKind(line: "Reduced memory use") == .improved)
        }

        @Test("only the exact verb counts, and a line with no verb is a note")
        func onlyExactVerbsCount() {
            #expect(ChangeKind(line: "Fixes a crash") == .other)
            #expect(ChangeKind(line: "Windows: paste now works") == .other)
            #expect(ChangeKind(line: "Adding support") == .other)
            #expect(ChangeKind(line: "") == .other)
            #expect(ChangeKind.other.label == "Note")
            #expect(ChangeKind.fixed.label == "Fixed")
        }

        @Test("fixes sit at the far end of the detail slider, notes at the near end")
        func tiers() {
            #expect([ChangeKind.added, .changed, .removed, .other].allSatisfy { $0.tier == 0 })
            #expect(ChangeKind.improved.tier == 1)
            #expect(ChangeKind.fixed.tier == 2)
        }

        @Test("each detail level shows what it should and counts what it holds back")
        func filtersByTier() async throws {
            let releases = try await Self.releases("""
            ## 1.0.0
            - Added one
            - Improved two
            - Fixed three
            - Fixed four
            - Note without a verb
            """)
            let release = try #require(releases.first)

            #expect(release.shown(upTo: 0).map(\.text) == ["Added one", "Note without a verb"])
            #expect(release.hiddenCount(upTo: 0) == 3)
            #expect(release.shown(upTo: 1).count == 3)
            #expect(release.hiddenCount(upTo: 1) == 2)
            #expect(release.shown(upTo: 2).count == 5)
            #expect(release.hiddenCount(upTo: 2) == 0)
        }
    }
}
