import Foundation

/// A tool call the model made in one turn.
public struct ToolCall: Hashable, Sendable {
    public var id: String
    public var name: String
    /// The raw JSON text the model produced for the arguments.
    public var rawArguments: String
    /// Parsed arguments, or nil when `rawArguments` isn't a JSON object.
    public var arguments: JSONValue?
}

/// What one streamed model turn produced.
public struct TurnResult: Sendable {
    /// The assistant message, in the provider's native format, to append to the transcript.
    public var assistantMessage: JSONValue
    public var toolCalls: [ToolCall]
    public var stopReason: String?
    public var usage: TokenUsage
    public var model: String?
}

/// Incremental output while a turn streams.
public enum StreamOutput: Equatable, Sendable {
    case text(String)
    case notice(String)
}

/// Rebuilds an Anthropic Messages API response from its stream events.
public struct AnthropicTurnAccumulator {
    private var blocks: [Int: [String: JSONValue]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var stopReason: String?
    private var usage = TokenUsage()
    private var model: String?

    public init() {}

    /// Consumes one event; returns text to show. Throws on a stream error event.
    public mutating func consume(_ event: SSEEvent) throws -> [StreamOutput] {
        guard let json = try? JSONValue.parse(event.data) else { return [] }
        switch json["type"]?.stringValue {
        case "error":
            throw ChatAPIError.provider(json["error"]?["message"]?.stringValue ?? "The API returned an error.")

        case "message_start":
            model = json["message"]?["model"]?.stringValue ?? model
            if let usageJSON = json["message"]?["usage"] { usage = usage.merged(with: Self.usage(usageJSON)) }

        case "content_block_start":
            guard let index = json["index"]?.intValue, let block = json["content_block"]?.objectValue else { break }
            blocks[index] = block
            if block["type"]?.stringValue == "tool_use" { partialJSON[index] = "" }

        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"], var block = blocks[index] else { break }
            var output: [StreamOutput] = []
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                block["text"] = .string((block["text"]?.stringValue ?? "") + text)
                output.append(.text(text))
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            case "thinking_delta":
                block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + (delta["thinking"]?.stringValue ?? ""))
            case "signature_delta":
                block["signature"] = delta["signature"] ?? block["signature"]
            case "citations_delta":
                if let citation = delta["citation"] {
                    block["citations"] = .array((block["citations"]?.arrayValue ?? []) + [citation])
                }
            default:
                break
            }
            blocks[index] = block
            return output

        case "message_delta":
            stopReason = json["delta"]?["stop_reason"]?.stringValue ?? stopReason
            if let usageJSON = json["usage"] { usage = usage.merged(with: Self.usage(usageJSON)) }
            switch stopReason {
            case "refusal": return [.notice("The model declined to continue this request.")]
            case "max_tokens": return [.notice("Reply stopped at the output token limit.")]
            default: break
            }

        default:
            break
        }
        return []
    }

    public func result() -> TurnResult {
        var content: [JSONValue] = []
        var calls: [ToolCall] = []
        for index in blocks.keys.sorted() {
            guard var block = blocks[index] else { continue }
            if block["type"]?.stringValue == "tool_use" {
                let raw = partialJSON[index] ?? ""
                let parsed: JSONValue? = raw.trimmingCharacters(in: .whitespaces).isEmpty
                    ? .object([:])
                    : (try? JSONValue.parse(raw)).flatMap { $0.objectValue != nil ? $0 : nil }
                // The transcript needs a valid object even when the model's JSON was broken.
                block["input"] = parsed ?? .object([:])
                calls.append(ToolCall(
                    id: block["id"]?.stringValue ?? "",
                    name: block["name"]?.stringValue ?? "",
                    rawArguments: raw,
                    arguments: parsed
                ))
            }
            content.append(.object(block))
        }
        return TurnResult(
            assistantMessage: ["role": "assistant", "content": .array(content)],
            toolCalls: calls,
            stopReason: stopReason,
            usage: usage,
            model: model
        )
    }

    static func usage(_ json: JSONValue) -> TokenUsage {
        TokenUsage(
            input: json["input_tokens"]?.intValue ?? 0,
            output: json["output_tokens"]?.intValue ?? 0,
            cacheRead: json["cache_read_input_tokens"]?.intValue ?? 0,
            cacheWrite: json["cache_creation_input_tokens"]?.intValue ?? 0
        )
    }

    /// The user message carrying tool results back to Claude.
    public static func toolResultsMessage(_ results: [(id: String, result: ToolResult)]) -> JSONValue {
        [
            "role": "user",
            "content": .array(results.map { item in
                [
                    "type": "tool_result",
                    "tool_use_id": .string(item.id),
                    "content": .string(item.result.text.isEmpty ? "(no output)" : item.result.text),
                    "is_error": .bool(item.result.isError),
                ]
            }),
        ]
    }
}

