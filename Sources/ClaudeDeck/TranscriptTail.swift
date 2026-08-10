import Foundation

/// Reads the newest assistant message out of a session transcript
/// (~/.claude/projects/<project>/<sessionId>.jsonl). Those files reach tens of
/// megabytes, so the reader seeks backwards from EOF in chunks and gives up after
/// `maxScanBytes`. Results are cached per session and invalidated by file size.
actor TranscriptTail {
    private static let chunkSize = 64 * 1024
    private static let maxScanBytes = 2 * 1024 * 1024
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)

    private var paths: [String: URL] = [:]
    private var cache: [String: (size: Int, usage: TranscriptUsage)] = [:]

    func usage(for sessionId: String) -> TranscriptUsage? {
        guard let url = path(for: sessionId) else { return nil }
        guard let size = url.currentFileSize else { return nil }

        if let cached = cache[sessionId], cached.size == size { return cached.usage }
        guard let usage = scan(url: url, size: size) else { return nil }
        cache[sessionId] = (size, usage)
        return usage
    }

    func forget(sessionIds: Set<String>) {
        paths = paths.filter { sessionIds.contains($0.key) }
        cache = cache.filter { sessionIds.contains($0.key) }
    }

    private func path(for sessionId: String) -> URL? {
        if let known = paths[sessionId], FileManager.default.fileExists(atPath: known.path) { return known }

        let projects = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let candidate = dir.appending(path: "\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                paths[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    /// Reads with `pread`: `FileHandle.read(upToCount:)` permanently grows the process
    /// footprint by about the number of bytes it returns, and this runs on every status
    /// change.
    private func scan(url: URL, size: Int) -> TranscriptUsage? {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var offset = size
        var scanned = 0
        var trailing = Data()
        var scratch = [UInt8](repeating: 0, count: Self.chunkSize)

        while offset > 0 && scanned < Self.maxScanBytes {
            let length = min(Self.chunkSize, offset)
            offset -= length
            let got = scratch.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, length, off_t(offset)) }
            guard got == length else { return nil }
            let chunk = Data(scratch[0..<got])
            scanned += length

            var lines = (chunk + trailing).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // The first slice is a partial line unless we reached the start of the file.
            trailing = offset > 0 ? Data(lines.removeFirst()) : Data()

            for line in lines.reversed() where line.range(of: Self.assistantMarker) != nil {
                if let usage = decode(line: Data(line)) { return usage }
            }
        }
        return nil
    }

    private func decode(line: Data) -> TranscriptUsage? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let entry = try? decoder.decode(AssistantLine.self, from: line),
              entry.type == "assistant",
              let usage = entry.message?.usage else { return nil }

        let used = (usage.inputTokens ?? 0)
            + (usage.cacheCreationInputTokens ?? 0)
            + (usage.cacheReadInputTokens ?? 0)
        guard used > 0 else { return nil }
        return TranscriptUsage(model: entry.message?.model, contextUsed: used)
    }

    /// 1M-context runs report the same model string as 200k runs, so the window is
    /// inferred from the configured model plus the observed usage.
    static func contextWindow(used: Int, oneMillionConfigured: Bool) -> Int {
        (oneMillionConfigured || used > 200_000) ? 1_000_000 : 200_000
    }

    static func oneMillionConfigured() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? String else { return false }
        return model.contains("[1m]")
    }
}

/// One line of a transcript. Also used by `Stats`, which needs the timestamp and the
/// output tokens.
struct AssistantLine: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?
        }
        var id: String?
        var model: String?
        var usage: Usage?
    }
    var type: String?
    var timestamp: String?
    var message: Message?
}
