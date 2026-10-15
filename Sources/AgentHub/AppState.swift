import AgentHubCore
import Foundation
import Observation

/// A live interactive terminal running an agent.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id: UUID
    let agent: AgentDefinition
    let createdAt: Date
    let task: String?
    var title: String
    var status: SessionStatus = .running
    var unread = false
    let controller: TerminalController
    let commandLine: String

    init(id: UUID = UUID(), agent: AgentDefinition, title: String, task: String?, controller: TerminalController, commandLine: String) {
        self.id = id
        self.agent = agent
        self.title = title
        self.task = task
        self.createdAt = Date()
        self.controller = controller
        self.commandLine = commandLine
    }

    var isFinished: Bool { status == .done || status == .failed }

    func record() -> SessionRecord {
        SessionRecord(
            id: id, agentID: agent.id, agentName: agent.name, agentSymbol: agent.symbol, kind: .terminal,
            title: title, task: task, createdAt: createdAt, updatedAt: Date(), status: status,
            commandLine: commandLine, workingDirectory: agent.workingDirectory
        )
    }
}

/// A conversation plus the work in flight for it.
@MainActor
@Observable
final class ConversationModel: Identifiable {
    let id: UUID
    var conversation: Conversation
    /// Running agent tasks by run id.
    var tasks: [UUID: Task<Void, Never>] = [:]
    /// Run id → the assistant message currently receiving streamed text.
    var openBubbles: [UUID: UUID] = [:]
    var unread = false

    init(_ conversation: Conversation) {
        self.id = conversation.id
        self.conversation = conversation
    }

    var isBusy: Bool { !tasks.isEmpty }
}

enum SidebarItem: Hashable {
    case chat(UUID)
    case terminal(UUID)
    case board
    case usage
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
    private let conversationStore: ConversationStore
    private let logScanner = AgentLogScanner()
    private let runner = AgentRunner()
    private let headlessRunner = HeadlessRunner()
    let isDemo: Bool

    private(set) var config: HubConfiguration
    var conversations: [ConversationModel] = []
    var terminals: [TerminalSession] = []
    private(set) var history: [SessionRecord] = []
    var selection: SidebarItem?
    /// Terminals shown side by side when one of them is selected.
    var splitIDs: [UUID] = []
    var installedCommands: Set<String> = []
    var showPalette = false
    /// Short status line under the composer (errors, hints, routing).
    var notice: String?
    var isRouting = false

    /// Usage from Agent Hub's own API calls.
    private(set) var apiUsage: [UsageRecord] = []
    /// Usage read from Claude Code and Codex logs.
    private(set) var logUsage: [UsageRecord] = []
    private(set) var isScanningUsage = false
    private(set) var lastUsageScan: Date?

    private var toolbox: MCPToolbox?
    private var pendingApprovals: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var refreshTimer: Timer?

