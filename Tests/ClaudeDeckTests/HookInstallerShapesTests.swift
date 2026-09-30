import Foundation
import Testing

@testable import ClaudeDeck

/// The installer splices text into a file people format in their own way. Two promises, kept
/// apart because they are different strengths: whatever the layout, the result is valid JSON
/// and removing the hooks loses nothing that was there; and for the usual layouts the file
/// comes back byte for byte.
extension DeckTests {
    @Suite struct HookInstallerShapesTests {
        init() throws { try Hermetic.reset() }

        private static let shapes: [(name: String, text: String)] = [
            ("two-space", "{\n  \"model\": \"claude-opus-5\",\n  \"env\": {\n    \"A\": \"b\"\n  }\n}\n"),
            ("four-space", "{\n    \"model\": \"claude-opus-5\",\n    \"env\": {\n        \"A\": \"b\"\n    }\n}\n"),
            ("tabs", "{\n\t\"model\": \"claude-opus-5\",\n\t\"env\": {\n\t\t\"A\": \"b\"\n\t}\n}\n"),
            ("no trailing newline", "{\n  \"model\": \"claude-opus-5\"\n}"),
            ("hooks last, with one of the user's own", "{\n  \"model\": \"x\",\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [ { \"type\": \"command\", \"command\": \"echo hi\" } ]\n      }\n    ]\n  }\n}\n"),
            ("braces and escapes inside strings", "{\n  \"note\": \"Přístup \\\"quoted\\\" {not a brace} [nor a bracket]\",\n  \"model\": \"x\"\n}\n"),
            ("minified", #"{"model":"claude-opus-5","env":{"A":"b"}}"#),
            ("minified with a final newline", "{\"model\":\"claude-opus-5\"}\n"),
            ("Windows line endings", "{\r\n  \"model\": \"claude-opus-5\",\r\n  \"env\": {\r\n    \"A\": \"b\"\r\n  }\r\n}\r\n"),
            ("an empty object", "{}"),
            ("an empty object and a newline", "{}\n"),
        ]

        /// Layouts in which the file is expected to come back exactly.
        private static let exact: Set<String> = [
            "two-space", "four-space", "tabs", "no trailing newline",
            "hooks last, with one of the user's own", "braces and escapes inside strings",
        ]

        private static func object(_ text: String) throws -> NSDictionary {
            try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        }

        @Test("whatever the layout, the result is valid JSON, and removing the hooks loses nothing", arguments: shapes)
        func staysValidAndLosesNothing(shape: (name: String, text: String)) throws {
            let original = try Self.object(shape.text)
            try Hermetic.write(shape.text, to: ".claude/settings.json")

            try HookInstaller.install()
            let installed = try Self.object(try String(contentsOf: HookInstaller.settingsURL, encoding: .utf8))
            #expect(HookInstaller.isInstalled, "\(shape.name)")
            // Every key that was there is still there, and `hooks` is added if it was not.
            #expect(installed.count == original.count + (original["hooks"] == nil ? 1 : 0), "\(shape.name)")

            try HookInstaller.remove()
            let restored = try Self.object(try String(contentsOf: HookInstaller.settingsURL, encoding: .utf8))
            #expect(!HookInstaller.isInstalled && !HookInstaller.hasStaleCommands, "\(shape.name)")
            #expect(restored.isEqual(to: original), "\(shape.name): content changed")
        }

        @Test("in the usual layouts the file comes back byte for byte", arguments: shapes.filter { exact.contains($0.name) })
        func exactForUsualLayouts(shape: (name: String, text: String)) throws {
            try Hermetic.write(shape.text, to: ".claude/settings.json")
            try HookInstaller.install()
            try HookInstaller.remove()
            #expect(try String(contentsOf: HookInstaller.settingsURL, encoding: .utf8) == shape.text, "\(shape.name)")
        }

        @Test("an empty hooks object, or an empty event array, that was already there is tidied away")
        func emptyContainersAreDropped() throws {
            // The one thing removal does beyond taking out its own entries: an event array or a
            // hooks object that removal leaves empty is removed, even if it was empty before.
            try Hermetic.write("{\n  \"model\": \"x\",\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n", to: ".claude/settings.json")
            try HookInstaller.install()
            try HookInstaller.remove()

            let restored = try Self.object(try String(contentsOf: HookInstaller.settingsURL, encoding: .utf8))
            #expect(restored.isEqual(to: ["model": "x"]))
        }
    }
}
