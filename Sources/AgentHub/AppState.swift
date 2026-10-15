import AgentHubCore
import Foundation
import Observation

/// One running conversation with an agent: a live terminal or an API chat.
@MainActor
@Observable
final class AgentSession: Identifiable {
    let id: UUID
    let agent: AgentDefinition
    let createdAt: Date
    let task: String?
    var title: String
    var status: SessionStatus = .running
    var unread = false
    var usage = TokenUsage.zero

    // Terminal agents
    let terminal: TerminalController?
    let commandLine: String?

    // API agents
    var messages: [ChatMessage] = []
    /// Provider-native messages sent to the API.
    var transcript: [JSONValue] = []
    var runTask: Task<Void, Never>?
    /// The assistant bubble receiving streamed text, if any.
    var streamingReplyID: UUID?

    init(id: UUID = UUID(), agent: AgentDefinition, title: String, task: String?, createdAt: Date = Date(),
         terminal: TerminalController?, commandLine: String?) {
        self.id = id
        self.agent = agent
        self.title = title
        self.task = task
        self.createdAt = createdAt
        self.terminal = terminal
        self.commandLine = commandLine
    }

    var isFinished: Bool { status == .done || status == .failed }
    var isChat: Bool { terminal == nil }
    var isBusy: Bool { runTask != nil }

    func record() -> SessionRecord {
        SessionRecord(
            id: id,
            agentID: agent.id,
            agentName: agent.name,
            agentSymbol: agent.symbol,
            kind: isChat ? .chat : .terminal,
            title: title,
            task: task,
            createdAt: createdAt,
            updatedAt: Date(),
            status: status,
            commandLine: commandLine,
            workingDirectory: agent.workingDirectory,
            messages: messages,
            transcript: transcript,
            usage: usage
        )
    }
}

enum SidebarItem: Hashable {
    case board
    case usage
    case session(UUID)
    case history(UUID)
}

/// App-wide state, owned by the main actor.
@MainActor
@Observable
final class AppState {
    static let maxSplitPanes = 4

    private let store: HubStore
    private let historyStore: HistoryStore
    private let usageStore: UsageStore
    private let logScanner = AgentLogScanner()
    private let runner = AgentRunner()

    private(set) var config: HubConfiguration
    var sessions: [AgentSession] = []
    private(set) var history: [SessionRecord] = []
    var selection: SidebarItem? = .board
    /// Sessions shown side by side when one of them is selected.
    var splitIDs: [UUID] = []
    var installedCommands: Set<String> = []
    var showPalette = false
    /// Short message shown under the command bar (errors, hints, routing).
    var commandBarMessage: String?
    var isRouting = false

    /// Usage from Agent Hub's own API calls.
    private(set) var apiUsage: [UsageRecord] = []
    /// Usage read from Claude Code and Codex logs.
    private(set) var logUsage: [UsageRecord] = []
    private(set) var isScanningUsage = false
    private(set) var lastUsageScan: Date?

