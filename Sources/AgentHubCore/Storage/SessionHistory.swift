import Foundation

/// A saved session, for the history list and for reopening chats.
public struct SessionRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case terminal, chat
    }

    public var id: UUID
    public var agentID: UUID
    public var agentName: String
    public var agentSymbol: String
    public var kind: Kind
    public var title: String
    public var task: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var status: SessionStatus
    public var commandLine: String?
    public var workingDirectory: String?
    /// Chat sessions: what the user saw.
    public var messages: [ChatMessage]
    /// Chat sessions: provider-native messages, needed to continue the conversation.
    public var transcript: [JSONValue]
    public var usage: TokenUsage

    public init(
        id: UUID,
        agentID: UUID,
        agentName: String,
        agentSymbol: String,
        kind: Kind,
        title: String,
        task: String? = nil,
        createdAt: Date,
        updatedAt: Date = Date(),
        status: SessionStatus,
        commandLine: String? = nil,
        workingDirectory: String? = nil,
        messages: [ChatMessage] = [],
        transcript: [JSONValue] = [],
        usage: TokenUsage = .zero
    ) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.agentSymbol = agentSymbol
        self.kind = kind
        self.title = title
        self.task = task
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.messages = messages
        self.transcript = transcript
        self.usage = usage
    }
}

/// One JSON file per session under `<directory>/sessions/`.
public struct HistoryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.appendingPathComponent("sessions", isDirectory: true)
    }

    public func save(_ record: SessionRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(record.id)
        try Self.encoder.encode(record).write(to: url, options: .atomic)
        HubStore.restrictToOwner(url)
    }

    /// All saved sessions, newest first. Unreadable files are skipped.
    public func loadAll() -> [SessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.decoder
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(SessionRecord.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    public func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Append-only log of token usage from Agent Hub's own API calls (`usage.jsonl`).
public struct UsageStore: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("usage.jsonl")
    }

    public func append(_ record: UsageRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let line = try encoder.encode(record) + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
            HubStore.restrictToOwner(url)
        }
    }

    public func load() -> [UsageRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(UsageRecord.self, from: Data($0.utf8)) }
    }
}
