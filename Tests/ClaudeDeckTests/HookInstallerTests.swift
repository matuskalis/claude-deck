import Foundation
import Testing

@testable import ClaudeDeck

/// The hook installer edits a file the user owns and did not ask us to reformat, and the
/// uninstaller takes entries back out of it. Neither is safe to verify by eye.
@Suite(.serialized)
struct HookInstallerTests {
    /// Each test gets its own settings file and spool directory; the real ones are never
    /// touched.
    private static func inSandbox(_ contents: String, _ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "claude-deck-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = root.appending(path: "settings.json")
        try Data(contents.utf8).write(to: settings)

        let previousSettings = HookInstaller.settingsURL
        let previousDirectory = EventsSpool.directory
        HookInstaller.settingsURL = settings
        EventsSpool.directory = root.appending(path: "claude-deck")
        defer {
            HookInstaller.settingsURL = previousSettings
            EventsSpool.directory = previousDirectory
        }

        try body(settings)
    }

    private static func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private static func hooks(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return root?["hooks"] as? [String: Any] ?? [:]
    }

    @Test("installs every hook into an empty settings file")
    func installsIntoEmptyFile() throws {
        try Self.inSandbox("{\n}\n") { settings in
            try HookInstaller.install()

            let hooks = try Self.hooks(settings)
            #expect(hooks.count == HookInstaller.eventNames.count)
            for name in HookInstaller.eventNames {
                let commands = HookInstaller.commands(in: hooks[name] as Any)
                #expect(commands == [HookInstaller.command(for: name)])
            }
            #expect(HookInstaller.isInstalled)
        }
    }

