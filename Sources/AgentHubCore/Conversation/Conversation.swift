import Foundation

/// One agent's reply to one user message: its text, tool steps, and status.
public struct AgentRun: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var agentID: UUID
    public var agentName: String
    public var agentSymbol: String
    public var status: SessionStatus
    public var messages: [ChatMessage]
    public var usage: TokenUsage
    public var model: String?
    /// Cost reported by the agent itself (Claude Code reports one).
    public var reportedCost: Double?
    public var startedAt: Date
    public var finishedAt: Date?
    /// Files the run changed (git working folders only).
    public var changes: RunChanges?
    /// Runs started together by `/compare` share a group and show side by side.
    public var compareGroup: UUID?
    /// In a compare group: true for the result the user picked, false for the others.
    public var picked: Bool?
    /// "2/3" when the run is a step of a pipeline.
    public var pipelineStep: String?

    public init(id: UUID = UUID(), agent: AgentDefinition, startedAt: Date = Date()) {
        self.id = id
        self.agentID = agent.id
        self.agentName = agent.name
        self.agentSymbol = agent.symbol
        self.status = .running
        self.messages = []
        self.usage = .zero
        self.model = agent.model
        self.reportedCost = nil
        self.startedAt = startedAt
        self.finishedAt = nil
    }

    /// The reply text (excluding tool output), for sharing with other agents.
    public var replyText: String {
        messages.filter { $0.role == .assistant || $0.role == .output }.map(\.text).joined(separator: "\n\n")
    }

    public var isActive: Bool { status == .running || status == .needsInput }
}

public struct ConversationEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, run }

    public var id: UUID
    public var kind: Kind
    public var date: Date
    /// User entries: what was typed.
    public var text: String
    /// Run entries.
    public var run: AgentRun?
    /// User entries: paths of attached files.
    public var attachments: [String]?

    public static func user(_ text: String, attachments: [String] = [], date: Date = Date()) -> ConversationEntry {
        ConversationEntry(id: UUID(), kind: .user, date: date, text: text, run: nil, attachments: attachments.isEmpty ? nil : attachments)
    }

    public static func run(_ run: AgentRun) -> ConversationEntry {
        ConversationEntry(id: run.id, kind: .run, date: run.startedAt, text: "", run: run, attachments: nil)
    }
}

/// What the hub remembers about one agent within a conversation.
public struct Participant: Codable, Hashable, Sendable {
    public var agentID: UUID
    /// API agents: provider-native messages.
    public var transcript: [JSONValue]
    /// Terminal agents: the agent's own session id, used to continue it.
    public var resumeID: String?
    /// Entries before this index have already been shared with the agent.
    public var seenEntryCount: Int
    /// The agent's own git worktree, when the chat isolates agents.
    public var worktreePath: String?
    /// Tree the worktree started from, to diff and apply its changes.
    public var worktreeBase: String?

    public init(agentID: UUID) {
        self.agentID = agentID
        self.transcript = []
        self.resumeID = nil
        self.seenEntryCount = 0
    }
}

/// A chat thread where the user talks to one or more agents.
public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Folder terminal agents work in.
    public var workingDirectory: String?
    public var entries: [ConversationEntry]
    public var participants: [Participant]
    /// Give each agent its own git worktree (nil = off).
    public var isolateAgents: Bool?
    /// Agent addressed most recently; un-mentioned follow-ups go to it.
    public var lastAgentID: UUID?

    public init(id: UUID = UUID(), title: String = "New chat", workingDirectory: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.workingDirectory = workingDirectory
        self.entries = []
        self.participants = []
        self.lastAgentID = nil
    }

    public func participant(_ agentID: UUID) -> Participant? {
        participants.first { $0.agentID == agentID }
    }

    public mutating func updateParticipant(_ agentID: UUID, _ change: (inout Participant) -> Void) {
        if let index = participants.firstIndex(where: { $0.agentID == agentID }) {
            change(&participants[index])
        } else {
            var participant = Participant(agentID: agentID)
            change(&participant)
            participants.append(participant)
        }
    }

    public func runIndex(_ runID: UUID) -> Int? {
        entries.firstIndex { $0.id == runID && $0.kind == .run }
    }

    public mutating func updateRun(_ runID: UUID, _ change: (inout AgentRun) -> Void) {
        guard let index = runIndex(runID), var run = entries[index].run else { return }
        change(&run)
        entries[index].run = run
        updatedAt = Date()
    }

    public var runs: [AgentRun] { entries.compactMap(\.run) }
    public var activeRuns: [AgentRun] { runs.filter(\.isActive) }
    public var usage: TokenUsage { runs.reduce(.zero) { $0 + $1.usage } }

    /// Title from the first user message.
    public static func title(from text: String) -> String {
        let clean = text
            .split(separator: " ")
            .filter { !$0.hasPrefix("@") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "New chat" }
        return clean.count > 48 ? String(clean.prefix(47)) + "…" : clean
    }
}

/// Builds what an agent is sent for a task, including what other agents said
/// in the conversation since this agent last spoke.
public enum ConversationContext {
    public static let maxSharedCharacters = 6000

    public static func prompt(task: String, for agentID: UUID, in conversation: Conversation) -> String {
        let seen = conversation.participant(agentID)?.seenEntryCount ?? 0
        let others = conversation.entries.dropFirst(seen).compactMap { entry -> AgentRun? in
            guard let run = entry.run, run.agentID != agentID, !run.isActive else { return nil }
            return run.replyText.isEmpty ? nil : run
        }
        guard !others.isEmpty else { return task }

        let blocks = others.map { run -> String in
            var text = run.replyText
            if text.count > maxSharedCharacters { text = String(text.prefix(maxSharedCharacters)) + "\n[…truncated]" }
            return "<reply agent=\"\(run.agentName)\">\n\(text)\n</reply>"
        }
        return """
        Other agents in this conversation replied since you last spoke:

        \(blocks.joined(separator: "\n\n"))

        Your task:
        \(task)
        """
    }
}

/// One JSON file per conversation under `<directory>/conversations/`.
public struct ConversationStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.appendingPathComponent("conversations", isDirectory: true)
    }

    public func save(_ conversation: Conversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(conversation.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(conversation).write(to: url, options: .atomic)
        HubStore.restrictToOwner(url)
    }

    public func loadAll() -> [Conversation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(Conversation.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
    }
}