    private var toolbox: MCPToolbox?
    private var pendingApprovals: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("AgentHub", isDirectory: true)
        store = HubStore(directory: directory)
        historyStore = HistoryStore(directory: directory)
        usageStore = UsageStore(directory: directory)
        config = store.load()
        history = historyStore.loadAll()
        apiUsage = usageStore.load()
        Notifier.requestPermission()
        refreshInstalledAgents()
        refreshUsage()
    }

    // MARK: Configuration

    func updateConfig(_ change: (inout HubConfiguration) -> Void) {
        let oldServers = config.mcpServers
        change(&config)
        do {
            try store.save(config)
        } catch {
            commandBarMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
        if config.mcpServers != oldServers, let old = toolbox {
            toolbox = nil
            Task { await old.shutdown() }
        }
        refreshInstalledAgents()
    }

    func refreshInstalledAgents() {
        let commands = config.agents.filter(\.runsInTerminal).map(\.command)
        Task {
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

    private var shell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    // MARK: Sessions

    var selectedSession: AgentSession? {
        guard case let .session(id) = selection else { return nil }
        return sessions.first { $0.id == id }
    }

    func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
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
                shell: shell
            )
            if agent.mcpInjection == .claudeMCPConfigFlag { try? store.save(config) } // make sure the file exists
            let controller = TerminalController(spec: spec)
            session = AgentSession(agent: agent, title: title, task: trimmedTask, terminal: controller, commandLine: spec.commandLine)
            controller.onStatusChange = { [weak self, weak session] status in
                guard let self, let session else { return }
                self.statusChanged(session, to: status)
            }
            controller.onTitleChange = { [weak session] newTitle in
                guard let session, !newTitle.isEmpty else { return }
                session.title = "\(session.agent.name) · \(newTitle)"
            }
        } else {
            session = AgentSession(agent: agent, title: title, task: trimmedTask, terminal: nil, commandLine: nil)
            session.status = .needsInput
        }

        sessions.append(session)
        selection = .session(session.id)
        persist(session)
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
        stop(session)
        session.terminal?.terminate()
        if session.terminal != nil, !session.isFinished {
            session.status = .done
        }
        persist(session)
        sessions.removeAll { $0.id == session.id }
        splitIDs.removeAll { $0 == session.id }
        if case let .session(id) = selection, id == session.id {
            selection = sessions.last.map { .session($0.id) } ?? .board
        }
    }

    /// Stops an API agent's current reply and declines any pending tool approvals.
    func stop(_ session: AgentSession) {
        for message in session.messages where message.toolState == .awaitingApproval {
            resolveApproval(messageID: message.id, approved: false)
        }
        session.runTask?.cancel()
    }

    func select(_ session: AgentSession) {
        session.unread = false
        selection = .session(session.id)
    }

    // MARK: Split view

    func isInSplit(_ session: AgentSession) -> Bool { splitIDs.contains(session.id) }

    func toggleSplit(_ session: AgentSession) {
        if let index = splitIDs.firstIndex(of: session.id) {
            splitIDs.remove(at: index)
            return
        }
        // Starting a split from the current view keeps what's on screen.
        if splitIDs.isEmpty, let current = selectedSession, current.id != session.id {
            splitIDs.append(current.id)
        }
        guard splitIDs.count < Self.maxSplitPanes else {
            commandBarMessage = "Split view holds up to \(Self.maxSplitPanes) sessions."
            return
        }
        splitIDs.append(session.id)
        select(session)
    }

    /// Sessions to show side by side for the current selection, or nil for a single view.
    var visibleSplit: [AgentSession]? {
        guard case let .session(id) = selection, splitIDs.contains(id), splitIDs.count > 1 else { return nil }
        return splitIDs.compactMap { session(id: $0) }
    }

    // MARK: History

    /// Saved sessions that aren't open right now.
    var closedHistory: [SessionRecord] {
        let open = Set(sessions.map(\.id))
        return history.filter { !open.contains($0.id) }
    }

    func historyRecord(id: UUID) -> SessionRecord? {
        history.first { $0.id == id }
    }

    /// Reopens a saved chat so the conversation can continue, or reruns a terminal session.
    func reopen(_ record: SessionRecord) {
        if let open = session(id: record.id) { select(open); return }
        guard let agent = config.agents.first(where: { $0.id == record.agentID }) else {
            commandBarMessage = "The agent \"\(record.agentName)\" no longer exists."
            return
        }
        switch record.kind {
        case .chat:
            let session = AgentSession(id: record.id, agent: agent, title: record.title, task: record.task,
                                       createdAt: record.createdAt, terminal: nil, commandLine: nil)
            session.messages = record.messages
            session.transcript = record.transcript
            session.usage = record.usage
            session.status = .needsInput
            sessions.append(session)
            select(session)
        case .terminal:
            startSession(agent: agent, task: record.task, workingDirectory: record.workingDirectory)
        }
    }

    func deleteHistory(_ record: SessionRecord) {
        historyStore.delete(record.id)
        history.removeAll { $0.id == record.id }
        if selection == .history(record.id) { selection = .board }
    }

    func clearHistory() {
        let open = Set(sessions.map(\.id))
        for record in history where !open.contains(record.id) { historyStore.delete(record.id) }
        history.removeAll { !open.contains($0.id) }
        if case .history = selection { selection = .board }
    }

    private func persist(_ session: AgentSession) {
        let record = session.record()
        try? historyStore.save(record)
        history.removeAll { $0.id == record.id }
        history.insert(record, at: 0)
    }

    // MARK: Usage

    var allUsage: [UsageRecord] { apiUsage + logUsage }

    /// Re-reads Claude Code and Codex logs from the last 31 days.
    func refreshUsage() {
        guard config.scanAgentLogs else { logUsage = []; return }
        guard !isScanningUsage else { return }
        isScanningUsage = true
        let scanner = logScanner
        let since = Calendar.current.date(byAdding: .day, value: -31, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        Task {
            let records = await Task.detached(priority: .utility) { scanner.scan(since: since) }.value
            logUsage = records
            isScanningUsage = false
            lastUsageScan = Date()
        }
    }

    func usageSummary(since start: Date) -> UsageSummary {
        UsageSummary(records: allUsage, from: start)
    }

    private func recordUsage(_ usage: TokenUsage, model: String, source: String, session: AgentSession?) {
        let record = UsageRecord(source: source, model: model, date: Date(), usage: usage, sessionID: session?.id)
        apiUsage.append(record)
        try? usageStore.append(record)
    }

    // MARK: Command bar

    /// Handles a line typed in the command bar.
    ///
    /// - `@handle task` starts a new session per mentioned agent with the task.
    /// - `@all text` sends the text to every live session.
    /// - plain text goes to the selected session, or is auto-routed when none is selected.
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

        if let session = selectedSession {
            send(command.task, to: session)
        } else if config.autoRoute {
            route(command.task)
        } else {
            commandBarMessage = "Pick a session, or start one with @agent (e.g. @claude fix the tests)."
        }
    }

    /// Asks the router model which agent should handle `task`, then starts it.
    private func route(_ task: String) {
        guard !isRouting else { return }
        guard let router = config.routerAgent else {
            commandBarMessage = "Auto-routing needs an API agent. Pick one in Settings → General, or start with @agent."
            return
        }
        let candidates = config.agents.filter { isInstalled($0) != false }
        let key = router.apiKeyAccount.flatMap(KeychainStore.read(account:))
        let runner = runner
        isRouting = true
        commandBarMessage = "Choosing an agent…"

        Task {
            defer { isRouting = false }
            do {
                let result = try await runner.complete(agent: router, prompt: AutoRouter.prompt(task: task, candidates: candidates), apiKey: key)
                if !result.usage.isEmpty {
                    recordUsage(result.usage, model: result.model ?? router.model ?? "unknown", source: "Auto-router", session: nil)
                }
                let reply = AgentRunner.text(of: result.assistantMessage)
                guard let decision = AutoRouter.parse(reply, candidates: candidates) else {
                    commandBarMessage = "Couldn't pick an agent for that. Start it with @agent instead."
                    return
                }
                for handle in decision.handles {
                    if let agent = self.agent(handle: handle) { startSession(agent: agent, task: task) }
                }
                let names = decision.handles.map { "@\($0)" }.joined(separator: ", ")
                commandBarMessage = "Routed to \(names)" + (decision.reason.isEmpty ? "." : ": \(decision.reason)")
            } catch {
                commandBarMessage = "Auto-routing failed: \(error.localizedDescription) Start with @agent instead."
            }
        }
    }

    // MARK: Tool approvals

    func resolveApproval(messageID: UUID, approved: Bool) {
        guard let continuation = pendingApprovals.removeValue(forKey: messageID) else { return }
        for session in sessions {
            if let index = session.messages.firstIndex(where: { $0.id == messageID }) {
                session.messages[index].toolState = approved ? .running : .denied
                if approved { session.status = .running }
            }
        }
        continuation.resume(returning: approved)
    }

    private func approve(_ call: ToolCall, in session: AgentSession) async -> Bool {
        guard session.agent.confirmTools else { return true }
        guard let index = session.messages.lastIndex(where: { $0.toolCallID == call.id }) else { return false }
        let messageID = session.messages[index].id
        session.messages[index].toolState = .awaitingApproval
        statusChanged(session, to: .needsInput)
        return await withCheckedContinuation { continuation in
            pendingApprovals[messageID] = continuation
        }
    }

    // MARK: Private

    private func statusChanged(_ session: AgentSession, to status: SessionStatus) {
        session.status = status
        guard status != .running else { return }
        if selectedSession?.id != session.id { session.unread = true }
        Notifier.post(title: "\(session.agent.name): \(status.title)", body: session.title)
        if session.terminal != nil, session.isFinished { persist(session) }
    }

    private func currentToolbox() -> MCPToolbox? {
        guard config.mcpServers.contains(where: \.enabled) else { return nil }
        if let toolbox { return toolbox }
        let box = MCPToolbox(servers: config.mcpServers, shell: shell)
        toolbox = box
        return box
    }

    private func sendChat(_ text: String, to session: AgentSession) {
        guard !session.isBusy else {
            commandBarMessage = "\(session.agent.name) is still working. Stop it first or wait."
            return
        }
        session.messages.append(ChatMessage(role: .user, text: text))
        session.transcript.append(ChatProtocol.userMessage(text))
        session.status = .running
        session.streamingReplyID = nil

        let agent = session.agent
        let key = agent.apiKeyAccount.flatMap(KeychainStore.read(account:))
        let tools: ToolExecutor? = agent.useTools ? currentToolbox() : nil
        let transcript = session.transcript
        let runner = runner

        session.runTask = Task { [weak self] in
            var failed = false
            do {
                let appended = try await runner.run(
                    agent: agent,
                    transcript: transcript,
                    apiKey: key,
                    tools: tools,
                    approve: { [weak self] call in
                        await self?.approve(call, in: session) ?? false
                    },
                    onEvent: { [weak self] event in
                        await self?.handle(event, in: session)
                    }
                )
                session.transcript += appended
            } catch {
                if error is CancellationError || Task.isCancelled {
                    session.messages.append(ChatMessage(role: .system, text: "Stopped."))
                } else {
                    failed = true
                    session.messages.append(ChatMessage(role: .system, text: error.localizedDescription))
                }
                Self.dropUnansweredUserTurn(session)
            }
            session.runTask = nil
            session.streamingReplyID = nil
            session.messages.removeAll { $0.role == .assistant && $0.text.isEmpty }
            self?.statusChanged(session, to: failed ? .failed : .needsInput)
            self?.persist(session)
        }
    }

    /// After a failed or stopped run, the transcript must not end with the
    /// user turn the model never answered, or the next send would put two user
    /// turns in a row. (Partial tool rounds aren't added to the transcript.)
    private static func dropUnansweredUserTurn(_ session: AgentSession) {
        if session.transcript.last?["role"]?.stringValue == "user",
           session.transcript.last?["content"]?.stringValue != nil {
            session.transcript.removeLast()
        }
    }

    private func handle(_ event: RunnerEvent, in session: AgentSession) {
        switch event {
        case let .text(text):
            if let id = session.streamingReplyID, let index = session.messages.firstIndex(where: { $0.id == id }) {
                session.messages[index].text += text
            } else {
                let reply = ChatMessage(role: .assistant, text: text)
                session.messages.append(reply)
                session.streamingReplyID = reply.id
            }
        case .turnFinished:
            session.streamingReplyID = nil
        case let .notice(note):
            session.messages.append(ChatMessage(role: .system, text: note))
        case let .toolCallStarted(id, name, arguments):
            session.messages.append(ChatMessage(
                role: .tool, text: "", toolName: name, toolCallID: id, toolArguments: arguments, toolState: .running
            ))
        case let .toolCallFinished(id, result):
            guard let index = session.messages.lastIndex(where: { $0.toolCallID == id }) else { return }
            let denied = session.messages[index].toolState == .denied
            session.messages[index].toolState = denied ? .denied : (result.isError ? .failed : .succeeded)
            session.messages[index].text = String(result.text.prefix(4000))
            session.status = .running
        case let .usage(usage, model):
            session.usage += usage
            recordUsage(usage, model: model, source: session.agent.name, session: session)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
