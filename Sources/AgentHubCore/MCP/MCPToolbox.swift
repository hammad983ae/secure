import Foundation

/// Runs tools for an API agent. Implemented by `MCPToolbox`; tests use fakes.
public protocol ToolExecutor: Sendable {
    func listTools() async -> [ToolSpec]
    func callTool(name: String, arguments: JSONValue) async -> ToolResult
}

/// All enabled MCP servers' tools behind one executor.
///
/// Tools are exposed as `server__tool` so names from different servers can't
/// collide and stay within the 64-character `[a-zA-Z0-9_-]` limit APIs use.
public actor MCPToolbox: ToolExecutor {
    private let servers: [MCPServerConfig]
    private let shell: String
    private var clients: [String: MCPClient] = [:]
    private var routes: [String: (server: String, tool: String)] = [:]
    private var cachedTools: [ToolSpec]?
    /// Servers that failed to start, with the reason, for display.
    public private(set) var failures: [String: String] = [:]

    public init(servers: [MCPServerConfig], shell: String = "/bin/zsh") {
        self.servers = servers.filter(\.enabled)
        self.shell = shell
    }

    public var hasServers: Bool { !servers.isEmpty }

    public func listTools() async -> [ToolSpec] {
        if let cachedTools { return cachedTools }
        var specs: [ToolSpec] = []
        var used = Set<String>()
        for server in servers {
            do {
                let client = try await client(for: server)
                for tool in try await client.listTools() {
                    let exposed = Self.exposedName(server: server.safeName, tool: tool.name, taken: used)
                    used.insert(exposed)
                    routes[exposed] = (server.safeName, tool.name)
                    let description = tool.description.isEmpty ? "Tool from the \(server.name) MCP server." : tool.description
                    specs.append(ToolSpec(name: exposed, description: description, inputSchema: Self.normalizedSchema(tool.inputSchema)))
                }
                failures[server.safeName] = nil
            } catch {
                failures[server.safeName] = error.localizedDescription
            }
        }
        cachedTools = specs
        return specs
    }

    public func callTool(name: String, arguments: JSONValue) async -> ToolResult {
        if cachedTools == nil { _ = await listTools() }
        guard let route = routes[name], let client = clients[route.server] else {
            return ToolResult(text: "Unknown tool \(name).", isError: true)
        }
        do {
            return try await client.callTool(route.tool, arguments: arguments)
        } catch {
            return ToolResult(text: error.localizedDescription, isError: true)
        }
    }

    public func shutdown() {
        for client in clients.values { client.close() }
        clients.removeAll()
        cachedTools = nil
        routes.removeAll()
    }

    private func client(for server: MCPServerConfig) async throws -> MCPClient {
        if let existing = clients[server.safeName] { return existing }
        let client = try await MCPClient.connect(server, shell: shell)
        clients[server.safeName] = client
        return client
    }

    static func exposedName(server: String, tool: String, taken: Set<String>) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let clean = String("\(server)__\(tool)".map { allowed.contains($0) ? $0 : "_" })
        var name = String(clean.prefix(64))
        var counter = 2
        while taken.contains(name) {
            let suffix = "_\(counter)"
            name = String(clean.prefix(64 - suffix.count)) + suffix
            counter += 1
        }
        return name
    }

    /// APIs require an object schema at the top level.
    static func normalizedSchema(_ schema: JSONValue) -> JSONValue {
        guard var object = schema.objectValue else { return ["type": "object", "properties": [:]] }
        if object["type"] == nil { object["type"] = "object" }
        if object["properties"] == nil { object["properties"] = [:] }
        return .object(object)
    }
}
