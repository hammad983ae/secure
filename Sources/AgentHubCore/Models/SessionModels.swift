import Foundation

/// Lifecycle state of one agent session, used by the sidebar and the task board.
public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    /// Agent is producing output / working.
    case running
    /// Agent has gone quiet and is probably waiting for the user.
    case needsInput
    /// Process exited cleanly or the API reply finished.
    case done
    /// Process exited with an error or the API call failed.
    case failed

    public var title: String {
        switch self {
        case .running: return "Running"
        case .needsInput: return "Needs input"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

public enum ChatRole: String, Codable, Sendable {
    case system, user, assistant
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var text: String
    public var date: Date

    public init(id: UUID = UUID(), role: ChatRole, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}
