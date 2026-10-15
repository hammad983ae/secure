import AgentHubCore
import Foundation
import Observation

/// One running conversation with an agent: a live terminal or an API chat.
@MainActor
@Observable
final class AgentSession: Identifiable {
    let id = UUID()
    let agent: AgentDefinition
    let createdAt = Date()
    var title: String
    var status: SessionStatus = .running
    var unread = false

    // Terminal agents
    let terminal: TerminalController?
    let commandLine: String?

    // API agents
    var messages: [ChatMessage] = []
    var streamTask: Task<Void, Never>?

    init(agent: AgentDefinition, title: String, terminal: TerminalController?, commandLine: String?) {
        self.agent = agent
        self.title = title
        self.terminal = terminal
        self.commandLine = commandLine
    }

    var isFinished: Bool { status == .done || status == .failed }
    var isChat: Bool { terminal == nil }
}

enum SidebarItem: Hashable {
    case board
    case session(UUID)
}

/// App-wide state, owned by the main actor.
@MainActor
@Observable
final class AppState {
    private let store: HubStore
    private(set) var config: HubConfiguration
    var sessions: [AgentSession] = []
    var selection: SidebarItem? = .board
    var installedCommands: Set<String> = []
    var showPalette = false
    /// Short message shown under the command bar (errors, hints).
    var commandBarMessage: String?

    private let streamer = ChatStreamer()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = HubStore(directory: support.appendingPathComponent("AgentHub", isDirectory: true))
        config = store.load()
        Notifier.requestPermission()
        refreshInstalledAgents()
    }

    // MARK: Configuration

    func updateConfig(_ change: (inout HubConfiguration) -> Void) {
        change(&config)
        do {
            try store.save(config)
        } catch {
            commandBarMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
        refreshInstalledAgents()
    }

    func refreshInstalledAgents() {
        let commands = config.agents.filter(\.runsInTerminal).map(\.command)
        Task { @MainActor in
            installedCommands = await AgentAvailability.installed(commands)
        }
    }

    /// nil = unknown/not applicable (API agents, plain shell).
    func isInstalled(_ agent: AgentDefinition) -> Bool? {
        guard agent.runsInTerminal, let name = agent.command.split(separator: " ").first else { return nil }
        return installedCommands.contains(String(name))
    }

    func agent(handle: String) -> AgentDefinition? {
        config.agents.first { $0.handle.lowercased() == handle.lowercased() }
    }

    // MARK: Sessions

    var selectedSession: AgentSession? {
        guard case let .session(id) = selection else { return nil }
        return sessions.first { $0.id == id }
    }

    @discardableResult
    func startSession(agent: AgentDefinition, task: String?, workingDirectory: String? = nil) -> AgentSession {
        var agent = agent
        if let directory = workingDirectory ?? nonEmpty(agent.workingDirectory) ?? nonEmpty(config.defaultWorkingDirectory) {
            agent.workingDirectory = directory
        }
        let trimmedTask = task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedTask.isEmpty ? agent.name : "\(agent.name) · \(trimmedTask.prefix(40))"

        let session: AgentSession
        if agent.runsInTerminal {
            let spec = LaunchPlanner.plan(
                agent: agent,
                task: trimmedTask,
                mcpServers: config.mcpServers,
                mcpConfigPath: store.mcpConfigURL.path,
                shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            )
            if agent.mcpInjection == .claudeMCPConfigFlag { try? store.save(config) } // make sure the file exists
            let controller = TerminalController(spec: spec)
            session = AgentSession(agent: agent, title: title, terminal: controller, commandLine: spec.commandLine)
            controller.onStatusChange = { [weak self, weak session] status in
                guard let self, let session else { return }
                self.statusChanged(session, to: status)
            }
            controller.onTitleChange = { [weak session] newTitle in
                guard let session, !newTitle.isEmpty else { return }
                session.title = "\(session.agent.name) · \(newTitle)"
            }
        } else {
            session = AgentSession(agent: agent, title: title, terminal: nil, commandLine: nil)
            session.status = .needsInput
        }

        sessions.append(session)
        selection = .session(session.id)
        if session.isChat, !trimmedTask.isEmpty { sendChat(trimmedTask, to: session) }
        return session
    }

    func send(_ text: String, to session: AgentSession) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let terminal = session.terminal {
            terminal.send(text)
        } else {
            sendChat(text, to: session)
        }
    }

    func close(_ session: AgentSession) {
        session.terminal?.terminate()
        session.streamTask?.cancel()
        sessions.removeAll { $0.id == session.id }
        if case let .session(id) = selection, id == session.id {
            selection = sessions.last.map { .session($0.id) } ?? .board
        }
    }

    func select(_ session: AgentSession) {
        session.unread = false
        selection = .session(session.id)
    }

    // MARK: Command bar

    /// Handles a line typed in the command bar.
    ///
    /// - `@handle task` starts a new session per mentioned agent with the task.
    /// - `@all text` sends the text to every live session.
    /// - plain text goes to the selected session.
    func dispatch(_ input: String) {
        commandBarMessage = nil
        let handles = Set(config.agents.map { $0.handle.lowercased() })
        let command = CommandParser.parse(input, knownHandles: handles)

        if command.mentionsAll {
            let live = sessions.filter { !$0.isFinished }
            guard !live.isEmpty else { commandBarMessage = "No live sessions to broadcast to."; return }
            guard !command.task.isEmpty else { commandBarMessage = "Type something to send after @all."; return }
            live.forEach { send(command.task, to: $0) }
            commandBarMessage = "Sent to \(live.count) session\(live.count == 1 ? "" : "s")."
            return
        }

        if !command.mentions.isEmpty {
            for handle in command.mentions {
                if let agent = self.agent(handle: handle) { startSession(agent: agent, task: command.task) }
            }
            return
        }

        guard let session = selectedSession else {
            commandBarMessage = "Pick a session, or start one with @agent (e.g. @claude fix the tests)."
            return
        }
        send(command.task, to: session)
    }

    // MARK: Private

    private func statusChanged(_ session: AgentSession, to status: SessionStatus) {
        session.status = status
        guard status != .running else { return }
        if selectedSession?.id != session.id { session.unread = true }
        Notifier.post(title: "\(session.agent.name): \(status.title)", body: session.title)
    }

    private func sendChat(_ text: String, to session: AgentSession) {
        guard session.streamTask == nil else {
            commandBarMessage = "\(session.agent.name) is still replying."
            return
        }
        session.messages.append(ChatMessage(role: .user, text: text))
        let history = session.messages
        let reply = ChatMessage(role: .assistant, text: "")
        session.messages.append(reply)
        session.status = .running

        let agent = session.agent
        let key = agent.apiKeyAccount.flatMap(KeychainStore.read(account:))
        let stream = streamer.stream(agent: agent, history: history, apiKey: key)

        session.streamTask = Task { @MainActor [weak self, weak session] in
            var failed = false
            do {
                for try await chunk in stream {
                    guard let session, let index = session.messages.firstIndex(where: { $0.id == reply.id }) else { break }
                    switch chunk {
                    case let .text(text): session.messages[index].text += text
                    case let .notice(note): session.messages.append(ChatMessage(role: .system, text: note))
                    }
                }
            } catch is CancellationError {
            } catch {
                failed = true
                session?.messages.append(ChatMessage(role: .system, text: error.localizedDescription))
            }
            guard let session else { return }
            session.streamTask = nil
            session.messages.removeAll { $0.id == reply.id && $0.text.isEmpty }
            self?.statusChanged(session, to: failed ? .failed : .needsInput)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
