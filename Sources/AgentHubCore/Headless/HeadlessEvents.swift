import Foundation

/// How a terminal agent can be run without a terminal, for the chat interface.
public enum HeadlessStyle: Codable, Hashable, Sendable {
    /// Not supported; the agent only runs in a terminal.
    case none
    /// `claude -p --output-format stream-json --verbose`
    case claudeCode
    /// `codex exec --json`
    case codex
    /// `<command> <arguments…> "<prompt>"`, showing plain text output.
    /// With an empty command, the prompt itself is run as a shell command.
    case textOutput(arguments: [String])
}

/// What an agent may do when run from chat.
public enum HeadlessPermission: String, Codable, CaseIterable, Sendable {
    /// Read and answer only; edits and commands are refused.
    case readOnly
    /// Edit files in the working folder (Claude: acceptEdits, Codex: workspace-write sandbox).
    case editFiles
    /// No permission checks or sandbox. Only for trusted folders.
    case fullAccess

    public var title: String {
        switch self {
        case .readOnly: return "Read only"
        case .editFiles: return "Edit files in the folder"
        case .fullAccess: return "Full access (no sandbox)"
        }
    }
}

/// Progress from a headless agent run.
public enum HeadlessEvent: Equatable, Sendable {
    /// The agent's own session id (used to continue the conversation) and model.
    case started(sessionID: String?, model: String?)
    /// A block of the agent's reply.
    case text(String)
    /// Raw output from agents without structured output.
    case output(String)
    case toolStarted(id: String, name: String, detail: String)
    case toolFinished(id: String, output: String, isError: Bool)
    case usage(TokenUsage, model: String?)
    case finished(isError: Bool, message: String?, costUSD: Double?)
}

/// Parses `claude -p --output-format stream-json --verbose` output, one JSON object per line.
public struct ClaudeStreamParser {
    private var seenMessageIDs = Set<String>()
    private var model: String?

    public init() {}

    public mutating func parse(line: String) -> [HeadlessEvent] {
        guard let json = try? JSONValue.parse(line) else { return [] }
        switch json["type"]?.stringValue {
        case "system":
            guard json["subtype"]?.stringValue == "init" else { return [] }
            model = json["model"]?.stringValue
            return [.started(sessionID: json["session_id"]?.stringValue, model: model)]

        case "assistant":
            guard let message = json["message"] else { return [] }
            var events: [HeadlessEvent] = []
            for block in message["content"]?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue, !text.isEmpty { events.append(.text(text)) }
                case "tool_use":
                    let name = block["name"]?.stringValue ?? "tool"
                    events.append(.toolStarted(
                        id: block["id"]?.stringValue ?? UUID().uuidString,
                        name: name,
                        detail: Self.summarize(tool: name, input: block["input"] ?? [:])
                    ))
                default:
                    break
                }
            }
            // One API response can arrive as several assistant events that
            // repeat its usage; count it once.
            if let usageJSON = message["usage"] {
                let id = message["id"]?.stringValue ?? UUID().uuidString
                if seenMessageIDs.insert(id).inserted {
                    let usage = TokenUsage(
                        input: usageJSON["input_tokens"]?.intValue ?? 0,
                        output: usageJSON["output_tokens"]?.intValue ?? 0,
                        cacheRead: usageJSON["cache_read_input_tokens"]?.intValue ?? 0,
                        cacheWrite: usageJSON["cache_creation_input_tokens"]?.intValue ?? 0
                    )
                    if !usage.isEmpty { events.append(.usage(usage, model: message["model"]?.stringValue ?? model)) }
                }
            }
            return events

        case "user":
            return (json["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                guard block["type"]?.stringValue == "tool_result" else { return nil }
                return .toolFinished(
                    id: block["tool_use_id"]?.stringValue ?? "",
                    output: Self.text(of: block["content"]),
                    isError: block["is_error"]?.boolValue ?? false
                )
            }

        case "result":
            let isError = json["is_error"]?.boolValue ?? (json["subtype"]?.stringValue != "success")
            let message = isError ? (json["result"]?.stringValue ?? json["subtype"]?.stringValue ?? "The agent stopped with an error.") : nil
            return [.finished(isError: isError, message: message, costUSD: json["total_cost_usd"]?.doubleValue)]

        default:
            return []
        }
    }

    /// One line describing a tool call, e.g. the command or file path.
    static func summarize(tool: String, input: JSONValue) -> String {
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"] {
            if let value = input[key]?.stringValue, !value.isEmpty { return String(value.prefix(300)) }
        }
        let json = input.jsonString
        return json == "{}" ? "" : String(json.prefix(300))
    }

    static func text(of content: JSONValue?) -> String {
        if let text = content?.stringValue { return String(text.prefix(4000)) }
        let parts = (content?.arrayValue ?? []).compactMap { item -> String? in
            if item["type"]?.stringValue == "text" { return item["text"]?.stringValue }
            if item["type"]?.stringValue == "image" { return "[image]" }
            return nil
        }
        return String(parts.joined(separator: "\n").prefix(4000))
    }
}

