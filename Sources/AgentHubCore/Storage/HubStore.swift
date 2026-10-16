import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case dark, light, system
    public var title: String { rawValue.capitalized }
}

/// Accent color pairs for the UI.
public enum AccentPalette: String, Codable, CaseIterable, Sendable {
    case neon, sunset, aurora, ocean, mono
    public var title: String {
        switch self {
        case .neon: return "Neon (cyan → violet)"
        case .sunset: return "Sunset (amber → pink)"
        case .aurora: return "Aurora (green → teal)"
        case .ocean: return "Ocean (blue → indigo)"
        case .mono: return "Mono (silver)"
        }
    }
}

/// The user's persisted configuration: agents, shared MCP servers, and options.
/// API keys are deliberately not stored here (the app keeps them in the Keychain).
public struct HubConfiguration: Codable, Equatable, Sendable {
    public var agents: [AgentDefinition]
    public var mcpServers: [MCPServerConfig]
    /// Default working directory for new terminal sessions.
    public var defaultWorkingDirectory: String?
    /// Route command-bar text without an `@mention` (and no session selected) to an agent automatically.
    public var autoRoute: Bool
    /// API agent used to pick agents. nil = the built-in Claude API agent.
    public var routerAgentID: UUID?
    /// Model the router uses. nil = a fast default for the router agent's provider.
    public var routerModel: String?
    /// Read Claude Code and Codex logs for the usage dashboard.
    public var scanAgentLogs: Bool
    /// False for configs saved before agents had headless settings (they get preset values once).
    public var hasHeadlessSettings: Bool
    /// Show the usage widget in the menu bar.
    public var showMenuBarWidget: Bool
    public var budgets: [Budget]
    /// Saved prompts, run with `/name` in chat.
    public var prompts: [SavedPrompt]
    public var appearance: AppearanceMode
    public var accent: AccentPalette
    /// ⌥Space opens a quick prompt from any app.
    public var globalHotKey: Bool

    public init(
        agents: [AgentDefinition] = AgentPresets.all,
        mcpServers: [MCPServerConfig] = [],
        defaultWorkingDirectory: String? = nil,
        autoRoute: Bool = true,
        routerAgentID: UUID? = nil,
        routerModel: String? = nil,
        scanAgentLogs: Bool = true,
        showMenuBarWidget: Bool = true,
        budgets: [Budget] = [],
        prompts: [SavedPrompt] = SavedPrompt.defaults,
        appearance: AppearanceMode = .dark,
        accent: AccentPalette = .neon,
        globalHotKey: Bool = true
    ) {
        self.agents = agents
        self.mcpServers = mcpServers
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.autoRoute = autoRoute
        self.routerAgentID = routerAgentID
        self.routerModel = routerModel
        self.scanAgentLogs = scanAgentLogs
        self.hasHeadlessSettings = true
        self.showMenuBarWidget = showMenuBarWidget
        self.budgets = budgets
        self.prompts = prompts
        self.appearance = appearance
        self.accent = accent
        self.globalHotKey = globalHotKey
    }

    private enum CodingKeys: String, CodingKey {
        case agents, mcpServers, defaultWorkingDirectory, autoRoute, routerAgentID, routerModel, scanAgentLogs
        case hasHeadlessSettings, showMenuBarWidget, budgets, prompts, appearance, accent, globalHotKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = try c.decodeIfPresent([AgentDefinition].self, forKey: .agents) ?? AgentPresets.all
        mcpServers = try c.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? []
        defaultWorkingDirectory = try c.decodeIfPresent(String.self, forKey: .defaultWorkingDirectory)
        autoRoute = try c.decodeIfPresent(Bool.self, forKey: .autoRoute) ?? true
        routerAgentID = try c.decodeIfPresent(UUID.self, forKey: .routerAgentID)
        routerModel = try c.decodeIfPresent(String.self, forKey: .routerModel)
        scanAgentLogs = try c.decodeIfPresent(Bool.self, forKey: .scanAgentLogs) ?? true
        hasHeadlessSettings = try c.decodeIfPresent(Bool.self, forKey: .hasHeadlessSettings) ?? false
        showMenuBarWidget = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarWidget) ?? true
        budgets = try c.decodeIfPresent([Budget].self, forKey: .budgets) ?? []
        prompts = try c.decodeIfPresent([SavedPrompt].self, forKey: .prompts) ?? SavedPrompt.defaults
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .dark
        accent = try c.decodeIfPresent(AccentPalette.self, forKey: .accent) ?? .neon
        globalHotKey = try c.decodeIfPresent(Bool.self, forKey: .globalHotKey) ?? true
    }

    /// The agent used for auto-routing, with the router model applied.
    public var routerAgent: AgentDefinition? {
        let id = routerAgentID ?? AgentPresets.claudeAPI.id
        guard var agent = agents.first(where: { $0.id == id && $0.kind == .api }) else { return nil }
        if let routerModel, !routerModel.trimmingCharacters(in: .whitespaces).isEmpty {
            agent.model = routerModel
        } else if agent.provider == .anthropic {
            agent.model = AutoRouter.defaultAnthropicModel
        }
        agent.systemPrompt = nil
        return agent
    }
}

/// Reads and writes `HubConfiguration` as JSON in a directory
/// (on macOS: `~/Library/Application Support/AgentHub`).
public struct HubStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var mcpConfigURL: URL { directory.appendingPathComponent("mcp-servers.json") }

    public func load() -> HubConfiguration {
        guard let data = try? Data(contentsOf: configURL),
              var config = try? JSONDecoder().decode(HubConfiguration.self, from: data)
        else { return HubConfiguration() }
        // Built-in agents saved before newer fields existed pick up their defaults.
        for index in config.agents.indices {
            guard let preset = AgentPresets.all.first(where: { $0.id == config.agents[index].id }) else { continue }
            if config.agents[index].summary.isEmpty { config.agents[index].summary = preset.summary }
            if !config.hasHeadlessSettings { config.agents[index].headless = preset.headless }
        }
        config.hasHeadlessSettings = true
        return config
    }

    public func save(_ config: HubConfiguration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
        // Keep the file agents read in sync with the configuration.
        try MCPConfigRenderer.claudeJSON(config.mcpServers).write(to: mcpConfigURL, options: .atomic)
        // MCP env vars and headers often carry tokens: keep both files owner-only.
        for url in [configURL, mcpConfigURL] {
            Self.restrictToOwner(url)
        }
    }

    static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
