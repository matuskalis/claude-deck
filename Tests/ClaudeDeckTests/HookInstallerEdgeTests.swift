import Foundation
import Testing

@testable import ClaudeDeck

/// `settings.json` is the one file in Claude Code's config that this app writes. The main
/// splice behaviour is covered in `HookInstallerTests`; these are the refusals, the backup,
/// and the cases the README promises by name: a dotfiles symlink, a file that is not an
/// object, a settings file that does not exist yet.
extension DeckTests {
    @Suite struct HookInstallerEdgeTests {
        init() throws { try Hermetic.reset() }

        private static var settings: URL { HookInstaller.settingsURL }

        private static func read(_ url: URL) throws -> String {
            String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }

        private static func backups() throws -> [URL] {
            let folder = settings.deletingLastPathComponent()
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("settings.json.bak-claude-deck-") }
        }

        // MARK: - Backups

        @Test("the file is copied aside, byte for byte, before anything is written")
        func backsUpFirst() throws {
            let original = "{\n  \"model\": \"claude-opus-5\",\n\t\"odd\":   [1,2 ,3]\n}\n"
            try Hermetic.write(original, to: ".claude/settings.json")

            try HookInstaller.install()

            let copies = try Self.backups()
            #expect(copies.count == 1)
            #expect(try Self.read(try #require(copies.first)) == original)
            #expect(try Self.read(Self.settings) != original)
        }

        @Test("removing the hooks takes a backup too")
        func removeBacksUp() throws {
            try Hermetic.write("{\n}\n", to: ".claude/settings.json")
            try HookInstaller.install()
            let before = try Self.backups().count

            // The backup name is stamped to the second; make sure the second one is distinct.
            Thread.sleep(forTimeInterval: 1.1)
            try HookInstaller.remove()
            #expect(try Self.backups().count == before + 1)
        }

        // MARK: - Files that are not what they should be

        @Test("a settings file that is not a JSON object is refused and left alone")
        func refusesANonObject() throws {
            try Hermetic.write("[1, 2, 3]\n", to: ".claude/settings.json")

            #expect(throws: HookInstallError.self) { try HookInstaller.install() }
            #expect(try Self.read(Self.settings) == "[1, 2, 3]\n")
            #expect(try Self.backups().isEmpty)
        }

        @Test("a hooks value that is not an object is refused rather than guessed at")
        func refusesOddHooks() throws {
            let original = "{\n  \"hooks\": \"none\"\n}\n"
            try Hermetic.write(original, to: ".claude/settings.json")

            #expect(throws: HookInstallError.self) { try HookInstaller.install() }
            #expect(try Self.read(Self.settings) == original)
        }

        @Test("an event that is not an array is refused, and nothing is written")
        func refusesAnEventThatIsNotAnArray() throws {
            let original = "{\n  \"hooks\": {\n    \"Stop\": {\"oops\": true}\n  }\n}\n"
            try Hermetic.write(original, to: ".claude/settings.json")

            #expect(throws: HookInstallError.self) { try HookInstaller.install() }
            #expect(try Self.read(Self.settings) == original)
            #expect(try Self.backups().isEmpty)
        }

        @Test("removing from a settings file that does not exist does nothing")
        func removeWithNoFile() throws {
            try HookInstaller.remove()
            #expect(!FileManager.default.fileExists(atPath: Self.settings.path))
        }

        @Test("there is no settings file yet: one is created, with every hook, and no backup")
        func installCreatesTheFile() throws {
            #expect(!FileManager.default.fileExists(atPath: Self.settings.path))

            try HookInstaller.install()

            #expect(HookInstaller.isInstalled)
            #expect(try Self.backups().isEmpty)
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.settings)) as? [String: Any]
            #expect((root?["hooks"] as? [String: Any])?.count == HookInstaller.eventNames.count)
        }

        // MARK: - Symlinks

        @Test("a settings.json that is a symlink stays a symlink, and its target is what changes")
        func followsDotfileSymlinks() throws {
            let real = Hermetic.root.appending(path: "dotfiles/claude-settings.json")
            try Hermetic.write("{\n  \"model\": \"claude-opus-5\"\n}\n", to: "dotfiles/claude-settings.json")
            try FileManager.default.createSymbolicLink(at: Self.settings, withDestinationURL: real)

            try HookInstaller.install()

            let link = try FileManager.default.destinationOfSymbolicLink(atPath: Self.settings.path)
            #expect(link == real.path)
            #expect(try Self.read(real).contains("claude-deck/spool"))

            try HookInstaller.remove()
            #expect(try Self.read(real) == "{\n  \"model\": \"claude-opus-5\"\n}\n")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: Self.settings.path) == real.path)
        }

        // MARK: - What counts as installed

        @Test("one missing event is enough to read as not installed")
        func partialInstallIsNotInstalled() throws {
            try HookInstaller.install()
            #expect(HookInstaller.isInstalled)

            // Take one of the seven out by hand.
            // In the file the command sits inside a JSON string, so its quotes are escaped.
            let command = HookInstaller.command(for: "SessionEnd").replacingOccurrences(of: "\"", with: "\\\"")
            var text = try Self.read(Self.settings)
            #expect(text.contains(command))
            text = text.replacingOccurrences(of: command, with: "true # edited by hand")
            try Data(text.utf8).write(to: Self.settings)

            #expect(!HookInstaller.isInstalled)
        }

        @Test("every hook is written with a five second timeout, because the field is in seconds")
        func timeoutIsInSeconds() throws {
            try HookInstaller.install()

            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.settings)) as? [String: Any]
            let hooks = try #require(root?["hooks"] as? [String: [[String: Any]]])
            #expect(hooks.count == 7)
            for (event, matchers) in hooks {
                let entries = matchers.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                #expect(entries.count == 1, "\(event)")
                #expect(entries.first?["timeout"] as? Int == 5, "\(event)")
            }
        }

        @Test("each event is wired to the right spool: tool events to tools, the rest to events")
        func commandsTargetTheRightSpool() {
            #expect(HookInstaller.command(for: "PreToolUse").hasSuffix("spool\" tools PreToolUse"))
            #expect(HookInstaller.command(for: "PostToolUse").hasSuffix("spool\" tools PostToolUse"))
            for name in ["Notification", "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd"] {
                #expect(HookInstaller.command(for: name).hasSuffix("spool\" events \(name)"), "\(name)")
            }
            #expect(HookInstaller.eventNames.count == 7)
        }
    }
}
