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
    /// What this agent is good at; shown to the auto-router.
    public var summary: String

    // Terminal agents (cli / script)
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var promptStyle: PromptStyle
    public var mcpInjection: MCPInjection
    /// How the agent runs from chat (without a terminal).
    public var headless: HeadlessStyle
    /// What the agent may do when run from chat.
    public var headlessPermission: HeadlessPermission

    // API agents
    public var provider: APIProvider?
    public var model: String?
    public var baseURL: String?
    public var systemPrompt: String?
    /// API agents: offer the shared MCP servers' tools to the model.
    public var useTools: Bool
    /// API agents: ask before each tool call runs.
    public var confirmTools: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        handle: String,
        kind: AgentKind,
        symbol: String = "terminal",
        summary: String = "",
        command: String = "",
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        promptStyle: PromptStyle = .typeAfterLaunch,
        mcpInjection: MCPInjection = .none,
        headless: HeadlessStyle = .textOutput(arguments: []),
        headlessPermission: HeadlessPermission = .editFiles,
        provider: APIProvider? = nil,
        model: String? = nil,
        baseURL: String? = nil,
        systemPrompt: String? = nil,
        useTools: Bool = true,
        confirmTools: Bool = true
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.kind = kind
        self.symbol = symbol
        self.summary = summary
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.promptStyle = promptStyle
        self.mcpInjection = mcpInjection
        self.headless = headless
        self.headlessPermission = headlessPermission
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.systemPrompt = systemPrompt
        self.useTools = useTools
        self.confirmTools = confirmTools
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, handle, kind, symbol, summary, command, arguments, environment, workingDirectory
        case promptStyle, mcpInjection, headless, headlessPermission, provider, model, baseURL, systemPrompt, useTools, confirmTools
    }

    /// Fields added after the first release decode with defaults, so older
    /// config files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        handle = try c.decode(String.self, forKey: .handle)
        kind = try c.decode(AgentKind.self, forKey: .kind)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "terminal"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        promptStyle = try c.decodeIfPresent(PromptStyle.self, forKey: .promptStyle) ?? .typeAfterLaunch
        mcpInjection = try c.decodeIfPresent(MCPInjection.self, forKey: .mcpInjection) ?? .none
        headless = try c.decodeIfPresent(HeadlessStyle.self, forKey: .headless) ?? .textOutput(arguments: [])
        headlessPermission = try c.decodeIfPresent(HeadlessPermission.self, forKey: .headlessPermission) ?? .editFiles
        provider = try c.decodeIfPresent(APIProvider.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        useTools = try c.decodeIfPresent(Bool.self, forKey: .useTools) ?? true
        confirmTools = try c.decodeIfPresent(Bool.self, forKey: .confirmTools) ?? true
    }

    public var runsInTerminal: Bool { kind != .api }

    /// Can take tasks from the chat interface.
    public var supportsChat: Bool { kind == .api || headless != .none }

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
