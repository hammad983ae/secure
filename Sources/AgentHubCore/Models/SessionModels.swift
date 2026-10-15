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
    case system, user, assistant, tool
}

/// Where a tool call shown in a chat stands.
public enum ToolCallState: String, Codable, Sendable {
    case awaitingApproval, running, succeeded, failed, denied
}

/// One item in a chat as the user sees it. The provider-native transcript is
/// kept separately; this is for display and history.
public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var text: String
    public var date: Date
    // Tool calls (role == .tool)
    public var toolName: String?
    public var toolCallID: String?
    public var toolArguments: String?
    public var toolState: ToolCallState?

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        date: Date = Date(),
        toolName: String? = nil,
        toolCallID: String? = nil,
        toolArguments: String? = nil,
        toolState: ToolCallState? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.toolArguments = toolArguments
        self.toolState = toolState
    }
}
