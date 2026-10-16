import Foundation

/// A usage record read from an agent's local log, with a key for de-duplication.
public struct LoggedUsage: Hashable, Sendable {
    /// Identifies one API call across log files (agents can copy history into
    /// new files when a session is resumed). nil when the log has no stable id.
    public var dedupKey: String?
    public var record: UsageRecord
}

enum LogDates {
    // Formatters are expensive to create; parsing with a shared one is thread-safe.
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}

/// Calls `body` with each line of a file, reading it in 1 MB chunks so large
/// logs never have to fit in memory at once.
enum LineReader {
    static func forEachLine(in url: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
                if newline > start { body(Data(buffer[start..<newline])) }
                start = buffer.index(after: newline)
            }
            buffer = Data(buffer[start...])
        }
        if !buffer.isEmpty { body(buffer) }
    }

    static func lines(of contents: String) -> [Data] {
        contents.split(separator: "\n", omittingEmptySubsequences: true).map { Data($0.utf8) }
    }
}

private extension Data {
    func contains(_ text: String) -> Bool { range(of: Data(text.utf8)) != nil }
}

/// Reads token usage from Claude Code's session transcripts
/// (`~/.claude/projects/<project>/<session>.jsonl`).
///
/// Each assistant entry carries the API response's `usage`. One API response
/// can be split over several entries (one per content block) that repeat the
/// same usage, so entries are keyed by message id + request id.
public enum ClaudeCodeLogParser {
    public static let source = "Claude Code"

    /// Only the fields needed; the decoder skips everything else on the line.
    private struct Line: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation_input_tokens: Int?
        }
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    struct Accumulator {
        private(set) var results: [LoggedUsage] = []
        private var seen = Set<String>()
        private let decoder = JSONDecoder()

        mutating func consume(_ line: Data) {
            // Cheap byte checks first: most lines (user turns, tool output) have no usage.
            guard line.contains("\"usage\""), line.contains("\"assistant\""),
                  let entry = try? decoder.decode(Line.self, from: line),
                  entry.type == "assistant",
                  let message = entry.message,
                  let usageJSON = message.usage,
                  let model = message.model, model != "<synthetic>",
                  let date = LogDates.parse(entry.timestamp)
            else { return }

            let usage = TokenUsage(
                input: usageJSON.input_tokens ?? 0,
                output: usageJSON.output_tokens ?? 0,
                cacheRead: usageJSON.cache_read_input_tokens ?? 0,
                cacheWrite: usageJSON.cache_creation_input_tokens ?? 0
            )
            guard !usage.isEmpty else { return }

            var key: String?
            if let messageID = message.id {
                let id = messageID + ":" + (entry.requestId ?? "")
                guard seen.insert(id).inserted else { return }
                key = id
            }
            results.append(LoggedUsage(dedupKey: key, record: UsageRecord(source: source, model: model, date: date, usage: usage)))
        }
    }

    public static func parse(_ contents: String) -> [LoggedUsage] {
        var accumulator = Accumulator()
        LineReader.lines(of: contents).forEach { accumulator.consume($0) }
        return accumulator.results
    }

    static func parse(file: URL) -> [LoggedUsage] {
        var accumulator = Accumulator()
        LineReader.forEachLine(in: file) { accumulator.consume($0) }
        return accumulator.results
    }
}

/// Reads token usage from Codex CLI session logs
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
///
/// Codex logs `token_count` events with a running `total_token_usage`; each
/// record is the increase since the previous event, which is robust to
/// repeated events. The model comes from the latest `turn_context`.
public enum CodexLogParser {
    public static let source = "Codex"

    struct Accumulator {
        let fileKey: String
        private(set) var results: [LoggedUsage] = []
        private var model = "gpt-5"
        private var previous: TokenUsage?
        private var eventIndex = 0

        init(fileKey: String) {
            self.fileKey = fileKey
        }

