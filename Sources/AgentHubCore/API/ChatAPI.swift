import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ChatAPIError: Error, LocalizedError, Equatable {
    case missingAPIKey(String)
    case invalidConfiguration(String)
    case http(status: Int, message: String)
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case let .missingAPIKey(provider): return "No API key saved for \(provider). Add one in Settings → API Keys."
        case let .invalidConfiguration(message): return message
        case let .http(status, message): return "HTTP \(status): \(message)"
        case let .provider(message): return message
        }
    }
}

/// Builds provider requests from a provider-native transcript.
///
/// The transcript is the list of `messages` in the provider's own format, so
/// tool calls, tool results, and Claude's thinking blocks round-trip exactly
/// as the API returned them (the API requires thinking blocks to be passed
/// back unchanged during tool use).
public enum ChatProtocol {
    public static let anthropicVersion = "2023-06-01"
    /// Models that accept server-side refusal fallbacks (`fallbacks: "default"`).
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    /// The native form of a user message.
    public static func userMessage(_ text: String) -> JSONValue {
        ["role": "user", "content": .string(text)]
    }

    public static func makeRequest(
        agent: AgentDefinition,
        transcript: [JSONValue],
        tools: [ToolSpec] = [],
        apiKey: String?,
        maxTokens: Int = 64000
    ) throws -> URLRequest {
        guard let provider = agent.provider else {
            throw ChatAPIError.invalidConfiguration("\(agent.name) has no API provider set.")
        }
        guard let model = nonEmpty(agent.model) else {
            throw ChatAPIError.invalidConfiguration("\(agent.name) has no model set.")
        }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch provider {
        case .anthropic:
            if key.isEmpty { throw ChatAPIError.missingAPIKey(provider.displayName) }
            var request = try post(nonEmpty(agent.baseURL) ?? "https://api.anthropic.com", path: "/v1/messages")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

            var body: [String: JSONValue] = [
                "model": .string(model),
                "max_tokens": .number(Double(maxTokens)),
                "stream": true,
                "messages": .array(transcript),
            ]
            if let system = nonEmpty(agent.systemPrompt) { body["system"] = .string(system) }
            if !tools.isEmpty {
                body["tools"] = .array(tools.map { tool in
                    [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "input_schema": tool.inputSchema,
                        // Stream tool input as it is generated; inputs are
                        // validated before any tool runs.
                        "eager_input_streaming": true,
                    ]
                })
            }
            // On a safety decline, let the API re-run the request on a suitable
            // fallback model. Only the first-party API supports this.
            if fallbackModels.contains(model), nonEmpty(agent.baseURL) == nil {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
            request.httpBody = try JSONValue.object(body).data()
            return request

        case .openai, .openaiCompatible:
            if provider == .openai, key.isEmpty { throw ChatAPIError.missingAPIKey(provider.displayName) }
            let base: String
            if provider == .openai {
                base = nonEmpty(agent.baseURL) ?? "https://api.openai.com/v1"
            } else {
                guard let url = nonEmpty(agent.baseURL) else {
                    throw ChatAPIError.invalidConfiguration("\(agent.name) needs a base URL, e.g. http://localhost:11434/v1")
                }
                base = url
            }
            var request = try post(base, path: "/chat/completions")
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

            var messages: [JSONValue] = []
            if let system = nonEmpty(agent.systemPrompt) { messages.append(["role": "system", "content": .string(system)]) }
            messages += transcript
            var body: [String: JSONValue] = [
                "model": .string(model),
                "stream": true,
                "stream_options": ["include_usage": true],
                "messages": .array(messages),
            ]
            if !tools.isEmpty {
                body["tools"] = .array(tools.map { tool in
                    [
                        "type": "function",
                        "function": [
                            "name": .string(tool.name),
                            "description": .string(tool.description),
                            "parameters": tool.inputSchema,
                        ],
                    ]
                })
            }
            request.httpBody = try JSONValue.object(body).data()
            return request
        }
    }

    /// Extracts a readable message from an error response body.
    public static func errorMessage(from body: String) -> String {
        if let json = try? JSONValue.parse(body), let message = json["error"]?["message"]?.stringValue {
            return message
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No details." : String(trimmed.prefix(500))
    }

    private static func post(_ base: String, path: String) throws -> URLRequest {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + path), url.scheme == "https" || url.scheme == "http" else {
            throw ChatAPIError.invalidConfiguration("Invalid base URL: \(base)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        return request
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Streams Server-Sent Events from an HTTP request.
public struct SSEClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func events(for request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request) { _ = continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(FoundationNetworking)
    // swift-corelibs-foundation has no byte streaming: read the whole body, then parse.
    private func run(_ request: URLRequest, emit: (SSEEvent) -> Void) async throws {
        let (data, response) = try await HTTP.data(for: request, session: session)
        let body = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatAPIError.http(status: http.statusCode, message: ChatProtocol.errorMessage(from: body))
        }
        SSEParser.parseAll(body).forEach(emit)
    }
    #else
    private func run(_ request: URLRequest, emit: (SSEEvent) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw ChatAPIError.http(status: http.statusCode, message: ChatProtocol.errorMessage(from: body))
        }
        var parser = SSEParser()
        // `AsyncLineSequence` drops blank lines, which is how SSE normally ends an
        // event, so dispatch after each `data:` line instead. Both providers put a
        // whole JSON payload on a single data line.
        for try await line in bytes.lines {
            try Task.checkCancellation()
            _ = parser.feed(line: line)
            if line.hasPrefix("data:"), let event = parser.feed(line: "") { emit(event) }
        }
    }
    #endif
}