/// Parses `codex exec --json` output (JSONL thread/turn/item events).
public struct CodexStreamParser {
    private var startedItems = Set<String>()

    public init() {}

    public mutating func parse(line: String) -> [HeadlessEvent] {
        guard let json = try? JSONValue.parse(line) else { return [] }
        switch json["type"]?.stringValue {
        case "thread.started":
            return [.started(sessionID: json["thread_id"]?.stringValue, model: nil)]

        case "item.started":
            guard let item = json["item"], let start = toolStart(item) else { return [] }
            startedItems.insert(start.id)
            return [start.event]

        case "item.updated", "item.completed":
            guard let item = json["item"] else { return [] }
            let id = item["id"]?.stringValue ?? UUID().uuidString
            let completed = json["type"]?.stringValue == "item.completed"
            switch item["type"]?.stringValue {
            case "agent_message":
                guard completed, let text = item["text"]?.stringValue, !text.isEmpty else { return [] }
                return [.text(text)]
            case "command_execution", "mcp_tool_call", "web_search":
                guard completed else { return [] }
                var events: [HeadlessEvent] = []
                if !startedItems.contains(id), let start = toolStart(item) { events.append(start.event) }
                startedItems.insert(id)
                let output = item["aggregated_output"]?.stringValue
                    ?? item["result"].map { ClaudeStreamParser.text(of: $0["content"] ?? $0) }
                    ?? item["error"]?["message"]?.stringValue
                    ?? ""
                let failed = item["status"]?.stringValue == "failed"
                    || (item["exit_code"]?.intValue).map { $0 != 0 } ?? false
                events.append(.toolFinished(id: id, output: String(output.prefix(4000)), isError: failed))
                return events
            case "file_change":
                guard completed else { return [] }
                let paths = (item["changes"]?.arrayValue ?? []).compactMap { change -> String? in
                    guard let path = change["path"]?.stringValue else { return nil }
                    return "\(change["kind"]?.stringValue ?? "update") \(path)"
                }
                return [
                    .toolStarted(id: id, name: "edit", detail: paths.joined(separator: ", ")),
                    .toolFinished(id: id, output: paths.joined(separator: "\n"), isError: item["status"]?.stringValue == "failed"),
                ]
            case "error":
                guard completed else { return [] }
                return [.text("⚠️ " + (item["message"]?.stringValue ?? "Error"))]
            default:
                return []
            }

        case "turn.completed":
            guard let usageJSON = json["usage"] else { return [] }
            let input = usageJSON["input_tokens"]?.intValue ?? 0
            let cached = usageJSON["cached_input_tokens"]?.intValue ?? 0
            return [.usage(TokenUsage(input: max(0, input - cached), output: usageJSON["output_tokens"]?.intValue ?? 0, cacheRead: cached), model: nil)]

        case "turn.failed":
            return [.finished(isError: true, message: json["error"]?["message"]?.stringValue ?? "The turn failed.", costUSD: nil)]

        case "error":
            return [.finished(isError: true, message: json["message"]?.stringValue ?? "Codex reported an error.", costUSD: nil)]

        default:
            return []
        }
    }

    private func toolStart(_ item: JSONValue) -> (id: String, event: HeadlessEvent)? {
        let id = item["id"]?.stringValue ?? UUID().uuidString
        switch item["type"]?.stringValue {
        case "command_execution":
            return (id, .toolStarted(id: id, name: "shell", detail: item["command"]?.stringValue ?? ""))
        case "mcp_tool_call":
            let name = [item["server"]?.stringValue, item["tool"]?.stringValue].compactMap { $0 }.joined(separator: ".")
            return (id, .toolStarted(id: id, name: name.isEmpty ? "mcp" : name, detail: item["arguments"]?.jsonString ?? ""))
        case "web_search":
            return (id, .toolStarted(id: id, name: "web_search", detail: item["query"]?.stringValue ?? ""))
        default:
            return nil
        }
    }
}

/// Plain text output, with terminal escape codes removed.
public enum TextOutputParser {
    public static func parse(line: String) -> [HeadlessEvent] {
        [.output(stripANSI(line) + "\n")]
    }

    public static func stripANSI(_ text: String) -> String {
        // CSI sequences (colors, cursor moves) and OSC sequences (titles, links).
        let patterns = ["\u{1B}\\[[0-9;?]*[ -/]*[@-~]", "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", "\u{1B}[@-Z\\\\-_]"]
        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.replacingOccurrences(of: "\r", with: "")
    }
}