        mutating func consume(_ line: Data) {
            // Only model changes and token counts matter.
            let isContext = line.contains("\"turn_context\"")
            guard isContext || line.contains("\"token_count\""),
                  let json = try? JSONValue.parse(line) else { return }
            let payload = json["payload"]

            if let newModel = payload?["model"]?.stringValue, !newModel.isEmpty {
                model = newModel
                return
            }
            guard json["type"]?.stringValue == "event_msg",
                  payload?["type"]?.stringValue == "token_count",
                  let info = payload?["info"], !info.isNull,
                  let date = LogDates.parse(json["timestamp"]?.stringValue)
            else { return }

            let delta: TokenUsage
            if let totalJSON = info["total_token_usage"] {
                let total = CodexLogParser.codexUsage(totalJSON)
                if let previous, total.total >= previous.total {
                    delta = TokenUsage(
                        input: total.input - previous.input,
                        output: total.output - previous.output,
                        cacheRead: total.cacheRead - previous.cacheRead,
                        cacheWrite: 0
                    )
                } else if previous == nil {
                    delta = total
                } else {
                    // Counter went backwards (new conversation in the same file).
                    delta = info["last_token_usage"].map(CodexLogParser.codexUsage) ?? total
                }
                previous = total
            } else if let last = info["last_token_usage"] {
                delta = CodexLogParser.codexUsage(last)
            } else {
                return
            }

            eventIndex += 1
            guard !delta.isEmpty, delta.input >= 0, delta.output >= 0, delta.cacheRead >= 0 else { return }
            results.append(LoggedUsage(
                dedupKey: fileKey.isEmpty ? nil : "\(fileKey)#\(eventIndex)",
                record: UsageRecord(source: source, model: model, date: date, usage: delta)
            ))
        }
    }

    public static func parse(_ contents: String, fileKey: String = "") -> [LoggedUsage] {
        var accumulator = Accumulator(fileKey: fileKey)
        LineReader.lines(of: contents).forEach { accumulator.consume($0) }
        return accumulator.results
    }

    static func parse(file: URL) -> [LoggedUsage] {
        var accumulator = Accumulator(fileKey: file.path)
        LineReader.forEachLine(in: file) { accumulator.consume($0) }
        return accumulator.results
    }

    /// Codex counts cached tokens inside `input_tokens`; split them out.
    static func codexUsage(_ json: JSONValue) -> TokenUsage {
        let input = json["input_tokens"]?.intValue ?? 0
        let cached = json["cached_input_tokens"]?.intValue ?? 0
        return TokenUsage(
            input: max(0, input - cached),
            output: json["output_tokens"]?.intValue ?? 0,
            cacheRead: cached
        )
    }
}

/// Finds and parses agent logs on disk, re-reading only files that changed.
public final class AgentLogScanner: @unchecked Sendable {
    public struct Roots: Sendable {
        public var claudeProjects: [URL]
        public var codexSessions: [URL]

        public init(claudeProjects: [URL], codexSessions: [URL]) {
            self.claudeProjects = claudeProjects
            self.codexSessions = codexSessions
        }

        /// Default locations, honoring `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.
        public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> Roots {
            var claude = [
                home.appendingPathComponent(".claude/projects"),
                home.appendingPathComponent(".config/claude/projects"),
            ]
            if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
                claude += dir.split(separator: ",").map { URL(fileURLWithPath: String($0)).appendingPathComponent("projects") }
            }
            var codex = [home.appendingPathComponent(".codex/sessions")]
            if let dir = environment["CODEX_HOME"], !dir.isEmpty {
                codex.append(URL(fileURLWithPath: dir).appendingPathComponent("sessions"))
            }
            return Roots(claudeProjects: claude, codexSessions: codex)
        }
    }

    private struct CacheEntry {
        var modified: Date
        var size: Int
        var usage: [LoggedUsage]
    }

    private let roots: Roots
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    public init(roots: Roots = .standard()) {
        self.roots = roots
    }

    /// All records from log files modified on or after `since`, de-duplicated.
    /// Blocking file IO: call off the main thread.
    public func scan(since: Date) -> [UsageRecord] {
        var all: [LoggedUsage] = []
        var visited = Set<String>()
        for root in roots.claudeProjects {
            for file in jsonlFiles(under: root, modifiedSince: since) where visited.insert(file.path).inserted {
                all += cached(file) { ClaudeCodeLogParser.parse(file: $0) }
            }
        }
        for root in roots.codexSessions {
            for file in jsonlFiles(under: root, modifiedSince: since) where visited.insert(file.path).inserted {
                all += cached(file) { CodexLogParser.parse(file: $0) }
            }
        }

        var seen = Set<String>()
        return all.compactMap { item in
            if let key = item.dedupKey {
                guard seen.insert(key).inserted else { return nil }
            }
            return item.record.date >= since ? item.record : nil
        }
    }

    private func cached(_ file: URL, parse: (URL) -> [LoggedUsage]) -> [LoggedUsage] {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? 0

        lock.lock()
        let hit = cache[file.path]
        lock.unlock()
        if let hit, hit.modified == modified, hit.size == size { return hit.usage }

        let usage = parse(file)
        lock.lock()
        cache[file.path] = CacheEntry(modified: modified, size: size, usage: usage)
        lock.unlock()
        return usage
    }

    private func jsonlFiles(under root: URL, modifiedSince since: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) >= since else { continue }
            files.append(url)
        }
        return files
    }
}
