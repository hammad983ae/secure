import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A piece of a streamed model reply.
public enum StreamChunk: Equatable, Sendable {
    /// Text to append to the assistant's reply.
    case text(String)
    /// Something the user should know that isn't model text (refusal, truncation).
    case notice(String)
}

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

/// Builds HTTP requests and decodes streamed events for each provider.
/// Pure functions, so they are unit tested without the network.
public enum ChatProtocol {
    public static let anthropicVersion = "2023-06-01"
    /// Models that accept server-side refusal fallbacks (`fallbacks: "default"`).
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    public static func makeRequest(agent: AgentDefinition, history: [ChatMessage], apiKey: String?) throws -> URLRequest {
        guard let provider = agent.provider else {
            throw ChatAPIError.invalidConfiguration("\(agent.name) has no API provider set.")
        }
        guard let model = agent.model, !model.isEmpty else {
            throw ChatAPIError.invalidConfiguration("\(agent.name) has no model set.")
        }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch provider {
        case .anthropic:
            if key.isEmpty { throw ChatAPIError.missingAPIKey(provider.displayName) }
            let base = nonEmpty(agent.baseURL) ?? "https://api.anthropic.com"
            var request = try post(base, path: "/v1/messages")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

            var body: [String: Any] = [
                "model": model,
                "max_tokens": 64000,
                "stream": true,
                "messages": conversation(history).map { ["role": $0.role.rawValue, "content": $0.text] },
            ]
            if let system = nonEmpty(agent.systemPrompt) { body["system"] = system }
            // On a safety decline, let the API re-run the request on a suitable
            // fallback model. Only first-party API supports this.
            if fallbackModels.contains(model), nonEmpty(agent.baseURL) == nil {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
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

            var messages: [[String: String]] = []
            if let system = nonEmpty(agent.systemPrompt) { messages.append(["role": "system", "content": system]) }
            messages += conversation(history).map { ["role": $0.role.rawValue, "content": $0.text] }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "stream": true,
                "messages": messages,
            ] as [String: Any])
            return request
        }
    }

    /// Decodes one SSE event into chunks. Throws when the provider reports an error.
    public static func decode(_ event: SSEEvent, provider: APIProvider) throws -> [StreamChunk] {
        if event.data == "[DONE]" { return [] }
        guard let data = event.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        if let error = json["error"] as? [String: Any] {
            throw ChatAPIError.provider(error["message"] as? String ?? "The provider returned an error.")
        }

        switch provider {
        case .anthropic:
            switch json["type"] as? String {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    return [.text(text)]
                }
            case "message_delta":
                let stopReason = (json["delta"] as? [String: Any])?["stop_reason"] as? String
                if stopReason == "refusal" { return [.notice("The model declined to continue this request.")] }
                if stopReason == "max_tokens" { return [.notice("Reply stopped at the output token limit.")] }
            default:
                break
            }
            return []

        case .openai, .openaiCompatible:
            guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else { return [] }
            var chunks: [StreamChunk] = []
            if let delta = first["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
                chunks.append(.text(text))
            }
            if first["finish_reason"] as? String == "length" {
                chunks.append(.notice("Reply stopped at the output token limit."))
            }
            return chunks
        }
    }

    /// Extracts a readable message from an error response body.
    public static func errorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No details." : String(trimmed.prefix(500))
    }

    /// User/assistant turns only, without empty messages, starting with a user turn.
    static func conversation(_ history: [ChatMessage]) -> [ChatMessage] {
        let turns = history.filter { $0.role != .system && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(turns.drop(while: { $0.role != .user }))
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Streams a reply from an API agent.
public struct ChatStreamer: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(agent: AgentDefinition, history: [ChatMessage], apiKey: String?) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let provider = agent.provider else {
                        throw ChatAPIError.invalidConfiguration("\(agent.name) has no API provider set.")
                    }
                    let request = try ChatProtocol.makeRequest(agent: agent, history: history, apiKey: apiKey)
                    try await run(request, provider: provider) { _ = continuation.yield($0) }
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
    private func run(_ request: URLRequest, provider: APIProvider, emit: (StreamChunk) -> Void) async throws {
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (data ?? Data(), response ?? URLResponse()))
            }.resume()
        }
        let body = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatAPIError.http(status: http.statusCode, message: ChatProtocol.errorMessage(from: body))
        }
        for event in SSEParser.parseAll(body) {
            for chunk in try ChatProtocol.decode(event, provider: provider) { emit(chunk) }
        }
    }
    #else
    private func run(_ request: URLRequest, provider: APIProvider, emit: (StreamChunk) -> Void) async throws {
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
            if line.hasPrefix("data:"), let event = parser.feed(line: "") {
                for chunk in try ChatProtocol.decode(event, provider: provider) { emit(chunk) }
            }
        }
    }
    #endif
}