/// Rebuilds an OpenAI chat-completions response from its stream chunks.
public struct OpenAITurnAccumulator {
    private struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var text = ""
    private var calls: [Int: PartialCall] = [:]
    private var finishReason: String?
    private var usage = TokenUsage()
    private var model: String?

    public init() {}

    public mutating func consume(_ event: SSEEvent) throws -> [StreamOutput] {
        if event.data == "[DONE]" { return [] }
        guard let json = try? JSONValue.parse(event.data) else { return [] }
        if let error = json["error"] {
            throw ChatAPIError.provider(error["message"]?.stringValue ?? "The API returned an error.")
        }
        model = json["model"]?.stringValue ?? model
        if let usageJSON = json["usage"], !usageJSON.isNull {
            let prompt = usageJSON["prompt_tokens"]?.intValue ?? 0
            let cached = usageJSON["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
            usage = usage.merged(with: TokenUsage(
                input: max(0, prompt - cached),
                output: usageJSON["completion_tokens"]?.intValue ?? 0,
                cacheRead: cached
            ))
        }

        guard let choice = json["choices"]?[0] else { return [] }
        var output: [StreamOutput] = []
        if let delta = choice["delta"] {
            if let chunk = delta["content"]?.stringValue, !chunk.isEmpty {
                text += chunk
                output.append(.text(chunk))
            }
            for call in delta["tool_calls"]?.arrayValue ?? [] {
                let index = call["index"]?.intValue ?? 0
                var partial = calls[index] ?? PartialCall()
                if let id = call["id"]?.stringValue, !id.isEmpty { partial.id = id }
                if let name = call["function"]?["name"]?.stringValue { partial.name += name }
                if let args = call["function"]?["arguments"]?.stringValue { partial.arguments += args }
                calls[index] = partial
            }
        }
        if let reason = choice["finish_reason"]?.stringValue {
            finishReason = reason
            if reason == "length" { output.append(.notice("Reply stopped at the output token limit.")) }
            if reason == "content_filter" { output.append(.notice("The provider filtered this reply.")) }
        }
        return output
    }

    public func result() -> TurnResult {
        let ordered = calls.keys.sorted().compactMap { calls[$0] }
        var message: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
        if !ordered.isEmpty {
            message["tool_calls"] = .array(ordered.map { call in
                ["id": .string(call.id), "type": "function", "function": ["name": .string(call.name), "arguments": .string(call.arguments)]]
            })
        }
        let toolCalls = ordered.map { call -> ToolCall in
            let raw = call.arguments
            let parsed: JSONValue? = raw.trimmingCharacters(in: .whitespaces).isEmpty
                ? .object([:])
                : (try? JSONValue.parse(raw)).flatMap { $0.objectValue != nil ? $0 : nil }
            return ToolCall(id: call.id, name: call.name, rawArguments: raw, arguments: parsed)
        }
        return TurnResult(
            assistantMessage: .object(message),
            toolCalls: toolCalls,
            stopReason: finishReason == "tool_calls" ? "tool_use" : finishReason,
            usage: usage,
            model: model
        )
    }

    public static func toolResultMessages(_ results: [(id: String, result: ToolResult)]) -> [JSONValue] {
        results.map { item in
            [
                "role": "tool",
                "tool_call_id": .string(item.id),
                "content": .string(item.result.isError ? "Error: \(item.result.text)" : (item.result.text.isEmpty ? "(no output)" : item.result.text)),
            ]
        }
    }
}

/// Lightweight check of tool arguments against the top level of a JSON schema:
/// arguments must be an object and contain every required property.
public enum ToolInputValidator {
    public static func problem(with arguments: JSONValue?, schema: JSONValue) -> String? {
        guard let object = arguments?.objectValue else { return "Arguments were not a valid JSON object." }
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let missing = required.filter { object[$0] == nil }
        return missing.isEmpty ? nil : "Missing required argument(s): \(missing.joined(separator: ", "))."
    }
}
