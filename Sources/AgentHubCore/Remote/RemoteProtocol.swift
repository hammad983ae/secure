import Foundation

// MARK: - Minimal HTTP/1.1

/// An HTTP request read from a socket.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public static let maxSize = 1_000_000

    public enum ParseResult: Equatable, Sendable {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    /// Parses one request from the bytes received so far.
    public static func parse(_ data: Data) -> ParseResult {
        guard data.count <= maxSize else { return .invalid }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxSize else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: Data(body)
        ))
    }

    /// The bearer token from the Authorization header.
    public var bearerToken: String? {
        guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int, contentType: String = "application/json", body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    public func serialized() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 429: reason = "Too Many Requests"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        if contentType.hasPrefix("text/html") {
            head += "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

// MARK: - Pairing token

public enum RemoteAuth {
    /// A new random token (256 bits, URL-safe).
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares in constant time so the token can't be guessed byte by byte.
    public static func matches(_ given: String?, _ expected: String) -> Bool {
        guard let given, !expected.isEmpty else { return false }
        let a = Array(given.utf8), b = Array(expected.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<b.count {
            difference |= (index < a.count ? a[index] : 0) ^ b[index]
        }
        return difference == 0
    }
}

// MARK: - What the phone sees

public struct RemoteSnapshot: Codable, Sendable {
    public struct Chat: Codable, Sendable {
        public var id: UUID
        public var title: String
        public var updatedAt: Date
        public var busy: Bool
        public var needsApproval: Bool
        public var folder: String?
        public var entries: [Entry]
    }

    public struct Entry: Codable, Sendable {
        public var id: UUID
        /// "user" or "run".
        public var kind: String
        public var text: String?
        public var run: Run?
    }

    public struct Run: Codable, Sendable {
        public var agent: String
        public var status: String
        public var active: Bool
        public var model: String?
        public var tokens: Int
        public var step: String?
        public var messages: [Message]
    }

    public struct Message: Codable, Sendable {
        public var id: UUID
        /// "text", "output", "tool", or "system".
        public var kind: String
        public var text: String
        public var tool: String?
        public var arguments: String?
        /// Tool state; "awaitingApproval" shows Allow / Deny.
        public var state: String?
    }

    public var generatedAt: Date
    public var host: String
    public var agents: [String]
    public var chats: [Chat]

    static let textLimit = 4000

    /// Recent chats (newest first) with their latest entries. Long text and
    /// tool output are trimmed to keep the phone fast.
    public static func make(conversations: [Conversation], agents: [String], host: String,
                            chatLimit: Int = 25, entryLimit: Int = 40, now: Date = Date()) -> RemoteSnapshot {
        let chats = conversations
            .filter { !$0.entries.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(chatLimit)
            .map { conversation -> Chat in
                let entries = conversation.entries.suffix(entryLimit).map { entry -> Entry in
                    guard let run = entry.run else {
                        return Entry(id: entry.id, kind: "user", text: trim(entry.text), run: nil)
                    }
                    let messages = run.messages.map { message -> Message in
                        let kind: String
                        switch message.role {
                        case .assistant, .user: kind = "text"
                        case .output: kind = "output"
                        case .tool: kind = "tool"
                        case .system: kind = "system"
                        }
                        return Message(id: message.id, kind: kind, text: trim(message.text, tail: kind == "output"),
                                       tool: message.toolName, arguments: message.toolArguments.map { trim($0) },
                                       state: message.toolState?.rawValue)
                    }
                    return Entry(id: entry.id, kind: "run", text: nil, run: Run(
                        agent: run.agentName, status: run.status.rawValue, active: run.isActive, model: run.model,
                        tokens: run.usage.total, step: run.pipelineStep, messages: messages
                    ))
                }
                let needsApproval = conversation.activeRuns.contains { run in
                    run.messages.contains { $0.toolState == .awaitingApproval }
                }
                return Chat(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt,
                            busy: !conversation.activeRuns.isEmpty, needsApproval: needsApproval,
                            folder: conversation.workingDirectory, entries: entries)
            }
        return RemoteSnapshot(generatedAt: now, host: host, agents: agents, chats: Array(chats))
    }

    static func trim(_ text: String, tail: Bool = false) -> String {
        guard text.count > textLimit else { return text }
        return tail ? "…" + String(text.suffix(textLimit)) : String(text.prefix(textLimit)) + "…"
    }
}

/// Bodies the phone posts.
public enum RemoteCommand {
    public struct Approve: Codable, Sendable {
        public var messageID: UUID
        public var approved: Bool
    }

    public struct Stop: Codable, Sendable {
        public var chatID: UUID
        public var runID: UUID?
    }

    public struct Send: Codable, Sendable {
        /// nil starts a new chat.
        public var chatID: UUID?
        public var text: String
    }
}
