import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A tool an API model can call.
public struct ToolSpec: Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolResult: Hashable, Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

public enum MCPError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case closed(String)
    case timeout(String)
    case rpc(code: Int, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(message): return "Couldn't start MCP server: \(message)"
        case let .closed(message): return "MCP server closed the connection. \(message)"
        case let .timeout(method): return "MCP request timed out: \(method)"
        case let .rpc(code, message): return "MCP error \(code): \(message)"
        case let .badResponse(message): return "Unexpected MCP response: \(message)"
        }
    }
}

/// Moves JSON-RPC messages to and from an MCP server.
protocol MCPTransport: AnyObject, Sendable {
    /// Sends a request and returns its response message (`result` or `error`).
    func request(_ message: JSONValue, id: Int, timeout: TimeInterval) async throws -> JSONValue
    func notify(_ message: JSONValue) async throws
    func close()
}

/// MCP client: performs the handshake, lists tools, and calls them.
public final class MCPClient: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"

    public let name: String
    private let transport: MCPTransport
    private let lock = NSLock()
    private var nextID = 1

    init(name: String, transport: MCPTransport) {
        self.name = name
        self.transport = transport
    }

    /// Connects to a configured server. stdio servers are started through
    /// `shell -l -c` so they find the same PATH as the user's terminal.
    public static func connect(_ config: MCPServerConfig, shell: String = "/bin/zsh") async throws -> MCPClient {
        let transport: MCPTransport
        switch config.transport {
        case let .stdio(command, arguments, environment):
            let commandLine = (["exec", command] + arguments.map(LaunchPlanner.shellQuote)).joined(separator: " ")
            transport = try StdioTransport(executable: shell, arguments: ["-l", "-c", commandLine], environment: environment)
        case let .http(url, headers):
            guard let endpoint = URL(string: url) else { throw MCPError.launchFailed("Invalid URL \(url)") }
            transport = HTTPTransport(url: endpoint, headers: headers)
        }
        let client = MCPClient(name: config.safeName, transport: transport)
        do {
            try await client.initialize()
        } catch {
            transport.close()
            throw error
        }
        return client
    }

    /// For tests: connect to a server started with an explicit command.
    public static func connectStdio(name: String, executable: String, arguments: [String]) async throws -> MCPClient {
        let client = MCPClient(name: name, transport: try StdioTransport(executable: executable, arguments: arguments, environment: [:]))
        try await client.initialize()
        return client
    }

    func initialize() async throws {
        _ = try await call("initialize", params: [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": [:],
            "clientInfo": ["name": "AgentHub", "version": "0.2.0"],
        ], timeout: 30)
        try await transport.notify(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    public func listTools() async throws -> [ToolSpec] {
        var tools: [ToolSpec] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await call("tools/list", params: .object(params), timeout: 30)
            for tool in result["tools"]?.arrayValue ?? [] {
                guard let name = tool["name"]?.stringValue else { continue }
                tools.append(ToolSpec(
                    name: name,
                    description: tool["description"]?.stringValue ?? "",
                    inputSchema: tool["inputSchema"] ?? ["type": "object"]
                ))
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil
        return tools
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        let result = try await call("tools/call", params: ["name": .string(name), "arguments": arguments], timeout: 300)
        return Self.toolResult(from: result)
    }

    public func close() {
        transport.close()
    }

    static func toolResult(from result: JSONValue) -> ToolResult {
        var parts: [String] = []
        for item in result["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "text": parts.append(item["text"]?.stringValue ?? "")
            case "image": parts.append("[image: \(item["mimeType"]?.stringValue ?? "unknown type")]")
            case "audio": parts.append("[audio]")
            case "resource", "resource_link":
                let resource = item["resource"] ?? item
                parts.append(resource["text"]?.stringValue ?? "[resource: \(resource["uri"]?.stringValue ?? "")]")
            default: parts.append(item.jsonString)
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"] { parts.append(structured.jsonString) }
        return ToolResult(text: parts.joined(separator: "\n"), isError: result["isError"]?.boolValue ?? false)
    }

    private func call(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()

        let response = try await transport.request(
            ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params],
            id: id,
            timeout: timeout
        )
        if let error = response["error"] {
            throw MCPError.rpc(code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? "Unknown error")
        }
        guard let result = response["result"] else { throw MCPError.badResponse(response.jsonString) }
        return result
    }
}

// MARK: - stdio

/// Newline-delimited JSON-RPC over a child process's stdin/stdout.
final class StdioTransport: MCPTransport, @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false

    init(executable: String, arguments: [String], environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.receive(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.appendStderr(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.failAll(MCPError.closed("Exit code \(process.terminationStatus). \(self?.lastStderr ?? "")"))
        }
        do {
            try process.run()
        } catch {
            throw MCPError.launchFailed(error.localizedDescription)
        }
    }

    func request(_ message: JSONValue, id: Int, timeout: TimeInterval) async throws -> JSONValue {
        let data = try message.data() + Data("\n".utf8)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: MCPError.closed(lastStderr))
                return
            }
            pending[id] = continuation
            lock.unlock()
            write(data)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id: id, with: .failure(MCPError.timeout(message["method"]?.stringValue ?? "request")))
            }
        }
    }

    func notify(_ message: JSONValue) async throws {
        write(try message.data() + Data("\n".utf8))
    }

    func close() {
        failAll(MCPError.closed("Closed by Agent Hub."))
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    var lastStderr: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrTail
    }

    private func write(_ data: Data) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        stdin.fileHandleForWriting.write(data)
    }

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            guard let message = try? JSONValue.parse(line) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSONValue) {
        let id = message["id"]?.intValue
        if message["method"] != nil {
            // A request from the server. Answer pings; decline everything else.
            guard let rawID = message["id"] else { return } // notification
            let reply: JSONValue = message["method"]?.stringValue == "ping"
                ? ["jsonrpc": "2.0", "id": rawID, "result": [:]]
                : ["jsonrpc": "2.0", "id": rawID, "error": ["code": -32601, "message": "Method not supported by Agent Hub"]]
            if let data = try? reply.data() { write(data + Data("\n".utf8)) }
            return
        }
        if let id { resolve(id: id, with: .success(message)) }
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(2000))
        lock.unlock()
    }

    private func resolve(id: Int, with result: Result<JSONValue, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        lock.lock()
        closed = true
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}

