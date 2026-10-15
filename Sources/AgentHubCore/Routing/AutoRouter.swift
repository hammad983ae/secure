import Foundation

/// The router model's choice of agents for a task.
public struct RouteDecision: Equatable, Sendable {
    public var handles: [String]
    public var reason: String
}

/// Picks agents for a task that has no `@mention`, by asking a fast model.
public enum AutoRouter {
    /// Default router model when the router agent uses Anthropic.
    public static let defaultAnthropicModel = "claude-haiku-5-5"

    public static func prompt(task: String, candidates: [AgentDefinition]) -> String {
        let list = candidates.map { agent in
            let kind: String
            switch agent.kind {
            case .cli: kind = "terminal coding agent"
            case .api: kind = "chat model"
            case .script: kind = "script/shell"
            }
            let summary = agent.summary.isEmpty ? "" : " — \(agent.summary)"
            return "- \(agent.handle) (\(agent.name), \(kind))\(summary)"
        }.joined(separator: "\n")

        return """
        You route tasks to AI agents. Pick the single best agent for the task below. \
        Pick more than one only if the user explicitly asks for several agents or a comparison.

        Agents:
        \(list)

        Task:
        <task>
        \(task)
        </task>

        Reply with only a JSON object, no other text:
        {"handles": ["<handle>"], "reason": "<one short sentence>"}
        """
    }

    /// Parses the router's reply, keeping only known handles. Returns nil if
    /// no usable choice was found.
    public static func parse(_ reply: String, candidates: [AgentDefinition]) -> RouteDecision? {
        let known = Set(candidates.map { $0.handle.lowercased() })
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let json = try? JSONValue.parse(String(reply[start...end]))
        else { return nil }

        var handles: [String] = []
        let raw = json["handles"]?.arrayValue?.compactMap(\.stringValue)
            ?? json["handle"]?.stringValue.map { [$0] }
            ?? []
        for handle in raw {
            let clean = handle.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            if known.contains(clean), !handles.contains(clean) { handles.append(clean) }
        }
        guard !handles.isEmpty else { return nil }
        return RouteDecision(handles: handles, reason: json["reason"]?.stringValue ?? "")
    }
}
