import Foundation

enum HookInstallError: LocalizedError {
    case unreadable
    case notAnObject
    case unsupportedShape(String)
    case wouldCorrupt

    var errorDescription: String? {
        switch self {
        case .unreadable: "Could not read ~/.claude/settings.json"
        case .notAnObject: "~/.claude/settings.json is not a JSON object"
        case .unsupportedShape(let key): "~/.claude/settings.json has an unexpected value for \"\(key)\"; fix it by hand and try again"
        case .wouldCorrupt: "Refusing to write: the edited settings.json did not come out valid"
        }
    }
}

/// Installs the hooks that feed our event spools.
///
/// settings.json is the only file in the user's config the app writes to, so the
/// edit is a text splice: a hook is added to the existing `hooks` object, or to an
/// existing event array if the user already has hooks under that name, and every
/// other byte of the file is left exactly as it was. A timestamped backup is taken
/// first and the result is re-checked before it is written.
enum HookInstaller {
    static let eventNames = [
        "Notification", "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd",
        "PreToolUse", "PostToolUse",
    ]

    /// Tool events fire on every single tool call and their payload carries the whole
    /// `tool_input`, so they get their own spool and a helper that keeps it bounded.
    /// The other events are rare enough to append inline.
    static let toolEventNames: Set<String> = ["PreToolUse", "PostToolUse"]

    static let command = "mkdir -p ~/.claude/claude-deck; { cat; printf '\\n'; } >> ~/.claude/claude-deck/events.jsonl"
    static let toolCommand = "\"$HOME/.claude/claude-deck/spool\""

    static let settingsURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/settings.json")
    static let helperURL = EventsSpool.directory.appending(path: "spool")

    static var isInstalled: Bool {
        missingEventNames().isEmpty
    }

    static func install() throws {
        let missing = missingEventNames()
        guard !missing.isEmpty else { return }
        try writeHelper()

        // Writing atomically through a symlink would replace the link with a regular
        // file and leave the real settings.json untouched.
        let target = settingsURL.resolvingSymlinksInPath()

        let existed = FileManager.default.fileExists(atPath: target.path)
        var original = Data("{\n}\n".utf8)
        if existed {
            guard let data = try? Data(contentsOf: target) else { throw HookInstallError.unreadable }
            original = data
        }

        var bytes = Array(original)
        guard let rootBrace = rootBraceIndex(bytes) else { throw HookInstallError.notAnObject }

        if let hooksValue = valueStart(of: "hooks", inObjectAt: rootBrace, bytes: bytes) {
            guard bytes[hooksValue] == UInt8(ascii: "{") else { throw HookInstallError.unsupportedShape("hooks") }

            // Every insertion lands after the `{` of the hooks object, so its index
            // stays valid across the loop.
            for name in missing {
                if let arrayStart = valueStart(of: name, inObjectAt: hooksValue, bytes: bytes) {
                    guard bytes[arrayStart] == UInt8(ascii: "[") else { throw HookInstallError.unsupportedShape(name) }
                    let indent = lineIndent(bytes, at: arrayStart) + "  "
                    let merged = insert(entries: [matcherJSON(indent: indent, for: name)], into: bytes, afterOpening: arrayStart)
                    bytes = Array(merged.utf8)
                } else {
                    let indent = lineIndent(bytes, at: hooksValue) + "  "
                    let added = insert(entries: ["\"\(name)\": \(hookArrayJSON(indent: indent, for: name))"], into: bytes, afterOpening: hooksValue)
                    bytes = Array(added.utf8)
                }
            }
        } else {
            let indent = lineIndent(bytes, at: rootBrace) + "  "
            let added = insert(entries: ["\"hooks\": \(hooksObjectJSON(indent: indent))"], into: bytes, afterOpening: rootBrace)
            bytes = Array(added.utf8)
        }

        // Only once the edit is known to have worked, so a refusal leaves nothing behind.
        if existed { try backup(original, beside: target) }
        try validateAndWrite(bytes, to: target)
    }

    /// A duplicate key still parses, but Node keeps the last one and JSONSerialization
    /// the first, so both parsers have to agree on a single entry per event name.
    private static func validateAndWrite(_ bytes: [UInt8], to url: URL) throws {
        let data = Data(bytes)
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = parsed["hooks"] as? [String: Any],
              eventNames.allSatisfy({ hooks[$0] != nil }),
              let rootBrace = rootBraceIndex(bytes),
              members(ofObjectAt: rootBrace, bytes: bytes).count(where: { $0.key == "hooks" }) == 1,
              let hooksValue = valueStart(of: "hooks", inObjectAt: rootBrace, bytes: bytes),
              bytes[hooksValue] == UInt8(ascii: "{") else { throw HookInstallError.wouldCorrupt }

        let names = members(ofObjectAt: hooksValue, bytes: bytes).map(\.key)
        guard eventNames.allSatisfy({ name in names.count(where: { $0 == name }) == 1 }) else {
            throw HookInstallError.wouldCorrupt
        }

        try data.write(to: url, options: .atomic)
    }

    private static func backup(_ data: Data, beside url: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "settings.json.bak-claude-deck-\(formatter.string(from: Date()))"
        try data.write(to: url.deletingLastPathComponent().appending(path: name), options: .atomic)
    }

