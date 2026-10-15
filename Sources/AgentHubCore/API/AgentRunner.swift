import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Progress reported while an API agent works.
public enum RunnerEvent: Sendable {
    /// Text to append to the reply currently being shown.
    case text(String)
    case notice(String)
    /// A model turn finished and a new reply bubble should start for any further text.
    case turnFinished
    case toolCallStarted(id: String, name: String, arguments: String)
    case toolCallFinished(id: String, result: ToolResult)
    case usage(TokenUsage, model: String)
}

/// Runs an API agent: streams a reply and, when the model calls tools,
/// executes them and continues until the model is done.
public struct AgentRunner: Sendable {
    public static let maxTurns = 25

    private let client: SSEClient

    public init(session: URLSession = .shared) {
        self.client = SSEClient(session: session)
    }

    /// Runs from `transcript` (which should end with a user message) and returns
    /// the messages to append to it.
    ///
    /// - Parameters:
    ///   - approve: asked before each tool call; return false to deny it.
    ///   - onEvent: progress for the UI.
    public func run(
        agent: AgentDefinition,
        transcript: [JSONValue],
        apiKey: String?,
        tools: ToolExecutor?,
        approve: @escaping @Sendable (ToolCall) async -> Bool,
        onEvent: @escaping @Sendable (RunnerEvent) async -> Void
    ) async throws -> [JSONValue] {
        guard let provider = agent.provider else {
            throw ChatAPIError.invalidConfiguration("\(agent.name) has no API provider set.")
        }
        let specs = await tools?.listTools() ?? []
        let schemas = Dictionary(specs.map { ($0.name, $0.inputSchema) }, uniquingKeysWith: { first, _ in first })
        var appended: [JSONValue] = []

        for _ in 0..<Self.maxTurns {
            try Task.checkCancellation()
            let request = try ChatProtocol.makeRequest(agent: agent, transcript: transcript + appended, tools: specs, apiKey: apiKey)
            let turn = try await streamTurn(request, provider: provider, onEvent: onEvent)
            appended.append(turn.assistantMessage)
            if !turn.usage.isEmpty {
                await onEvent(.usage(turn.usage, model: turn.model ?? agent.model ?? "unknown"))
            }
            await onEvent(.turnFinished)

            guard turn.stopReason == "tool_use", !turn.toolCalls.isEmpty, let tools else { return appended }

            var results: [(id: String, result: ToolResult)] = []
            for call in turn.toolCalls {
                await onEvent(.toolCallStarted(id: call.id, name: call.name, arguments: call.rawArguments))
                let result: ToolResult
                if let problem = ToolInputValidator.problem(with: call.arguments, schema: schemas[call.name] ?? [:]) {
                    // Don't run tools on broken input; let the model retry.
                    result = ToolResult(text: "Invalid input: \(problem) Raw input: \(call.rawArguments.prefix(2000))", isError: true)
                } else if await approve(call) {
                    result = await tools.callTool(name: call.name, arguments: call.arguments ?? [:])
                } else {
                    result = ToolResult(text: "The user denied this tool call.", isError: true)
                }
                await onEvent(.toolCallFinished(id: call.id, result: result))
                results.append((id: call.id, result: result))
            }

            switch provider {
            case .anthropic:
                appended.append(AnthropicTurnAccumulator.toolResultsMessage(results))
            case .openai, .openaiCompatible:
                appended += OpenAITurnAccumulator.toolResultMessages(results)
            }
        }
        await onEvent(.notice("Stopped after \(Self.maxTurns) tool rounds."))
        return appended
    }

    /// Runs one prompt without tools (used by the router). The reply text is
    /// `AgentRunner.text(of: result.assistantMessage)`.
    public func complete(agent: AgentDefinition, prompt: String, apiKey: String?) async throws -> TurnResult {
        guard let provider = agent.provider else {
            throw ChatAPIError.invalidConfiguration("\(agent.name) has no API provider set.")
        }
        let request = try ChatProtocol.makeRequest(agent: agent, transcript: [ChatProtocol.userMessage(prompt)], apiKey: apiKey, maxTokens: 8000)
        return try await streamTurn(request, provider: provider) { _ in }
    }

    private func streamTurn(
        _ request: URLRequest,
        provider: APIProvider,
        onEvent: @escaping @Sendable (RunnerEvent) async -> Void
    ) async throws -> TurnResult {
        switch provider {
        case .anthropic:
            var accumulator = AnthropicTurnAccumulator()
            for try await event in client.events(for: request) {
                for output in try accumulator.consume(event) { await onEvent(Self.event(output)) }
            }
            return accumulator.result()
        case .openai, .openaiCompatible:
            var accumulator = OpenAITurnAccumulator()
            for try await event in client.events(for: request) {
                for output in try accumulator.consume(event) { await onEvent(Self.event(output)) }
            }
            return accumulator.result()
        }
    }

    private static func event(_ output: StreamOutput) -> RunnerEvent {
        switch output {
        case let .text(text): return .text(text)
        case let .notice(note): return .notice(note)
        }
    }

    /// Visible text of a native assistant message.
    public static func text(of message: JSONValue) -> String {
        if let text = message["content"]?.stringValue { return text }
        return (message["content"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
    }
}
