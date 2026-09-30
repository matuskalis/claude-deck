import Foundation
import Testing

@testable import ClaudeDeck

/// "Launch Claude in..." builds a shell command from a folder name and hands it to
/// AppleScript inside a string literal, so a folder name is escaped twice. These tests take
/// the generated script apart, undo the AppleScript layer, and run what is left through
/// `/bin/sh` with `claude` replaced by a function that reports where it landed.
extension DeckTests {
    @Suite struct LauncherTests {
        init() throws { try Hermetic.reset() }

        /// The text of the AppleScript string literal after `marker`, up to the closing quote
        /// that is followed by `terminator`.
        private static func literal(in script: String, after marker: String, before terminator: String) throws -> String {
            let afterMarker = try #require(script.components(separatedBy: marker).dropFirst().first)
            return try #require(afterMarker.components(separatedBy: terminator).first)
        }

        /// What AppleScript makes of a string literal: `\\` and `\"` lose their backslash.
        private static func unescapeAppleScript(_ text: String) -> String {
            var result = ""
            var iterator = text.makeIterator()
            while let character = iterator.next() {
                if character == "\\", let next = iterator.next() {
                    result.append(next)
                } else {
                    result.append(character)
                }
            }
            return result
        }

        /// Runs the command the terminal would, with `claude` standing in.
        private static func run(_ command: String) throws -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "claude() { pwd; echo \"args:$*\"; }; " + command]
            process.environment = ["PATH": "/bin:/usr/bin"]
            // If quoting ever failed, anything the command did would land in the sandbox.
            process.currentDirectoryURL = Hermetic.root
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }

        @MainActor
        private static func terminalCommand(directory: String, resume: Bool) throws -> String {
            let previous = Launcher.iTermPath
            Launcher.iTermPath = "/nonexistent/iTerm.app"
            defer { Launcher.iTermPath = previous }
            let script = Launcher.script(directory: directory, resume: resume)
            return unescapeAppleScript(try literal(in: script, after: "do script \"", before: "\"\n  activate"))
        }

        @MainActor
        private static func iTermCommand(directory: String, resume: Bool) throws -> String {
            let previous = Launcher.iTermPath
            Launcher.iTermPath = "/"
            defer { Launcher.iTermPath = previous }
            let script = Launcher.script(directory: directory, resume: resume)
            return unescapeAppleScript(try literal(in: script, after: "write text \"", before: "\"\nend tell"))
        }

        private static func awkwardDirectory(_ name: String) throws -> String {
            let url = Hermetic.root.appending(path: name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }

        // MARK: - Quoting

        @MainActor
        @Test("a folder with an apostrophe launches where it should, in Terminal")
        func apostropheInTerminal() throws {
            let directory = try Self.awkwardDirectory("it's a test")
            let lines = try Self.run(Self.terminalCommand(directory: directory, resume: false))
            #expect(lines.first == directory)
            #expect(lines.dropFirst().first == "args:")
        }

        @MainActor
        @Test("a folder with an apostrophe launches where it should, in iTerm")
        func apostropheInITerm() throws {
            let directory = try Self.awkwardDirectory("it's a test")
            let lines = try Self.run(Self.iTermCommand(directory: directory, resume: false))
            #expect(lines.first == directory)
        }

        @MainActor
        @Test("double quotes, backslashes and spaces survive both layers")
        func everyAwkwardCharacter() throws {
            let directory = try Self.awkwardDirectory(#"quoted "name" \ with $dollar and `tick`"#)
            for command in [
                try Self.terminalCommand(directory: directory, resume: false),
                try Self.iTermCommand(directory: directory, resume: false),
            ] {
                #expect(try Self.run(command).first == directory)
            }
        }

        @MainActor
        @Test("a folder name cannot break out of the quoted path and run something else")
        func noInjection() throws {
            let directory = try Self.awkwardDirectory("x'; touch pwned; echo '")
            let lines = try Self.run(Self.terminalCommand(directory: directory, resume: false))
            #expect(lines.first == directory)
            #expect(!FileManager.default.fileExists(atPath: Hermetic.root.appending(path: "pwned").path))
        }

        // MARK: - What it starts

        @MainActor
        @Test("resume adds -c, and a fresh launch does not")
        func resumeFlag() throws {
            let directory = try Self.awkwardDirectory("project")
            let fresh = try Self.run(Self.terminalCommand(directory: directory, resume: false))
            let resumed = try Self.run(Self.terminalCommand(directory: directory, resume: true))
            #expect(fresh.dropFirst().first == "args:")
            #expect(resumed.dropFirst().first == "args:-c")
        }

        @MainActor
        @Test("iTerm is used when it is installed, Terminal when it is not")
        func choosesTheTerminal() {
            let previous = Launcher.iTermPath
            defer { Launcher.iTermPath = previous }

            Launcher.iTermPath = "/"
            #expect(Launcher.script(directory: "/tmp", resume: false).contains("tell application \"iTerm\""))

            Launcher.iTermPath = "/nonexistent/iTerm.app"
            #expect(Launcher.script(directory: "/tmp", resume: false).contains("tell application \"Terminal\""))
        }
    }
}