    private static func missingEventNames() -> [String] {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return eventNames }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return eventNames.filter { !(hooks[$0].map(containsDeckCommand) ?? false) }
    }

    private static func containsDeckCommand(_ value: Any) -> Bool {
        guard let matchers = value as? [[String: Any]] else { return false }
        return matchers.contains { matcher in
            let entries = matcher["hooks"] as? [[String: Any]] ?? []
            return entries.contains { ($0["command"] as? String)?.contains("claude-deck") == true }
        }
    }

    // MARK: - The tool spool helper

    /// Written next to the spools rather than inlined into settings.json: rotation needs
    /// several statements, and a multi-line shell command in a config file is a worse
    /// thing to hand someone than a script they can read.
    ///
    /// Parallel tool calls append concurrently, so a very large `tool_input` can interleave
    /// with another write and produce a line that will not parse. Those lines are dropped
    /// on read; a missed tool label is not worth locking for.
    private static let helperScript = """
    #!/bin/sh
    # Written by Claude Deck. Spools PreToolUse/PostToolUse payloads, one per line, and
    # keeps the file bounded because tool_input can carry the full contents of a file.
    #
    # A PreToolUse hook that exits non-zero blocks the tool call it fired for. Nothing a
    # menu bar app does is worth stopping someone's Bash call, so there is no `set -e`,
    # every step tolerates failure, and the script always exits 0.
    dir="$HOME/.claude/claude-deck"
    file="$dir/tools.jsonl"
    mkdir -p "$dir" 2>/dev/null
    { cat; printf '\\n'; } >> "$file" 2>/dev/null
    size=$(stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -gt 1000000 ]; then
      tail -c 200000 "$file" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null
    fi
    exit 0

    """

    private static func writeHelper() throws {
        try FileManager.default.createDirectory(at: EventsSpool.directory, withIntermediateDirectories: true)
        try Data(helperScript.utf8).write(to: helperURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    // MARK: - JSON fragments

    private static func matcherJSON(indent: String, for name: String) -> String {
        [
            "{",
            "\(indent)  \"hooks\": [",
            "\(indent)    {",
            "\(indent)      \"type\": \"command\",",
            "\(indent)      \"command\": \(jsonString(toolEventNames.contains(name) ? toolCommand : command)),",
            "\(indent)      \"timeout\": 5000",
            "\(indent)    }",
            "\(indent)  ]",
            "\(indent)}",
        ].joined(separator: "\n")
    }

    private static func hookArrayJSON(indent: String, for name: String) -> String {
        "[\n\(indent)  \(matcherJSON(indent: indent + "  ", for: name))\n\(indent)]"
    }

    private static func hooksObjectJSON(indent: String) -> String {
        let body = eventNames
            .map { "\(indent)  \"\($0)\": \(hookArrayJSON(indent: indent + "  ", for: $0))" }
            .joined(separator: ",\n")
        return "{\n\(body)\n\(indent)}"
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: .withoutEscapingSlashes),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    // MARK: - Text splicing

    /// Inserts entries at the head of the object or array whose opening delimiter is
    /// at `index`.
    private static func insert(entries: [String], into bytes: [UInt8], afterOpening index: Int) -> String {
        let outerIndent = lineIndent(bytes, at: index)
        let indent = outerIndent + "  "
        var after = index + 1
        while after < bytes.count, isBlank(bytes[after]) { after += 1 }
        let isEmpty = after < bytes.count && (bytes[after] == UInt8(ascii: "}") || bytes[after] == UInt8(ascii: "]"))

        var insertion = entries
            .map { "\n\(indent)\($0)" }
            .joined(separator: ",")
        insertion += isEmpty ? "\n\(outerIndent)" : ","

        let head = String(decoding: bytes[..<(index + 1)], as: UTF8.self)
        let tail = String(decoding: bytes[(index + 1)...], as: UTF8.self)
        return head + insertion + tail
    }

    private static func rootBraceIndex(_ bytes: [UInt8]) -> Int? {
        var i = 0
        while i < bytes.count, isBlank(bytes[i]) { i += 1 }
        return i < bytes.count && bytes[i] == UInt8(ascii: "{") ? i : nil
    }

    private static func valueStart(of key: String, inObjectAt brace: Int, bytes: [UInt8]) -> Int? {
        members(ofObjectAt: brace, bytes: bytes).first { $0.key == key }?.valueStart
    }

    /// Keys of the object whose `{` is at `brace`, in file order, each with the index
    /// of the first byte of its value. Duplicates are reported as they appear.
    private static func members(ofObjectAt brace: Int, bytes: [UInt8]) -> [(key: String, valueStart: Int)] {
        let quote = UInt8(ascii: "\"")
        var found: [(key: String, valueStart: Int)] = []
        var i = brace + 1
        var depth = 1

        while i < bytes.count {
            let byte = bytes[i]
            if byte == quote {
                let start = i + 1
                var end = start
                while end < bytes.count, bytes[end] != quote {
                    end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
                }
                guard end < bytes.count else { return found }
                i = end + 1

                guard depth == 1 else { continue }
                var value = i
                while value < bytes.count, isBlank(bytes[value]) { value += 1 }
                guard value < bytes.count, bytes[value] == UInt8(ascii: ":") else { continue }
                value += 1
                while value < bytes.count, isBlank(bytes[value]) { value += 1 }
                guard value < bytes.count else { return found }

                found.append((String(decoding: bytes[start..<end], as: UTF8.self), value))
                i = value
                continue
            }

            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return found }
            }
            i += 1
        }
        return found
    }

    private static func lineIndent(_ bytes: [UInt8], at index: Int) -> String {
        var start = index
        while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        var indent = ""
        var i = start
        while i < bytes.count, bytes[i] == UInt8(ascii: " ") || bytes[i] == UInt8(ascii: "\t") {
            indent.append(Character(UnicodeScalar(bytes[i])))
            i += 1
        }
        return indent
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }
}