// MARK: - Streamable HTTP

/// MCP "Streamable HTTP": each JSON-RPC message is a POST; the reply is JSON
/// or a short SSE stream containing the response.
final class HTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var sessionID: String?

    init(url: URL, headers: [String: String], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    func request(_ message: JSONValue, id: Int, timeout: TimeInterval) async throws -> JSONValue {
        let (data, response) = try await post(message, timeout: timeout)
        if let http = response as? HTTPURLResponse {
            if let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
                lock.lock(); sessionID = newSession; lock.unlock()
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MCPError.badResponse("HTTP \(http.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
            }
        }
        let body = String(decoding: data, as: UTF8.self)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            for event in SSEParser.parseAll(body) {
                if let message = try? JSONValue.parse(event.data), message["id"]?.intValue == id { return message }
            }
            throw MCPError.badResponse("No response for request \(id) in event stream")
        }
        return try JSONValue.parse(data)
    }

    func notify(_ message: JSONValue) async throws {
        _ = try await post(message, timeout: 30)
    }

    func close() {
        lock.lock()
        let id = sessionID
        lock.unlock()
        guard let id else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id")
        session.dataTask(with: request).resume()
    }

    private func post(_ message: JSONValue, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try message.data()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        lock.lock()
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        lock.unlock()
        return try await HTTP.data(for: request, session: session)
    }
}

/// `URLSession.data(for:)` that also works with swift-corelibs-foundation.
enum HTTP {
    static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response ?? URLResponse()))
                }
            }.resume()
        }
    }
}