    @Test("leaves every other byte of the file alone")
    func preservesUnrelatedContent() throws {
        let original = """
        {
          "model": "claude-opus-5[1m]",
          "env": {
            "FOO": "bar"
          },
          "permissions": {
            "allow": ["Bash(ls:*)"]
          }
        }

        """
        try Self.inSandbox(original) { settings in
            try HookInstaller.install()
            let after = try Self.read(settings)

            // Every line of the original still present, in order, and nothing removed.
            var remaining = after[...]
            for line in original.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                guard let found = remaining.range(of: line) else {
                    Issue.record("line vanished from settings.json: \(line)")
                    return
                }
                remaining = remaining[found.upperBound...]
            }
        }
    }

    @Test("adds to an event the user already uses, rather than replacing it")
    func mergesWithExistingHook() throws {
        let original = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "afplay /System/Library/Sounds/Glass.aiff"
                  }
                ]
              }
            ]
          }
        }

        """
        try Self.inSandbox(original) { settings in
            try HookInstaller.install()

            let commands = HookInstaller.commands(in: try Self.hooks(settings)["Stop"] as Any)
            #expect(commands.contains("afplay /System/Library/Sounds/Glass.aiff"))
            #expect(commands.contains(HookInstaller.command(for: "Stop")))
            #expect(commands.count == 2)
        }
    }

    @Test("uninstalling puts the file back exactly as it was")
    func removeIsExactlyReversible() throws {
        let original = """
        {
          "model": "claude-opus-5",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "afplay /System/Library/Sounds/Glass.aiff"
                  }
                ]
              }
            ]
          }
        }

        """
        try Self.inSandbox(original) { settings in
            try HookInstaller.install()
            #expect(try Self.read(settings) != original)

            try HookInstaller.remove()
            #expect(try Self.read(settings) == original)
        }
    }

    @Test("uninstalling from a file that had no hooks at all removes the key it added")
    func removeDropsTheHooksKeyItCreated() throws {
        let original = "{\n  \"model\": \"claude-opus-5\"\n}\n"
        try Self.inSandbox(original) { settings in
            try HookInstaller.install()
            try HookInstaller.remove()
            #expect(try Self.read(settings) == original)
            #expect(try Self.hooks(settings).isEmpty)
        }
    }

    @Test("uninstalling never touches hooks the user wrote")
    func removeKeepsForeignHooks() throws {
        let original = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/local/bin/audit-tool-call"
                  }
                ]
              }
            ]
          }
        }

        """
        try Self.inSandbox(original) { settings in
            try HookInstaller.install()
            try HookInstaller.remove()

            let commands = HookInstaller.commands(in: try Self.hooks(settings)["PreToolUse"] as Any)
            #expect(commands == ["/usr/local/bin/audit-tool-call"])
            #expect(try Self.read(settings) == original)
        }
    }

    @Test("a hook left by an older version reads as missing, and reinstalling replaces it")
    func upgradesStaleCommands() throws {
        // Exactly what 1.2 and 1.3 wrote: the raw payload appended straight to the spool.
        let legacy = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "mkdir -p ~/.claude/claude-deck; { cat; printf '\\\\n'; } >> ~/.claude/claude-deck/events.jsonl"
                  }
                ]
              }
            ]
          }
        }

        """
        try Self.inSandbox(legacy) { settings in
            #expect(!HookInstaller.isInstalled)
            #expect(HookInstaller.hasStaleCommands)

            try HookInstaller.reinstall()

            let commands = HookInstaller.commands(in: try Self.hooks(settings)["Stop"] as Any)
            #expect(commands == [HookInstaller.command(for: "Stop")])
            #expect(!HookInstaller.hasStaleCommands)
            #expect(HookInstaller.isInstalled)
        }
    }

    @Test("installing twice changes nothing the second time")
    func installIsIdempotent() throws {
        try Self.inSandbox("{\n}\n") { settings in
            try HookInstaller.install()
            let once = try Self.read(settings)
            try HookInstaller.install()
            #expect(try Self.read(settings) == once)
        }
    }

    @Test("the spool helper is written private and executable")
    func helperPermissions() throws {
        try Self.inSandbox("{\n}\n") { _ in
            try HookInstaller.install()

            let attributes = try FileManager.default.attributesOfItem(atPath: HookInstaller.helperURL.path)
            #expect(attributes[.posixPermissions] as? Int == 0o700)

            let directory = try FileManager.default.attributesOfItem(atPath: EventsSpool.directory.path)
            #expect(directory[.posixPermissions] as? Int == 0o700)
        }
    }

    @Test("the helper records the fields the menu needs and none of the payload")
    func helperRecordsOnlyDisplayedFields() throws {
        try Self.inSandbox("{\n}\n") { settings in
            try HookInstaller.install()

            let payload = """
            {"hook_event_name":"PreToolUse","session_id":"11111111-2222-3333-4444-555555555555",\
            "cwd":"/Users/someone/secret-project","transcript_path":"/Users/someone/.claude/x.jsonl",\
            "tool_name":"Bash","tool_input":{"command":"deploy --token=SUPERSECRET"}}
            """

            // The helper resolves $HOME, so the child gets a home of its own — otherwise
            // this test would append to the real spool.
            let home = settings.deletingLastPathComponent()
            let process = Process()
            process.executableURL = HookInstaller.helperURL
            process.arguments = ["tools", "PreToolUse"]
            process.environment = ["HOME": home.path, "PATH": "/bin:/usr/bin"]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()

            #expect(process.terminationStatus == 0)

            let spool = home.appending(path: ".claude/claude-deck/tools.jsonl")
            let written = String(decoding: try Data(contentsOf: spool), as: UTF8.self)
            #expect(written.contains("\"tool_name\":\"Bash\""))
            #expect(written.contains("11111111-2222-3333-4444-555555555555"))
            // The whole point: none of this may ever reach disk.
            #expect(!written.contains("SUPERSECRET"))
            #expect(!written.contains("deploy"))
            #expect(!written.contains("secret-project"))
            #expect(!written.contains("transcript_path"))

            let event = try JSONDecoder().decode(DeckEvent.self, from: Data(written.utf8))
            #expect(event.hookEventName == "PreToolUse")
            #expect(event.toolName == "Bash")
        }
    }
}