    init(demo: Bool = false) {
        isDemo = demo
        let directory: URL
        if demo {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHubDemo-\(UUID().uuidString)")
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = support.appendingPathComponent("AgentHub", isDirectory: true)
        }
        store = HubStore(directory: directory)
        historyStore = HistoryStore(directory: directory)
        usageStore = UsageStore(directory: directory)
        conversationStore = ConversationStore(directory: directory)
        config = store.load()
        history = historyStore.loadAll()
        apiUsage = usageStore.load()
        conversations = conversationStore.loadAll().map(ConversationModel.init)
        // Runs that were in flight when the app quit can't be resumed.
        for model in conversations {
            for run in model.conversation.runs where run.isActive {
                model.conversation.updateRun(run.id) { $0.status = .failed; $0.finishedAt = $0.finishedAt ?? Date() }
            }
        }

        if demo {
            DemoData.populate(self)
        } else {
            Notifier.requestPermission()
            refreshInstalledAgents()
            refreshUsage()
            // Keep the menu bar figures current even when no window is open.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUsage() }
            }
        }
        selection = conversations.first.map { .chat($0.id) } ?? .board
    }

    // MARK: Configuration

    func updateConfig(_ change: (inout HubConfiguration) -> Void) {
        let oldServers = config.mcpServers
        change(&config)
        if !isDemo {
            do {
                try store.save(config)
            } catch {
                notice = "Couldn't save settings: \(error.localizedDescription)"
            }
        }
        if config.mcpServers != oldServers, let old = toolbox {
            toolbox = nil
            Task { await old.shutdown() }
        }
        refreshInstalledAgents()
    }

    func refreshInstalledAgents() {
        guard !isDemo else { return }
        let commands = config.agents.filter(\.runsInTerminal).map(\.command)
        Task {
            installedCommands = await AgentAvailability.installed(commands)
        }
    }

    /// nil = unknown/not applicable (API agents, plain shell).
    func isInstalled(_ agent: AgentDefinition) -> Bool? {
        guard agent.runsInTerminal, let name = agent.command.split(separator: " ").first else { return nil }
        if isDemo { return true }
        return installedCommands.contains(String(name))
    }

    func agent(handle: String) -> AgentDefinition? {
        config.agents.first { $0.handle.lowercased() == handle.lowercased() }
    }

    func agent(id: UUID) -> AgentDefinition? {
        config.agents.first { $0.id == id }
    }

    /// Agents that can take tasks from chat.
    var chatAgents: [AgentDefinition] { config.agents.filter(\.supportsChat) }

    private var shell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    // MARK: Conversations

    var sortedConversations: [ConversationModel] {
        conversations.sorted { $0.conversation.updatedAt > $1.conversation.updatedAt }
    }

    var selectedConversation: ConversationModel? {
        guard case let .chat(id) = selection else { return nil }
        return conversation(id: id)
    }

    func conversation(id: UUID) -> ConversationModel? {
        conversations.first { $0.id == id }
    }

    @discardableResult
    func newConversation(workingDirectory: String? = nil) -> ConversationModel {
        // Reuse an untouched empty chat instead of piling them up.
        if let empty = conversations.first(where: { $0.conversation.entries.isEmpty }) {
            selection = .chat(empty.id)
            return empty
        }
        let model = ConversationModel(Conversation(workingDirectory: workingDirectory ?? config.defaultWorkingDirectory))
        conversations.append(model)
        selection = .chat(model.id)
        return model
    }

    func deleteConversation(_ model: ConversationModel) {
        stopAll(in: model)
        conversations.removeAll { $0.id == model.id }
        conversationStore.delete(model.id)
        if selection == .chat(model.id) {
            selection = sortedConversations.first.map { .chat($0.id) } ?? .board
        }
    }

    func setWorkingDirectory(_ path: String?, for model: ConversationModel) {
        model.conversation.workingDirectory = path
        persist(model)
    }

    /// Handles a message typed in a conversation.
    ///
    /// - `@agent task` runs each mentioned agent on the task (mentions can be anywhere).
    /// - `@all text` goes to every agent already in the conversation.
    /// - no mention: goes to the agent addressed last, or is auto-routed.
    func send(_ input: String, in model: ConversationModel) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notice = nil
        let handles = Set(chatAgents.map { $0.handle.lowercased() })
        let command = CommandParser.chatCommand(text, knownHandles: handles)
        let task = command.task.isEmpty ? text : command.task

        var targets: [AgentDefinition]
        if command.mentionsAll {
            targets = model.conversation.participants.compactMap { agent(id: $0.agentID) }
            if targets.isEmpty { notice = "No agents in this chat yet. Mention one, like @claude."; return }
        } else if !command.mentions.isEmpty {
            targets = command.mentions.compactMap { agent(handle: $0) }
        } else if let last = model.conversation.lastAgentID, let agent = agent(id: last) {
            targets = [agent]
        } else {
            targets = []
        }

        if model.conversation.entries.isEmpty { model.conversation.title = Conversation.title(from: text) }
        model.conversation.entries.append(.user(text))
        model.conversation.updatedAt = Date()
        persist(model)

        if targets.isEmpty {
            if config.autoRoute {
                route(task, in: model)
            } else {
                notice = "Mention an agent to start, like @claude or @codex."
            }
            return
        }
        for agent in targets { startRun(agent: agent, task: task, in: model) }
    }

    /// Sends a quick task from the menu bar into a fresh chat.
    func quickAsk(_ text: String) {
        let model = newConversation()
        send(text, in: model)
    }

    func stop(runID: UUID, in model: ConversationModel) {
        if let run = model.conversation.entries.first(where: { $0.id == runID })?.run {
            for message in run.messages where message.toolState == .awaitingApproval {
                resolveApproval(messageID: message.id, approved: false)
            }
        }
        model.tasks[runID]?.cancel()
    }

    func stopAll(in model: ConversationModel) {
        for runID in model.tasks.keys { stop(runID: runID, in: model) }
    }

    /// Opens a chat run's agent session in an interactive terminal.
    func openInTerminal(_ run: AgentRun, in model: ConversationModel) {
        guard var agent = agent(id: run.agentID) else { return }
        agent.workingDirectory = model.conversation.workingDirectory ?? agent.workingDirectory
        if let resumeID = model.conversation.participant(agent.id)?.resumeID,
           let extra = LaunchPlanner.interactiveResumeArguments(for: agent, resumeID: resumeID) {
            agent.arguments += extra
        }
        startTerminal(agent: agent, task: nil)
    }

    private func startRun(agent baseAgent: AgentDefinition, task: String, in model: ConversationModel) {
        var agent = baseAgent
        if agent.runsInTerminal {
            agent.workingDirectory = nonEmpty(model.conversation.workingDirectory)
                ?? nonEmpty(agent.workingDirectory)
                ?? nonEmpty(config.defaultWorkingDirectory)
        }
        let prompt = ConversationContext.prompt(task: task, for: agent.id, in: model.conversation)

        let run = AgentRun(agent: agent)
        // Everything finished so far has now been shared with this agent.
        let firstActiveOther = model.conversation.entries.firstIndex {
            ($0.run?.isActive ?? false) && $0.run?.agentID != agent.id
        }
        let seen = firstActiveOther ?? model.conversation.entries.count
        model.conversation.entries.append(.run(run))
        model.conversation.lastAgentID = agent.id
        model.conversation.updateParticipant(agent.id) { $0.seenEntryCount = seen }

        if agent.kind == .api {
            startAPIRun(agent: agent, prompt: prompt, runID: run.id, in: model)
        } else {
            startHeadlessRun(agent: agent, prompt: prompt, runID: run.id, in: model)
        }
    }

    private func startAPIRun(agent: AgentDefinition, prompt: String, runID: UUID, in model: ConversationModel) {
        let userMessage = ChatProtocol.userMessage(prompt)
        let transcript = (model.conversation.participant(agent.id)?.transcript ?? []) + [userMessage]
        let key = agent.apiKeyAccount.flatMap(KeychainStore.read(account:))
        let tools: ToolExecutor? = agent.useTools ? currentToolbox() : nil
        let runner = runner

        model.tasks[runID] = Task { [weak self] in
            var failed = false
            do {
                let appended = try await runner.run(
                    agent: agent,
                    transcript: transcript,
                    apiKey: key,
                    tools: tools,
                    approve: { [weak self] call in
                        await self?.approve(call, runID: runID, in: model) ?? false
                    },
                    onEvent: { [weak self] event in
                        await self?.handle(event, runID: runID, agent: agent, in: model)
                    }
                )
                model.conversation.updateParticipant(agent.id) { $0.transcript = transcript + appended }
            } catch {
                failed = !(error is CancellationError || Task.isCancelled)
                let text = failed ? error.localizedDescription : "Stopped."
                model.conversation.updateRun(runID) { $0.messages.append(ChatMessage(role: .system, text: text)) }
            }
            self?.finishRun(runID, failed: failed, in: model)
        }
    }

    private func startHeadlessRun(agent: AgentDefinition, prompt: String, runID: UUID, in model: ConversationModel) {
        let resumeID = model.conversation.participant(agent.id)?.resumeID
        guard let spec = LaunchPlanner.headless(
            agent: agent, prompt: prompt, resumeID: resumeID,
            mcpServers: config.mcpServers, mcpConfigPath: store.mcpConfigURL.path, shell: shell
        ) else {
            model.conversation.updateRun(runID) {
                $0.messages.append(ChatMessage(role: .system, text: "\(agent.name) can't run from chat. Open it in a terminal instead."))
            }
            finishRun(runID, failed: true, in: model)
            return
        }
        if agent.headless == .claudeCode, !config.mcpServers.isEmpty, !isDemo { try? store.save(config) }
        let events = headlessRunner.run(spec, style: agent.headless)

        model.tasks[runID] = Task { [weak self] in
            var failed = false
            do {
                for try await event in events {
                    if case let .finished(isError, _, _) = event { failed = isError }
                    self?.handle(event, runID: runID, agent: agent, in: model)
                }
                if Task.isCancelled {
                    model.conversation.updateRun(runID) { $0.messages.append(ChatMessage(role: .system, text: "Stopped.")) }
                }
            } catch {
                failed = !Task.isCancelled
                model.conversation.updateRun(runID) {
                    $0.messages.append(ChatMessage(role: .system, text: failed ? "Couldn't start \(agent.name): \(error.localizedDescription)" : "Stopped."))
                }
            }
            self?.finishRun(runID, failed: failed, in: model)
        }
    }

    private func finishRun(_ runID: UUID, failed: Bool, in model: ConversationModel) {
        model.tasks[runID] = nil
        model.openBubbles[runID] = nil
        var finished: AgentRun?
        model.conversation.updateRun(runID) { run in
            run.status = failed ? .failed : .done
            run.finishedAt = Date()
            run.messages.removeAll { $0.role == .assistant && $0.text.isEmpty }
            for index in run.messages.indices where run.messages[index].toolState == .running || run.messages[index].toolState == .awaitingApproval {
                run.messages[index].toolState = .failed
            }
            finished = run
        }
        persist(model)
        guard let finished else { return }
        if selectedConversation?.id != model.id { model.unread = true }
        Notifier.post(title: "\(finished.agentName): \(finished.status.title)", body: model.conversation.title)
    }

    /// Asks the router model which agent should handle `task`, then runs it.
    private func route(_ task: String, in model: ConversationModel) {
        guard !isRouting else { return }
        guard let router = config.routerAgent else {
            notice = "Auto-routing needs an API agent. Pick one in Settings → General, or mention an agent."
            return
        }
        let candidates = chatAgents.filter { isInstalled($0) != false }
        let key = router.apiKeyAccount.flatMap(KeychainStore.read(account:))
        let runner = runner
        isRouting = true
        notice = "Choosing an agent…"

        Task {
            defer { isRouting = false }
            do {
                let result = try await runner.complete(agent: router, prompt: AutoRouter.prompt(task: task, candidates: candidates), apiKey: key)
                if !result.usage.isEmpty {
                    recordUsage(result.usage, model: result.model ?? router.model ?? "unknown", source: "Auto-router")
                }
                guard let decision = AutoRouter.parse(AgentRunner.text(of: result.assistantMessage), candidates: candidates) else {
                    notice = "Couldn't pick an agent for that. Mention one, like @claude."
                    return
                }
                for handle in decision.handles {
                    if let agent = agent(handle: handle) { startRun(agent: agent, task: task, in: model) }
                }
                notice = "Routed to " + decision.handles.map { "@\($0)" }.joined(separator: ", ")
                    + (decision.reason.isEmpty ? "" : " · \(decision.reason)")
            } catch {
                notice = "Auto-routing failed: \(error.localizedDescription) Mention an agent instead."
            }
        }
    }

    // MARK: Run events

    private func handle(_ event: RunnerEvent, runID: UUID, agent: AgentDefinition, in model: ConversationModel) {
        if case .turnFinished = event { model.openBubbles[runID] = nil }
        if case let .text(text) = event {
            if let bubble = model.openBubbles[runID] {
                model.conversation.updateRun(runID) { run in
                    if let index = run.messages.lastIndex(where: { $0.id == bubble }) { run.messages[index].text += text }
                }
            } else {
                let message = ChatMessage(role: .assistant, text: text)
                model.openBubbles[runID] = message.id
                model.conversation.updateRun(runID) { $0.messages.append(message) }
            }
            return
        }
        model.conversation.updateRun(runID) { run in
            switch event {
            case .text, .turnFinished:
                break
            case let .notice(note):
                run.messages.append(ChatMessage(role: .system, text: note))
            case let .toolCallStarted(id, name, arguments):
                run.messages.append(ChatMessage(role: .tool, text: "", toolName: name, toolCallID: id, toolArguments: arguments, toolState: .running))
            case let .toolCallFinished(id, result):
                guard let index = run.messages.lastIndex(where: { $0.toolCallID == id }) else { return }
                let denied = run.messages[index].toolState == .denied
                run.messages[index].toolState = denied ? .denied : (result.isError ? .failed : .succeeded)
                run.messages[index].text = String(result.text.prefix(4000))
                run.status = .running
            case let .usage(usage, model):
                run.usage += usage
                run.model = model
            }
        }
        if case let .usage(usage, modelName) = event {
            recordUsage(usage, model: modelName, source: agent.name)
        }
    }

    private func handle(_ event: HeadlessEvent, runID: UUID, agent: AgentDefinition, in model: ConversationModel) {
        if case let .started(sessionID, _) = event, let sessionID {
            model.conversation.updateParticipant(agent.id) { $0.resumeID = sessionID }
        }
        model.conversation.updateRun(runID) { run in
            switch event {
            case let .started(_, modelName):
                if let modelName { run.model = modelName }
            case let .text(text):
                run.messages.append(ChatMessage(role: .assistant, text: text))
            case let .output(text):
                if let last = run.messages.indices.last, run.messages[last].role == .output {
                    run.messages[last].text += text
                    if run.messages[last].text.count > 200_000 {
                        run.messages[last].text = "…" + String(run.messages[last].text.suffix(150_000))
                    }
                } else {
                    run.messages.append(ChatMessage(role: .output, text: text))
                }
            case let .toolStarted(id, name, detail):
                run.messages.append(ChatMessage(role: .tool, text: "", toolName: name, toolCallID: id, toolArguments: detail, toolState: .running))
            case let .toolFinished(id, output, isError):
                if let index = run.messages.lastIndex(where: { $0.toolCallID == id }) {
                    run.messages[index].toolState = isError ? .failed : .succeeded
                    run.messages[index].text = output
                }
            case let .usage(usage, modelName):
                run.usage += usage
                if let modelName { run.model = modelName }
            case let .finished(isError, message, cost):
                if let cost { run.reportedCost = cost }
                if let message, isError { run.messages.append(ChatMessage(role: .system, text: message)) }
            }
        }
        // Claude Code and Codex log their own usage, which the dashboard reads;
        // recording it here too would count it twice.
    }

    // MARK: Tool approvals (API agents)

    func resolveApproval(messageID: UUID, approved: Bool) {
        guard let continuation = pendingApprovals.removeValue(forKey: messageID) else { return }
        for model in conversations {
            for entry in model.conversation.entries {
                guard let run = entry.run, run.messages.contains(where: { $0.id == messageID }) else { continue }
                model.conversation.updateRun(run.id) { run in
                    if let index = run.messages.firstIndex(where: { $0.id == messageID }) {
                        run.messages[index].toolState = approved ? .running : .denied
                    }
                    run.status = .running
                }
            }
        }
        continuation.resume(returning: approved)
    }

    private func approve(_ call: ToolCall, runID: UUID, in model: ConversationModel) async -> Bool {
        guard let run = model.conversation.entries.first(where: { $0.id == runID })?.run,
              let agent = agent(id: run.agentID) else { return false }
        guard agent.confirmTools else { return true }
        guard let message = run.messages.last(where: { $0.toolCallID == call.id }) else { return false }
        model.conversation.updateRun(runID) { run in
            if let index = run.messages.firstIndex(where: { $0.id == message.id }) {
                run.messages[index].toolState = .awaitingApproval
            }
            run.status = .needsInput
        }
        Notifier.post(title: "\(agent.name) wants to use a tool", body: call.name)
        return await withCheckedContinuation { continuation in
            pendingApprovals[message.id] = continuation
        }
    }

    private func currentToolbox() -> MCPToolbox? {
        guard config.mcpServers.contains(where: \.enabled) else { return nil }
        if let toolbox { return toolbox }
        let box = MCPToolbox(servers: config.mcpServers, shell: shell)
        toolbox = box
        return box
    }

    private func persist(_ model: ConversationModel) {
        guard !isDemo, !model.conversation.entries.isEmpty else { return }
        try? conversationStore.save(model.conversation)
    }

    // MARK: Terminals

    var selectedTerminal: TerminalSession? {
        guard case let .terminal(id) = selection else { return nil }
        return terminal(id: id)
    }

    func terminal(id: UUID) -> TerminalSession? {
        terminals.first { $0.id == id }
    }

    @discardableResult
    func startTerminal(agent: AgentDefinition, task: String?, workingDirectory: String? = nil) -> TerminalSession {
        var agent = agent
        if let directory = workingDirectory ?? nonEmpty(agent.workingDirectory) ?? nonEmpty(config.defaultWorkingDirectory) {
            agent.workingDirectory = directory
        }
        let trimmedTask = task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let spec = LaunchPlanner.plan(
            agent: agent, task: trimmedTask, mcpServers: config.mcpServers,
            mcpConfigPath: store.mcpConfigURL.path, shell: shell
        )
        if agent.mcpInjection == .claudeMCPConfigFlag, !isDemo { try? store.save(config) }
        let controller = TerminalController(spec: spec)
        let title = trimmedTask.isEmpty ? agent.name : "\(agent.name) · \(trimmedTask.prefix(40))"
        let session = TerminalSession(agent: agent, title: title, task: trimmedTask, controller: controller, commandLine: spec.commandLine)
        controller.onStatusChange = { [weak self, weak session] status in
            guard let self, let session else { return }
            session.status = status
            guard status != .running else { return }
            if self.selectedTerminal?.id != session.id { session.unread = true }
            Notifier.post(title: "\(session.agent.name): \(status.title)", body: session.title)
            if session.isFinished { self.persist(session) }
        }
        controller.onTitleChange = { [weak session] newTitle in
            guard let session, !newTitle.isEmpty else { return }
            session.title = "\(session.agent.name) · \(newTitle)"
        }
        terminals.append(session)
        selection = .terminal(session.id)
        persist(session)
        return session
    }

    func sendToTerminal(_ text: String, _ session: TerminalSession) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.controller.send(text)
    }

    func close(_ session: TerminalSession) {
        session.controller.terminate()
        if !session.isFinished { session.status = .done }
        persist(session)
        terminals.removeAll { $0.id == session.id }
        splitIDs.removeAll { $0 == session.id }
        if selection == .terminal(session.id) {
            selection = terminals.last.map { .terminal($0.id) } ?? sortedConversations.first.map { .chat($0.id) } ?? .board
        }
    }

    func select(_ session: TerminalSession) {
        session.unread = false
        selection = .terminal(session.id)
    }

    func isInSplit(_ session: TerminalSession) -> Bool { splitIDs.contains(session.id) }

    func toggleSplit(_ session: TerminalSession) {
        if let index = splitIDs.firstIndex(of: session.id) {
            splitIDs.remove(at: index)
            return
        }
        if splitIDs.isEmpty, let current = selectedTerminal, current.id != session.id {
            splitIDs.append(current.id)
        }
        guard splitIDs.count < Self.maxSplitPanes else {
            notice = "Split view holds up to \(Self.maxSplitPanes) terminals."
            return
        }
        splitIDs.append(session.id)
        select(session)
    }

    /// Terminals to show side by side for the current selection, or nil for a single view.
    var visibleSplit: [TerminalSession]? {
        guard case let .terminal(id) = selection, splitIDs.contains(id), splitIDs.count > 1 else { return nil }
        return splitIDs.compactMap { terminal(id: $0) }
    }

    // MARK: History (terminal sessions and pre-chat records)

    var closedHistory: [SessionRecord] {
        let open = Set(terminals.map(\.id))
        return history.filter { !open.contains($0.id) }
    }

    func historyRecord(id: UUID) -> SessionRecord? {
        history.first { $0.id == id }
    }

    func rerun(_ record: SessionRecord) {
        guard let agent = config.agents.first(where: { $0.id == record.agentID }) else {
            notice = "The agent \"\(record.agentName)\" no longer exists."
            return
        }
        if record.kind == .terminal {
            startTerminal(agent: agent, task: record.task, workingDirectory: record.workingDirectory)
        } else {
            let model = newConversation(workingDirectory: record.workingDirectory)
            if let task = record.task, !task.isEmpty { send("@\(agent.handle) \(task)", in: model) }
        }
    }

    func deleteHistory(_ record: SessionRecord) {
        historyStore.delete(record.id)
        history.removeAll { $0.id == record.id }
        if selection == .history(record.id) { selection = .board }
    }

    func clearHistory() {
        let open = Set(terminals.map(\.id))
        for record in history where !open.contains(record.id) { historyStore.delete(record.id) }
        history.removeAll { !open.contains($0.id) }
        if case .history = selection { selection = .board }
    }

    private func persist(_ session: TerminalSession) {
        let record = session.record()
        if !isDemo { try? historyStore.save(record) }
        history.removeAll { $0.id == record.id }
        history.insert(record, at: 0)
    }

    // MARK: Board

    struct BoardItem: Identifiable {
        enum Target { case run(conversationID: UUID), terminal }
        let id: UUID
        let title: String
        let subtitle: String
        let agentID: UUID
        let symbol: String
        let status: SessionStatus
        let date: Date
        let target: Target
    }

    /// Runs from the last two days plus live terminals.
    var boardItems: [BoardItem] {
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        var items: [BoardItem] = []
        for model in conversations {
            for run in model.conversation.runs where run.isActive || run.startedAt > cutoff {
                items.append(BoardItem(
                    id: run.id, title: model.conversation.title, subtitle: run.agentName, agentID: run.agentID,
                    symbol: run.agentSymbol, status: run.status, date: run.startedAt, target: .run(conversationID: model.id)
                ))
            }
        }
        for session in terminals {
            items.append(BoardItem(
                id: session.id, title: session.title, subtitle: "Terminal · \(session.agent.name)", agentID: session.agent.id,
                symbol: session.agent.symbol, status: session.status, date: session.createdAt, target: .terminal
            ))
        }
        return items.sorted { $0.date > $1.date }
    }

    func open(_ item: BoardItem) {
        switch item.target {
        case let .run(conversationID): selection = .chat(conversationID)
        case .terminal: if let session = terminal(id: item.id) { select(session) }
        }
    }

    struct ActiveRun: Identifiable {
        let conversation: ConversationModel
        let run: AgentRun
        var id: UUID { run.id }
    }

    /// Runs in progress across all chats, for the menu bar.
    var activeRuns: [ActiveRun] {
        conversations.flatMap { model in model.conversation.activeRuns.map { ActiveRun(conversation: model, run: $0) } }
    }

    // MARK: Usage

    var allUsage: [UsageRecord] { apiUsage + logUsage }

    /// Re-reads Claude Code and Codex logs from the last 31 days.
    func refreshUsage() {
        guard !isDemo else { return }
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

    var todaySummary: UsageSummary {
        usageSummary(since: Calendar.current.startOfDay(for: Date()))
    }

    private func recordUsage(_ usage: TokenUsage, model: String, source: String) {
        let record = UsageRecord(source: source, model: model, date: Date(), usage: usage)
        apiUsage.append(record)
        if !isDemo { try? usageStore.append(record) }
    }

    /// Demo data hook.
    func seedDemo(conversations: [Conversation], usage: [UsageRecord]) {
        self.conversations = conversations.map(ConversationModel.init)
        apiUsage = usage
        lastUsageScan = Date()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
