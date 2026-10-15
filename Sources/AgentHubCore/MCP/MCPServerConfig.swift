import Foundation

/// An MCP server shared by every agent the hub launches.
public struct MCPServerConfig: Identifiable, Codable, Hashable, Sendable {
    public enum Transport: Codable, Hashable, Sendable {
        case stdio(command: String, arguments: [String], environment: [String: String])
        case http(url: String, headers: [String: String])
    }

    public var id: UUID
    public var name: String
    public var transport: Transport
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, transport: Transport, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.transport = transport
        self.enabled = enabled
    }

    /// Name reduced to characters every agent's config format accepts as a key.
    public var safeName: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "server" : cleaned
    }
}

/// Renders shared MCP servers into the formats individual agents understand.
public enum MCPConfigRenderer {
    /// `{"mcpServers": {...}}` JSON as read by `claude --mcp-config`.
    public static func claudeJSON(_ servers: [MCPServerConfig]) throws -> Data {
        var entries: [String: Any] = [:]
        for server in servers where server.enabled {
            switch server.transport {
            case let .stdio(command, arguments, environment):
                var entry: [String: Any] = ["type": "stdio", "command": command, "args": arguments]
                if !environment.isEmpty { entry["env"] = environment }
                entries[server.safeName] = entry
            case let .http(url, headers):
                var entry: [String: Any] = ["type": "http", "url": url]
                if !headers.isEmpty { entry["headers"] = headers }
                entries[server.safeName] = entry
            }
        }
        return try JSONSerialization.data(
            withJSONObject: ["mcpServers": entries],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// `-c key=value` override pairs for the Codex CLI. Only stdio servers are
    /// emitted; Codex's HTTP MCP support is configured differently.
    public static func codexOverrides(_ servers: [MCPServerConfig]) -> [String] {
        var args: [String] = []
        for server in servers where server.enabled {
            guard case let .stdio(command, arguments, environment) = server.transport else { continue }
            let key = "mcp_servers.\(server.safeName)"
            args += ["-c", "\(key).command=\(tomlString(command))"]
            args += ["-c", "\(key).args=[\(arguments.map(tomlString).joined(separator: ","))]"]
            if !environment.isEmpty {
                let pairs = environment.keys.sorted().map { "\(tomlKey($0))=\(tomlString(environment[$0]!))" }
                args += ["-c", "\(key).env={\(pairs.joined(separator: ","))}"]
            }
        }
        return args
    }

    /// A TOML basic string. JSON string escaping is a valid subset of TOML's.
    static func tomlString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        // Strip the surrounding [ ] of the one-element array.
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: "\\/", with: "/")
    }

    static func tomlKey(_ key: String) -> String {
        let bare = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return bare && !key.isEmpty ? key : tomlString(key)
    }
}
