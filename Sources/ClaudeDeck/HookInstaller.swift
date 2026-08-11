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

    static let toolEventNames: Set<String> = ["PreToolUse", "PostToolUse"]

    /// Every hook goes through the helper, which records the handful of fields the menu
    /// displays and drops the rest of the payload on the floor. The event name is passed
    /// as an argument rather than parsed back out, which saves the high-frequency tool
    /// path one subprocess.
    static func command(for name: String) -> String {
        let spool = toolEventNames.contains(name) ? "tools" : "events"
        return "\"$HOME/.claude/claude-deck/spool\" \(spool) \(name)"
    }

    /// Matches every command this app has ever installed, including the pre-1.4 ones that
    /// appended the raw payload, so an upgrade can clear them out.
    static let marker = ".claude/claude-deck"

    /// Both are redirected by the tests, which must never touch the real settings file.
    /// Same escape hatch as `Launcher.iTermPath`.
    nonisolated(unsafe) static var settingsURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/settings.json")
    static var helperURL: URL { EventsSpool.directory.appending(path: "spool") }

    static var isInstalled: Bool {
        missingEventNames().isEmpty
    }

    /// True when hooks are present but were written by an older version, so the menu can
    /// offer to replace them rather than silently leaving raw payloads being spooled.
    static var hasStaleCommands: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.contains { name, value in
            commands(in: value).contains { $0.contains(marker) && $0 != command(for: name) }
        }
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

    /// Replaces whatever is installed with the current commands. This is what "Reinstall"
    /// does, and it is the upgrade path: a version that changes what the hooks record has
    /// to take the old ones out, not add itself alongside them.
    static func reinstall() throws {
        try remove()
        try install()
    }

    /// Takes every hook this app has ever installed back out, leaving anything the user
    /// put there themselves exactly where it was.
    ///
    /// Only entries this app wrote are touched: a matcher is removed when it carries a
    /// command mentioning our directory, an event array is removed only if emptying it is
    /// what left it empty, and `hooks` itself only if it was ours alone.
    static func remove() throws {
        let target = settingsURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard let original = try? Data(contentsOf: target) else { throw HookInstallError.unreadable }

        var bytes = Array(original)
        guard rootBraceIndex(bytes) != nil else { throw HookInstallError.notAnObject }

        var touched: Set<String> = []
        while let (range, event) = nextMatcher(in: bytes) {
            bytes = removing(range, from: bytes)
            touched.insert(event)
        }
        guard !touched.isEmpty else { return }

        for event in touched {
            guard let range = emptiedEvent(event, in: bytes) else { continue }
            bytes = removing(range, from: bytes)
        }
        if let range = emptiedHooks(in: bytes) {
            bytes = removing(range, from: bytes)
        }

        try backup(original, beside: target)

        let data = Data(bytes)
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallError.wouldCorrupt
        }
        let hooks = parsed["hooks"] as? [String: Any] ?? [:]
        guard !hooks.values.contains(where: { commands(in: $0).contains { $0.contains(marker) } }) else {
            throw HookInstallError.wouldCorrupt
        }
        try data.write(to: target, options: .atomic)
    }

    /// The next matcher object belonging to this app, with the event it sits under.
    private static func nextMatcher(in bytes: [UInt8]) -> (range: Range<Int>, event: String)? {
        guard let rootBrace = rootBraceIndex(bytes),
              let hooksValue = valueStart(of: "hooks", inObjectAt: rootBrace, bytes: bytes),
              bytes[hooksValue] == UInt8(ascii: "{") else { return nil }

        for event in members(ofObjectAt: hooksValue, bytes: bytes) {
            guard bytes[event.valueStart] == UInt8(ascii: "[") else { continue }
            for element in elements(ofArrayAt: event.valueStart, bytes: bytes)
            where String(decoding: bytes[element], as: UTF8.self).contains(marker) {
                return (element, event.key)
            }
        }
        return nil
    }

    private static func emptiedEvent(_ name: String, in bytes: [UInt8]) -> Range<Int>? {
        guard let rootBrace = rootBraceIndex(bytes),
              let hooksValue = valueStart(of: "hooks", inObjectAt: rootBrace, bytes: bytes),
              bytes[hooksValue] == UInt8(ascii: "{"),
              let event = members(ofObjectAt: hooksValue, bytes: bytes).first(where: { $0.key == name }),
              bytes[event.valueStart] == UInt8(ascii: "["),
              elements(ofArrayAt: event.valueStart, bytes: bytes).isEmpty else { return nil }
        return event.keyStart..<endOfValue(at: event.valueStart, bytes: bytes)
    }

    private static func emptiedHooks(in bytes: [UInt8]) -> Range<Int>? {
        guard let rootBrace = rootBraceIndex(bytes),
              let hooks = members(ofObjectAt: rootBrace, bytes: bytes).first(where: { $0.key == "hooks" }),
              bytes[hooks.valueStart] == UInt8(ascii: "{"),
              members(ofObjectAt: hooks.valueStart, bytes: bytes).isEmpty else { return nil }
        return hooks.keyStart..<endOfValue(at: hooks.valueStart, bytes: bytes)
    }

    /// Deletes a range along with the one comma that held it in place, and the blank line
    /// it would otherwise leave behind.
    private static func removing(_ range: Range<Int>, from bytes: [UInt8]) -> [UInt8] {
        var start = range.lowerBound
        var end = range.upperBound

        var after = end
        while after < bytes.count, isBlank(bytes[after]) { after += 1 }
        if after < bytes.count, bytes[after] == UInt8(ascii: ",") {
            end = after + 1
        } else {
            var before = start
            while before > 0, isBlank(bytes[before - 1]) { before -= 1 }
            if before > 0, bytes[before - 1] == UInt8(ascii: ",") { start = before - 1 }
        }

        var lineStart = start
        while lineStart > 0, bytes[lineStart - 1] == UInt8(ascii: " ") || bytes[lineStart - 1] == UInt8(ascii: "\t") {
            lineStart -= 1
        }
        if lineStart > 0, bytes[lineStart - 1] == UInt8(ascii: "\n") {
            var tail = end
            while tail < bytes.count, bytes[tail] == UInt8(ascii: " ") || bytes[tail] == UInt8(ascii: "\t") {
                tail += 1
            }
            if tail < bytes.count, bytes[tail] == UInt8(ascii: "\n") {
                start = lineStart
                end = tail + 1
            }
        }

        var result = bytes
        result.removeSubrange(start..<end)
        return result
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
        // Exact match, not "mentions claude-deck": an old command still spooling raw
        // payloads must read as missing so that reinstalling replaces it.
        return eventNames.filter { name in
            !(hooks[name].map { commands(in: $0).contains(command(for: name)) } ?? false)
        }
    }

    static func commands(in value: Any) -> [String] {
        guard let matchers = value as? [[String: Any]] else { return [] }
        return matchers.flatMap { matcher in
            (matcher["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
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
    # Written by Claude Deck. Usage: spool <events|tools> <EventName>
    #
    # Records only the fields the menu bar app actually displays. Your prompts, tool
    # inputs and tool results are read from the hook payload and thrown away: they are
    # never written anywhere. Delete this file and the hooks in ~/.claude/settings.json
    # to stop it entirely.
    #
    # A PreToolUse hook that exits non-zero blocks the tool call it fired for. Nothing a
    # menu bar app does is worth stopping someone's Bash call, so there is no `set -e`,
    # every step tolerates failure, and the script always exits 0.
    umask 077
    dir="$HOME/.claude/claude-deck"
    file="$dir/$1.jsonl"
    event="$2"
    mkdir -p "$dir" 2>/dev/null

    payload=$(cat)
    field() {
      printf '%s' "$payload" | plutil -extract "$1" raw -o - - 2>/dev/null
    }

    # session_id is a UUID and tool_name an identifier, so neither can carry a quote or a
    # backslash and both are safe to place into JSON as they are. If a future version
    # breaks that, the line fails to parse and is dropped on read — it never leaks.
    line="{\\"hook_event_name\\":\\"$event\\""
    session=$(field session_id)
    if [ -n "$session" ]; then
      line="$line,\\"session_id\\":\\"$session\\""
    fi

    case "$event" in
      PreToolUse|PostToolUse)
        tool=$(field tool_name)
        if [ -n "$tool" ]; then
          line="$line,\\"tool_name\\":\\"$tool\\""
        fi
        ;;
      Notification|StopFailure)
        # The only free text kept, and only because it is what the row and the banner say.
        # Written by Claude Code rather than by you: "Claude needs your permission to run
        # Bash". Flattened, stripped of control characters, capped, then escaped.
        message=$(field message \\
          | tr '\\n\\r\\t' '   ' \\
          | LC_ALL=C tr -d '\\000-\\037' \\
          | cut -c1-200 \\
          | sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g')
        if [ -n "$message" ]; then
          line="$line,\\"message\\":\\"$message\\""
        fi
        ;;
    esac

    printf '%s}\\n' "$line" >> "$file" 2>/dev/null

    size=$(stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -gt 262144 ]; then
      tail -c 65536 "$file" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null
    fi
    exit 0

    """

    private static func writeHelper() throws {
        try FileManager.default.createDirectory(
            at: EventsSpool.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Also applied to a directory that already exists from an earlier version, which
        // was created with the default 0755.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: EventsSpool.directory.path)
        try Data(helperScript.utf8).write(to: helperURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
    }

    // MARK: - JSON fragments

    private static func matcherJSON(indent: String, for name: String) -> String {
        [
            "{",
            "\(indent)  \"hooks\": [",
            "\(indent)    {",
            "\(indent)      \"type\": \"command\",",
            "\(indent)      \"command\": \(jsonString(command(for: name))),",
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

    /// The index one past the end of the JSON value starting at `index`.
    private static func endOfValue(at index: Int, bytes: [UInt8]) -> Int {
        let quote = UInt8(ascii: "\"")
        guard index < bytes.count else { return index }

        if bytes[index] == quote {
            var i = index + 1
            while i < bytes.count, bytes[i] != quote {
                i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1
            }
            return min(i + 1, bytes.count)
        }

        if bytes[index] == UInt8(ascii: "{") || bytes[index] == UInt8(ascii: "[") {
            var depth = 0
            var i = index
            while i < bytes.count {
                let byte = bytes[i]
                if byte == quote {
                    i = endOfValue(at: i, bytes: bytes)
                    continue
                }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    depth += 1
                } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return i
        }

        var i = index
        while i < bytes.count, !isBlank(bytes[i]),
              bytes[i] != UInt8(ascii: ","), bytes[i] != UInt8(ascii: "}"), bytes[i] != UInt8(ascii: "]") {
            i += 1
        }
        return i
    }

    /// Byte ranges of the top-level elements of the array whose `[` is at `index`.
    private static func elements(ofArrayAt index: Int, bytes: [UInt8]) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var i = index + 1
        while i < bytes.count {
            while i < bytes.count, isBlank(bytes[i]) { i += 1 }
            guard i < bytes.count, bytes[i] != UInt8(ascii: "]") else { break }
            let end = endOfValue(at: i, bytes: bytes)
            guard end > i else { break }
            found.append(i..<end)
            i = end
            while i < bytes.count, isBlank(bytes[i]) { i += 1 }
            if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i += 1 }
        }
        return found
    }

    /// Keys of the object whose `{` is at `brace`, in file order, each with the index
    /// of the first byte of its value. Duplicates are reported as they appear.
    private static func members(ofObjectAt brace: Int, bytes: [UInt8]) -> [(key: String, keyStart: Int, valueStart: Int)] {
        let quote = UInt8(ascii: "\"")
        var found: [(key: String, keyStart: Int, valueStart: Int)] = []
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

                found.append((String(decoding: bytes[start..<end], as: UTF8.self), start - 1, value))
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
