import Foundation

/// How an agent is driven by the hub.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    /// An interactive command-line agent (Claude Code, Codex, Gemini CLI, Aider, ...)
    /// run inside a pseudo-terminal.
    case cli
    /// A model reached directly over an HTTP API using the user's own key.
    case api
    /// Any user-registered command or script, also run in a terminal.
    case script
}

/// Remote model providers the hub can talk to directly.
public enum APIProvider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openai
    /// Any server that speaks the OpenAI chat-completions protocol
    /// (Ollama, LM Studio, OpenRouter, vLLM, ...). Requires `baseURL`.
    case openaiCompatible

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .openaiCompatible: return "OpenAI-compatible"
        }
    }
}

/// How an initial task is handed to a terminal agent when it starts.
public enum PromptStyle: Codable, Hashable, Sendable {
    /// `agent "the task"`
    case positional
    /// `agent <flag> "the task"`, e.g. `gemini -i "the task"`.
    case flag(String)
    /// Start the agent, then type the task into its terminal.
    case typeAfterLaunch
}

/// How the hub's shared MCP servers are passed to a terminal agent.
public enum MCPInjection: String, Codable, CaseIterable, Sendable {
    case none
    /// `--mcp-config <file.json>` (Claude Code).
    case claudeMCPConfigFlag
    /// `-c mcp_servers.<name>.command=...` overrides (Codex CLI).
    case codexConfigOverrides
}

/// A configured agent the user can start sessions with.
public struct AgentDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Short handle used for `@mentions` in the command bar, e.g. `claude`.
    public var handle: String
    public var kind: AgentKind
    /// SF Symbol name shown in the UI.
    public var symbol: String

    // Terminal agents (cli / script)
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var promptStyle: PromptStyle
    public var mcpInjection: MCPInjection

    // API agents
    public var provider: APIProvider?
    public var model: String?
    public var baseURL: String?
    public var systemPrompt: String?

    public init(
        id: UUID = UUID(),
        name: String,
        handle: String,
        kind: AgentKind,
        symbol: String = "terminal",
        command: String = "",
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        promptStyle: PromptStyle = .typeAfterLaunch,
        mcpInjection: MCPInjection = .none,
        provider: APIProvider? = nil,
        model: String? = nil,
        baseURL: String? = nil,
        systemPrompt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.kind = kind
        self.symbol = symbol
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.promptStyle = promptStyle
        self.mcpInjection = mcpInjection
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.systemPrompt = systemPrompt
    }

    public var runsInTerminal: Bool { kind != .api }

    /// Keychain account under which this agent's API key is stored.
    /// Agents of the same provider share a key unless they use a custom base URL.
    public var apiKeyAccount: String? {
        guard kind == .api, let provider else { return nil }
        if provider == .openaiCompatible, let baseURL, !baseURL.isEmpty {
            return "\(provider.rawValue):\(baseURL)"
        }
        return provider.rawValue
    }
}
