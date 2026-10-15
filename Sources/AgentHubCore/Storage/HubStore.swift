import Foundation

/// The user's persisted configuration: agents and shared MCP servers.
/// API keys are deliberately not stored here (the app keeps them in the Keychain).
public struct HubConfiguration: Codable, Equatable, Sendable {
    public var agents: [AgentDefinition]
    public var mcpServers: [MCPServerConfig]
    /// Default working directory for new terminal sessions.
    public var defaultWorkingDirectory: String?

    public init(
        agents: [AgentDefinition] = AgentPresets.all,
        mcpServers: [MCPServerConfig] = [],
        defaultWorkingDirectory: String? = nil
    ) {
        self.agents = agents
        self.mcpServers = mcpServers
        self.defaultWorkingDirectory = defaultWorkingDirectory
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
              let config = try? JSONDecoder().decode(HubConfiguration.self, from: data)
        else { return HubConfiguration() }
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
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
