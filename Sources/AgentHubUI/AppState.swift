import AgentHubCore
import AppKit
import Foundation
import Observation
import SystemConfiguration
import WidgetKit

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
    /// Streamed text not yet shown, by run id. Flushed a few times a second so
    /// the chat isn't re-rendered for every token.
    @ObservationIgnored var pendingText: [UUID: String] = [:]
    @ObservationIgnored var flushScheduled = false
    var unread = false
    /// A running pipeline (`@a … → @b …`), which starts one run after another.
    var pipelineTask: Task<Void, Never>?

    init(_ conversation: Conversation) {
        self.id = conversation.id
        self.conversation = conversation
    }

    var isBusy: Bool { !tasks.isEmpty || pipelineTask != nil }
}

enum SidebarItem: Hashable {
    case chat(UUID)
    case terminal(UUID)
    case board
    case usage
    case search
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
    /// App Support/AgentHub (or a temporary folder in demo mode).
    private let directory: URL
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
    /// Chat entry to scroll to after opening a search result.
    var scrollTarget: UUID?
    /// Bumped when worktrees are created, applied, or discarded.
    private(set) var worktreeVersion = 0

    /// Usage from Agent Hub's own API calls.
    private(set) var apiUsage: [UsageRecord] = []
    /// Usage read from Claude Code and Codex logs.
    private(set) var logUsage: [UsageRecord] = []
    /// Bumped whenever usage records change; summaries are cached per version.
    private var usageVersion = 0
    @ObservationIgnored private var summaryCache: [Date: UsageSummary] = [:]
    @ObservationIgnored private var summaryCacheVersion = -1
    private(set) var isScanningUsage = false
    private(set) var lastUsageScan: Date?

    private var toolbox: MCPToolbox?
    private var pendingApprovals: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var refreshTimer: Timer?
    /// Opens a main window (set by a view that has SwiftUI's `openWindow`).
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var quickPrompt: QuickPromptController?
    @ObservationIgnored private var scheduleTimer: Timer?
    @ObservationIgnored private var remoteServer: RemoteServer?
    @ObservationIgnored private var remoteServerPort: Int?
    @ObservationIgnored private var remoteFailures: [Date] = []
    /// nil while stopped or running fine; an error message if the server couldn't start.
    private(set) var remoteError: String?
    private(set) var remoteToken: String = ""

    init(demo: Bool = false) {
        isDemo = demo
        let directory: URL
        if demo {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHubDemo-\(UUID().uuidString)")
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = support.appendingPathComponent("AgentHub", isDirectory: true)
        }
        self.directory = directory
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
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUsage() }
            }
            scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.runDueSchedules() }
            }
            remoteToken = KeychainStore.read(account: Self.remoteTokenAccount) ?? ""
            updateRemoteServer()
        }
        applyAppearance()
        if !demo { updateHotKey() }
        if let recent = sortedConversations.first(where: { !$0.conversation.entries.isEmpty }) {
            selection = .chat(recent.id)
        } else {
            newConversation()
        }
    }

    // MARK: Configuration

    func updateConfig(_ change: (inout HubConfiguration) -> Void) {
        var updated = config
        change(&updated)
        // No-op writes must not touch observed state: SwiftUI bindings (like the
        // menu bar item's) can write back their current value during updates,
        // and reacting to that re-renders the scene, which writes again.
        guard updated != config else { return }
        let oldServers = config.mcpServers
        let oldAgents = config.agents
        config = updated
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
        if config.agents != oldAgents { refreshInstalledAgents() }
        applyAppearance()
        if !isDemo {
            updateHotKey()
            updateRemoteServer()
        }
    }

    // MARK: Appearance and quick prompt

    private func applyAppearance() {
        AccentStore.current = config.accent
        let appearance: NSAppearance?
        switch config.appearance {
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .light: appearance = NSAppearance(named: .aqua)
        case .system: appearance = nil
        }
        let app = NSApplication.shared
        if app.appearance?.name != appearance?.name { app.appearance = appearance }
    }

    private func updateHotKey() {
        if config.globalHotKey {
            GlobalHotKey.shared.onPress = { [weak self] in self?.toggleQuickPrompt() }
            GlobalHotKey.shared.register()
        } else {
            GlobalHotKey.shared.unregister()
            quickPrompt?.close()
        }
    }

    func toggleQuickPrompt() {
        if quickPrompt == nil { quickPrompt = QuickPromptController(state: self) }
        quickPrompt?.toggle()
    }

    /// Brings the main window forward, opening one if it was closed.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    func refreshInstalledAgents() {
        guard !isDemo else { return }
        let commands = config.agents.filter(\.runsInTerminal).map(\.command)
        Task {
            let found = await AgentAvailability.installed(commands)
            if found != installedCommands { installedCommands = found }
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
        let worktreePaths = model.conversation.participants.compactMap(\.worktreePath)
        if !worktreePaths.isEmpty {
            let folder = nonEmpty(model.conversation.workingDirectory) ?? nonEmpty(config.defaultWorkingDirectory)
            Task.detached(priority: .utility) {
                let root = folder.flatMap(GitWorkspace.root(of:))
                for path in worktreePaths {
                    if let root { try? GitWorkspace.removeWorktree(path: path, root: root) } else { try? FileManager.default.removeItem(atPath: path) }
                }
            }
        }
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
    /// - `@a task → @b task` runs a pipeline, one step after another.
    /// - `/compare @a @b task` runs the agents side by side, each in its own worktree.
    /// - no mention: goes to the agent addressed last, or is auto-routed.
    func send(_ input: String, attachments: [String] = [], in model: ConversationModel) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if text.isEmpty { text = "Take a look at the attached files." }
        notice = nil
        let handles = Set(chatAgents.map { $0.handle.lowercased() })

        if let rest = Self.dropCommand("schedule", from: text) {
            addSchedule(from: rest, in: model)
            return
        }
        var compare = false
        if let rest = Self.dropCommand("compare", from: text) {
            compare = true
            text = rest
        } else if text.hasPrefix("/") {
            // `/name …` runs a saved prompt.
            guard let expanded = PromptLibrary.expand(text, prompts: config.prompts, knownHandles: handles) else {
                notice = "No saved prompt named \(text.split(separator: " ").first ?? ""). Add one in Settings → Prompts."
                return
            }
            text = expanded
        }

        if !compare, let steps = PipelineParser.parse(text, knownHandles: handles) {
            appendUserEntry(text, attachments: attachments, in: model)
            runPipeline(steps, attachments: attachments, in: model)
            return
        }

        let command = CommandParser.chatCommand(text, knownHandles: handles)
        let task = command.task.isEmpty ? text : command.task

        var targets: [AgentDefinition]
        if command.mentionsAll {
            targets = model.conversation.participants.compactMap { agent(id: $0.agentID) }
            if targets.isEmpty { notice = "No agents in this chat yet. Mention one, like @claude."; return }
        } else if !command.mentions.isEmpty {
            targets = command.mentions.compactMap { agent(handle: $0) }
        } else if let last = model.conversation.lastAgentID, let agent = agent(id: last), !compare {
            targets = [agent]
        } else {
            targets = []
        }
        var seenIDs = Set<UUID>()
        targets = targets.filter { seenIDs.insert($0.id).inserted }

        if compare, targets.count < 2 {
            notice = "Compare needs two or more agents, like /compare @claude @codex fix the login bug."
            return
        }

        appendUserEntry(compare ? "/compare \(text)" : text, attachments: attachments, in: model)

        if targets.isEmpty {
            if config.autoRoute {
                route(task, in: model)
            } else {
                notice = "Mention an agent to start, like @claude or @codex."
            }
            return
        }
        let group = compare ? UUID() : nil
        for agent in targets {
            startRun(agent: agent, task: task, attachments: attachments, compareGroup: group, in: model)
        }
    }

    /// `/compare rest` → `rest`; nil if `text` isn't that command.
    static func dropCommand(_ name: String, from text: String) -> String? {
        let prefix = "/" + name
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendUserEntry(_ text: String, attachments: [String], in model: ConversationModel) {
        if model.conversation.entries.isEmpty { model.conversation.title = Conversation.title(from: text) }
        model.conversation.entries.append(.user(text, attachments: attachments))
        model.conversation.updatedAt = Date()
        persist(model)
    }

    /// Runs pipeline steps one after another; each step sees the earlier
    /// steps' replies through the conversation context. Stops at the first
    /// step that fails or is stopped.
    private func runPipeline(_ steps: [PipelineStep], attachments: [String], in model: ConversationModel) {
        guard model.pipelineTask == nil else {
            notice = "A pipeline is already running in this chat."
            return
        }
        model.pipelineTask = Task { [weak self] in
            defer { model.pipelineTask = nil }
            guard let self else { return }
            for (index, step) in steps.enumerated() {
                guard !Task.isCancelled, let agent = self.agent(handle: step.handle) else { break }
                let label = "\(index + 1)/\(steps.count)"
                guard let runID = self.startRun(
                    agent: agent,
                    task: PipelineParser.prompt(for: step, index: index, total: steps.count),
                    attachments: index == 0 ? attachments : [],
                    pipelineStep: label,
                    in: model
                ) else { break }
                await model.tasks[runID]?.value
                let status = model.conversation.entries.first { $0.id == runID }?.run?.status
                if status != .done {
                    if !Task.isCancelled, index < steps.count - 1 {
                        self.notice = "Pipeline stopped: step \(label) (\(agent.name)) didn't finish."
                    }
                    break
                }
            }
        }
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
        model.pipelineTask?.cancel()
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

    @discardableResult
    private func startRun(
        agent baseAgent: AgentDefinition, task: String, attachments: [String] = [],
        compareGroup: UUID? = nil, pipelineStep: String? = nil, in model: ConversationModel
    ) -> UUID? {
        if let blocking = BudgetEvaluator.blockingBudget(for: baseAgent, statuses: budgetStatuses) {
            notice = "\(baseAgent.name) wasn't started: \(budgetName(blocking.budget)) budget is used up. Change it in Settings → Budgets."
            return nil
        }
        var agent = baseAgent
        if agent.runsInTerminal {
            agent.workingDirectory = nonEmpty(model.conversation.workingDirectory)
                ?? nonEmpty(agent.workingDirectory)
                ?? nonEmpty(config.defaultWorkingDirectory)
        }
        let prompt = ConversationContext.prompt(task: task, for: agent.id, in: model.conversation)

        var run = AgentRun(agent: agent)
        run.compareGroup = compareGroup
        run.pipelineStep = pipelineStep
        // Everything finished so far has now been shared with this agent.
        let firstActiveOther = model.conversation.entries.firstIndex {
            ($0.run?.isActive ?? false) && $0.run?.agentID != agent.id
        }
        let seen = firstActiveOther ?? model.conversation.entries.count
        model.conversation.entries.append(.run(run))
        model.conversation.lastAgentID = agent.id
        model.conversation.updateParticipant(agent.id) { $0.seenEntryCount = seen }
        scheduleWidgetUpdate()

        if agent.kind == .api {
            startAPIRun(agent: agent, prompt: prompt, attachments: attachments, runID: run.id, in: model)
        } else {
            let isolate = compareGroup != nil || model.conversation.isolateAgents == true
            startHeadlessRun(agent: agent, prompt: Attachments.headlessPrompt(text: prompt, attachments: attachments),
                             isolate: isolate, runID: run.id, in: model)
        }
        return run.id
    }

    private func startAPIRun(agent: AgentDefinition, prompt: String, attachments: [String], runID: UUID, in model: ConversationModel) {
        let previous = model.conversation.participant(agent.id)?.transcript ?? []
        let userMessage = Attachments.userMessage(text: prompt, attachments: attachments, provider: agent.provider ?? .anthropic)
        let transcript = previous + [userMessage]
        // Saved history keeps file paths rather than image data.
        let savedMessage = ChatProtocol.userMessage(Attachments.headlessPrompt(text: prompt, attachments: attachments))
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
                model.conversation.updateParticipant(agent.id) { $0.transcript = previous + [savedMessage] + appended }
            } catch {
                failed = !(error is CancellationError || Task.isCancelled)
                let text = failed ? error.localizedDescription : "Stopped."
                model.conversation.updateRun(runID) { $0.messages.append(ChatMessage(role: .system, text: text)) }
            }
            self?.finishRun(runID, failed: failed, in: model)
        }
    }

    private func startHeadlessRun(agent baseAgent: AgentDefinition, prompt: String, isolate: Bool, runID: UUID, in model: ConversationModel) {
        if baseAgent.headless == .claudeCode, !config.mcpServers.isEmpty, !isDemo { try? store.save(config) }
        let runner = headlessRunner

        model.tasks[runID] = Task { [weak self] in
            var agent = baseAgent
            if isolate, let folder = agent.workingDirectory, let self {
                if let worktree = await self.worktree(for: agent, folder: folder, runID: runID, in: model) {
                    agent.workingDirectory = worktree
                }
            }
            guard let spec = self?.headlessSpec(agent: agent, prompt: prompt, in: model) else {
                model.conversation.updateRun(runID) {
                    $0.messages.append(ChatMessage(role: .system, text: "\(agent.name) can't run from chat. Open it in a terminal instead."))
                }
                self?.finishRun(runID, failed: true, in: model)
                return
            }
            let folder = agent.workingDirectory

            // Snapshot the git working tree first so the run's edits can be shown and undone.
            let before: (root: String, tree: String)? = await Task.detached(priority: .userInitiated) {
                guard let folder, let root = GitWorkspace.root(of: folder), let tree = try? GitWorkspace.snapshot(root: root) else { return nil }
                return (root, tree)
            }.value

            var failed = false
            do {
                for try await event in runner.run(spec, style: agent.headless) {
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
            if let before {
                let changes = await Task.detached(priority: .userInitiated) { () -> RunChanges? in
                    guard let after = try? GitWorkspace.snapshot(root: before.root) else { return nil }
                    return try? GitWorkspace.changes(from: before.tree, to: after, root: before.root)
                }.value
                if let changes { model.conversation.updateRun(runID) { $0.changes = changes } }
            }
            self?.finishRun(runID, failed: failed, in: model)
        }
    }

    private func headlessSpec(agent: AgentDefinition, prompt: String, in model: ConversationModel) -> LaunchSpec? {
        LaunchPlanner.headless(
            agent: agent, prompt: prompt, resumeID: model.conversation.participant(agent.id)?.resumeID,
            mcpServers: config.mcpServers, mcpConfigPath: store.mcpConfigURL.path, shell: shell
        )
    }

    // MARK: Worktrees

    /// The agent's own worktree for this chat, created on first use from the
    /// chat folder's current files. nil (with a note on the run) if the
    /// folder isn't in a git repository.
    private func worktree(for agent: AgentDefinition, folder: String, runID: UUID, in model: ConversationModel) async -> String? {
        if let existing = model.conversation.participant(agent.id)?.worktreePath,
           FileManager.default.fileExists(atPath: existing) {
            return existing
        }
        let name = "\(model.id.uuidString.prefix(8))-\(agent.handle.lowercased())"
        let path = directory.appendingPathComponent("worktrees", isDirectory: true).appendingPathComponent(name).path
        let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error>? in
            guard let root = GitWorkspace.root(of: folder) else { return nil }
            if FileManager.default.fileExists(atPath: path) { try? GitWorkspace.removeWorktree(path: path, root: root) }
            return Result(catching: { try GitWorkspace.createWorktree(from: root, at: path) })
        }.value
        switch result {
        case let .success(base):
            model.conversation.updateParticipant(agent.id) {
                $0.worktreePath = path
                $0.worktreeBase = base
                // Agent sessions are tied to their folder, so start a fresh one.
                $0.resumeID = nil
            }
            worktreeVersion += 1
            model.conversation.updateRun(runID) {
                $0.messages.append(ChatMessage(role: .system, text: "Working in its own worktree. Apply or discard its changes from the bar at the top of the chat."))
            }
            return path
        case let .failure(error):
            model.conversation.updateRun(runID) {
                $0.messages.append(ChatMessage(role: .system, text: "Couldn't create a worktree (\(error.localizedDescription)), so this run uses the shared folder."))
            }
        case nil:
            model.conversation.updateRun(runID) {
                $0.messages.append(ChatMessage(role: .system, text: "The folder isn't a git repository, so agents share it instead of getting their own worktrees."))
            }
        }
        return nil
    }

    struct WorktreeInfo: Identifiable {
        let agentID: UUID
        let agentName: String
        let symbol: String
        let path: String
        var id: UUID { agentID }
    }

    /// Agents in this chat that have their own worktree.
    func worktrees(in model: ConversationModel) -> [WorktreeInfo] {
        _ = worktreeVersion
        return model.conversation.participants.compactMap { participant in
            guard let path = participant.worktreePath else { return nil }
            let agent = agent(id: participant.agentID)
            return WorktreeInfo(agentID: participant.agentID, agentName: agent?.name ?? "Agent", symbol: agent?.symbol ?? "sparkle", path: path)
        }
    }

    func setIsolation(_ on: Bool, for model: ConversationModel) {
        model.conversation.isolateAgents = on ? true : nil
        persist(model)
    }

    /// Applies an agent's worktree changes to the chat folder, then removes the worktree.
    @discardableResult
    func applyWorktree(agentID: UUID, in model: ConversationModel) async -> Bool {
        guard let participant = model.conversation.participant(agentID),
              let path = participant.worktreePath, let base = participant.worktreeBase,
              let folder = nonEmpty(model.conversation.workingDirectory) ?? nonEmpty(config.defaultWorkingDirectory) else { return false }
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let root = GitWorkspace.root(of: folder) else { return "The chat folder isn't a git repository." }
            do {
                try GitWorkspace.applyWorktree(path: path, base: base, into: root)
                try? GitWorkspace.removeWorktree(path: path, root: root)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        let name = agent(id: agentID)?.name ?? "The agent"
        if let error {
            notice = "Couldn't apply \(name)'s changes: \(error). The worktree is still there to review."
            return false
        }
        clearWorktree(agentID: agentID, in: model)
        notice = "Applied \(name)'s changes to \((folder as NSString).lastPathComponent)."
        return true
    }

    /// Deletes an agent's worktree and everything in it.
    func discardWorktree(agentID: UUID, in model: ConversationModel) async {
        guard let path = model.conversation.participant(agentID)?.worktreePath else { return }
        let folder = nonEmpty(model.conversation.workingDirectory) ?? nonEmpty(config.defaultWorkingDirectory)
        await Task.detached(priority: .userInitiated) {
            if let folder, let root = GitWorkspace.root(of: folder) {
                try? GitWorkspace.removeWorktree(path: path, root: root)
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }.value
        clearWorktree(agentID: agentID, in: model)
    }

    private func clearWorktree(agentID: UUID, in model: ConversationModel) {
        model.conversation.updateParticipant(agentID) {
            $0.worktreePath = nil
            $0.worktreeBase = nil
            $0.resumeID = nil
        }
        worktreeVersion += 1
        persist(model)
    }

    // MARK: Compare

    /// Runs in the same `/compare` group, in order.
    func compareRuns(_ group: UUID, in model: ConversationModel) -> [AgentRun] {
        model.conversation.runs.filter { $0.compareGroup == group }
    }

    /// Keeps one compared result: applies its worktree to the chat folder and
    /// discards the other agents' worktrees.
    func pick(runID: UUID, in model: ConversationModel) async {
        guard let winner = model.conversation.entries.first(where: { $0.id == runID })?.run,
              let group = winner.compareGroup else { return }
        let runs = compareRuns(group, in: model)
        guard !runs.contains(where: \.isActive) else { return }
        if model.conversation.participant(winner.agentID)?.worktreePath != nil {
            guard await applyWorktree(agentID: winner.agentID, in: model) else { return }
        }
        for run in runs where run.agentID != winner.agentID {
            await discardWorktree(agentID: run.agentID, in: model)
        }
        for run in runs {
            model.conversation.updateRun(run.id) { $0.picked = run.id == runID }
        }
        model.conversation.lastAgentID = winner.agentID
        persist(model)
    }

    // MARK: Search and export

    func search(_ query: String) -> [SearchHit] {
        ConversationSearch.search(query, in: conversations.map(\.conversation))
    }

    func open(_ hit: SearchHit) {
        guard let model = conversation(id: hit.conversationID) else { return }
        model.unread = false
        selection = .chat(model.id)
        scrollTarget = hit.entryID
    }

    func markdown(for model: ConversationModel) -> String {
        ConversationExporter.markdown(model.conversation)
    }

    /// Saves pasted image data so it can be attached like a file.
    func saveAttachment(_ data: Data, fileExtension: String) -> String? {
        let folder = directory.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).\(fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            notice = "Couldn't save the pasted image: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Diff review

    /// Marks a run's file changes as accepted.
    func keepChanges(runID: UUID, in model: ConversationModel) {
        model.conversation.updateRun(runID) { $0.changes?.state = .kept }
        persist(model)
    }

    /// Restores the files a run changed. Returns paths edited again since the
    /// run (and does nothing) unless `force` is set.
    func undoChanges(runID: UUID, in model: ConversationModel, force: Bool = false) async -> [String] {
        guard let changes = model.conversation.entries.first(where: { $0.id == runID })?.run?.changes else { return [] }
        let result: Result<[String], Error> = await Task.detached(priority: .userInitiated) {
            do {
                if !force {
                    let edited = try GitWorkspace.editedSinceRun(changes)
                    if !edited.isEmpty { return .success(edited) }
                }
                try GitWorkspace.undo(changes)
                return .success([])
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(edited) where !edited.isEmpty:
            return edited
        case .success:
            model.conversation.updateRun(runID) { $0.changes?.state = .undone }
            persist(model)
        case let .failure(error):
            notice = "Couldn't undo: \(error.localizedDescription)"
        }
        return []
    }

    /// Moves buffered streamed text into the visible messages.
    private func flushText(in model: ConversationModel) {
        model.flushScheduled = false
        let pending = model.pendingText
        guard !pending.isEmpty else { return }
        model.pendingText.removeAll()
        for (runID, text) in pending {
            guard let bubble = model.openBubbles[runID] else { continue }
            model.conversation.updateRun(runID) { run in
                if let index = run.messages.lastIndex(where: { $0.id == bubble }) { run.messages[index].text += text }
            }
        }
    }

    private func finishRun(_ runID: UUID, failed: Bool, in model: ConversationModel) {
        defer { scheduleWidgetUpdate() }
        flushText(in: model)
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
        if case .turnFinished = event {
            flushText(in: model)
            model.openBubbles[runID] = nil
        }
        if case let .text(text) = event {
            if model.openBubbles[runID] != nil {
                model.pendingText[runID, default: ""] += text
                if !model.flushScheduled {
                    model.flushScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        MainActor.assumeIsolated { self?.flushText(in: model) }
                    }
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

    // MARK: Scheduled tasks

    /// Runs every enabled schedule whose time has come. A run missed while
    /// the Mac slept or the app was closed happens once, on the next check.
    func runDueSchedules(now: Date = Date()) {
        guard !isDemo else { return }
        for task in config.schedules where task.isDue(at: now) {
            runSchedule(task.id, now: now)
        }
    }

    /// Sends a scheduled task's message into its chat now.
    func runSchedule(_ id: UUID, now: Date = Date()) {
        guard let task = config.schedules.first(where: { $0.id == id }) else { return }
        let model: ConversationModel
        if let existing = task.conversationID.flatMap(conversation(id:)) {
            model = existing
        } else {
            model = ConversationModel(Conversation(
                title: "⏰ \(task.name)",
                workingDirectory: nonEmpty(task.workingDirectory) ?? config.defaultWorkingDirectory
            ))
            conversations.append(model)
        }
        updateConfig { config in
            guard let index = config.schedules.firstIndex(where: { $0.id == id }) else { return }
            config.schedules[index].lastRun = now
            config.schedules[index].conversationID = model.id
        }
        if model.isBusy {
            Notifier.post(title: "Skipped “\(task.name)”", body: "The previous run is still going.")
            return
        }
        send(task.message, in: model)
        model.conversation.title = "⏰ \(task.name)"
        if selectedConversation?.id != model.id { model.unread = true }
        persist(model)
    }

    /// `/schedule every weekday at 9 @codex run the tests` from a chat.
    private func addSchedule(from text: String, in model: ConversationModel) {
        let usage = "Try: /schedule every weekday at 9 @codex run the tests and summarize failures"
        guard let parsed = ScheduleParser.parse(text) else {
            notice = "Couldn't read the schedule. \(usage)"
            return
        }
        let message = parsed.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let handles = Set(chatAgents.map { $0.handle.lowercased() })
        let mentions = CommandParser.chatCommand(message, knownHandles: handles).mentions
        guard !message.isEmpty, !mentions.isEmpty || PipelineParser.parse(message, knownHandles: handles) != nil else {
            notice = "Say which agent should do it. \(usage)"
            return
        }
        let task = ScheduledTask(
            name: Conversation.title(from: CommandParser.chatCommand(message, knownHandles: handles).task),
            message: message,
            rule: parsed.rule,
            workingDirectory: nonEmpty(model.conversation.workingDirectory)
        )
        updateConfig { $0.schedules.append(task) }
        let next = task.nextRun().map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
        notice = "Scheduled: \(parsed.rule.summary.lowercased()). Next run \(next). Results go to a “⏰ \(task.name)” chat. Manage in Settings → Schedules."
    }

    // MARK: Remote access

    static let remoteTokenAccount = "remote-access-token"

    /// The links that pair a phone, one per network address.
    var remotePairingLinks: [String] {
        guard !remoteToken.isEmpty else { return [] }
        let port = config.remotePort
        var hosts = RemoteServer.localAddresses()
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            hosts.append("\(name).local")
        }
        return hosts.map { "http://\($0):\(port)/#token=\(remoteToken)" }
    }

    var isRemoteRunning: Bool { remoteServer != nil && remoteError == nil }

    /// Makes a new pairing token; phones paired with the old one stop working.
    func resetRemoteToken() {
        remoteToken = RemoteAuth.makeToken()
        KeychainStore.write(account: Self.remoteTokenAccount, value: remoteToken)
    }

    private func updateRemoteServer() {
        guard !isDemo else { return }
        let wanted = config.remoteAccess ? config.remotePort : nil
        guard wanted != remoteServerPort else { return }
        remoteServer?.stop()
        remoteServer = nil
        remoteServerPort = nil
        remoteError = nil
        guard let port = wanted else { return }
        if remoteToken.isEmpty { resetRemoteToken() }
        do {
            let server = try RemoteServer(port: port) { [weak self] request in
                await self?.handleRemote(request) ?? .error(503, "Agent Hub is shutting down.")
            }
            server.start { [weak self] error in
                Task { @MainActor in self?.remoteError = error }
            }
            remoteServer = server
            remoteServerPort = port
        } catch {
            remoteError = error.localizedDescription
        }
    }

    private func handleRemote(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "GET", request.path == "/" || request.path == "/index.html" {
            return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(RemoteWebPage.html.utf8))
        }
        guard request.path.hasPrefix("/api/") else { return .error(404, "Not found") }

        // Slow down token guessing: after 10 bad tokens in a minute, refuse for a while.
        let now = Date()
        remoteFailures.removeAll { now.timeIntervalSince($0) > 60 }
        guard remoteFailures.count < 10 else { return .error(429, "Too many attempts. Try again in a minute.") }
        guard RemoteAuth.matches(request.bearerToken, remoteToken) else {
            remoteFailures.append(now)
            return .error(401, "Not paired")
        }

        let decoder = JSONDecoder()
        switch (request.method, request.path) {
        case ("GET", "/api/state"):
            let host = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
            return .json(RemoteSnapshot.make(conversations: conversations.map(\.conversation),
                                              agents: chatAgents.map(\.handle), host: host))
        case ("POST", "/api/approve"):
            guard let body = try? decoder.decode(RemoteCommand.Approve.self, from: request.body) else { return .error(400, "Bad request") }
            resolveApproval(messageID: body.messageID, approved: body.approved)
            return .json(["ok": true])
        case ("POST", "/api/stop"):
            guard let body = try? decoder.decode(RemoteCommand.Stop.self, from: request.body),
                  let model = conversation(id: body.chatID) else { return .error(400, "Bad request") }
            if let runID = body.runID { stop(runID: runID, in: model) } else { stopAll(in: model) }
            return .json(["ok": true])
        case ("POST", "/api/send"):
            guard let body = try? decoder.decode(RemoteCommand.Send.self, from: request.body),
                  !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error(400, "Bad request") }
            let model: ConversationModel
            if let id = body.chatID {
                guard let existing = conversation(id: id) else { return .error(404, "That chat is gone.") }
                model = existing
            } else {
                model = ConversationModel(Conversation(workingDirectory: config.defaultWorkingDirectory))
                conversations.append(model)
            }
            notice = nil
            send(body.text, in: model)
            if model.conversation.entries.isEmpty {
                conversations.removeAll { $0.id == model.id }
                return .error(400, notice ?? "Mention an agent, like @claude.")
            }
            // Explain when nothing started (no agent mentioned, budget used up…).
            let problem = model.isBusy || isRouting ? "" : (notice ?? "")
            return .json(["chatID": model.id.uuidString, "notice": problem])
        default:
            return .error(404, "Not found")
        }
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
        guard config.scanAgentLogs else { logUsage = []; usageVersion += 1; return }
        guard !isScanningUsage else { return }
        isScanningUsage = true
        let scanner = logScanner
        let since = Calendar.current.date(byAdding: .day, value: -31, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        Task {
            let records = await Task.detached(priority: .utility) { scanner.scan(since: since) }.value
            logUsage = records
            usageVersion += 1
            usageDidChange()
            isScanningUsage = false
            lastUsageScan = Date()
        }
    }

    /// Totals since `start`. Cached until the usage records change, because
    /// views (sidebar, menu bar) ask for this on every redraw.
    func usageSummary(since start: Date) -> UsageSummary {
        let version = usageVersion // registers the observation dependency
        if summaryCacheVersion != version {
            summaryCache.removeAll()
            summaryCacheVersion = version
        }
        if let cached = summaryCache[start] { return cached }
        let summary = UsageSummary(records: allUsage, from: start)
        summaryCache[start] = summary
        return summary
    }

    var todaySummary: UsageSummary {
        usageSummary(since: Calendar.current.startOfDay(for: Date()))
    }

    private func recordUsage(_ usage: TokenUsage, model: String, source: String) {
        let record = UsageRecord(source: source, model: model, date: Date(), usage: usage)
        apiUsage.append(record)
        usageVersion += 1
        usageDidChange()
        if !isDemo { try? usageStore.append(record) }
    }

    // MARK: Budgets

    @ObservationIgnored private var budgetCache: (version: Int, budgets: [Budget], statuses: [BudgetStatus])?
    @ObservationIgnored private var notifiedBudgetKeys = Set<String>()

    /// Current use of every budget. Cached until usage or the budgets change.
    var budgetStatuses: [BudgetStatus] {
        let version = usageVersion
        if let cache = budgetCache, cache.version == version, cache.budgets == config.budgets { return cache.statuses }
        let records = allUsage
        let statuses = config.budgets.map { BudgetEvaluator.status(of: $0, records: records, agents: config.agents) }
        budgetCache = (version, config.budgets, statuses)
        return statuses
    }

    /// The most-used budget, for the menu bar.
    var tightestBudget: BudgetStatus? {
        budgetStatuses.max { $0.fraction < $1.fraction }
    }

    func budgetName(_ budget: Budget) -> String {
        let who = budget.agentID.flatMap { agent(id: $0)?.name } ?? "All agents"
        return "\(who) · \(budget.period.title.lowercased())"
    }

    func budgetLimitText(_ budget: Budget) -> String {
        switch budget.limit {
        case let .tokens(limit): return "\(Formatters.tokens(limit)) tokens"
        case let .dollars(limit): return Formatters.cost(limit)
        }
    }

    func budgetUsedText(_ status: BudgetStatus) -> String {
        switch status.budget.limit {
        case .tokens: return Formatters.tokens(Int(status.used))
        case .dollars: return Formatters.cost(status.used)
        }
    }

    /// Notifies once per budget and period when it reaches 80% and again at 100%.
    private func checkBudgets() {
        for status in budgetStatuses where status.fraction >= BudgetStatus.warningFraction {
            let level = status.isExceeded ? "exceeded" : "warning"
            let key = status.periodKey() + level
            guard notifiedBudgetKeys.insert(key).inserted else { continue }
            let name = budgetName(status.budget)
            if status.isExceeded {
                Notifier.post(title: "Budget used up: \(name)",
                              body: "\(budgetUsedText(status)) of \(budgetLimitText(status.budget))" + (status.budget.hardStop ? ". New runs are paused." : "."))
            } else {
                Notifier.post(title: "Budget at \(Int(status.fraction * 100))%: \(name)",
                              body: "\(budgetUsedText(status)) of \(budgetLimitText(status.budget))")
            }
        }
    }

    private func usageDidChange() {
        guard !isDemo else { return }
        checkBudgets()
        scheduleWidgetUpdate()
    }

    // MARK: Widget

    @ObservationIgnored private var widgetUpdateScheduled = false

    /// Writes the widget's summary file and asks WidgetKit to refresh, at most every few seconds.
    func scheduleWidgetUpdate() {
        guard !isDemo, !widgetUpdateScheduled else { return }
        widgetUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.writeWidgetSnapshot() }
        }
    }

    private func writeWidgetSnapshot() {
        widgetUpdateScheduled = false
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let week = usageSummary(since: calendar.date(byAdding: .day, value: -6, to: today) ?? today)
        let todaySummary = self.todaySummary
        let days = (0..<7).map { offset -> Int in
            guard let day = calendar.date(byAdding: .day, value: offset - 6, to: today) else { return 0 }
            return week.daily.filter { calendar.isDate($0.day, inSameDayAs: day) }.reduce(0) { $0 + $1.usage.total }
        }
        var runs = activeRuns.prefix(4).map {
            WidgetSnapshot.Run(agent: $0.run.agentName, symbol: $0.run.agentSymbol, title: $0.conversation.conversation.title, status: $0.run.status)
        }
        runs += terminals.filter { !$0.isFinished }.prefix(max(0, 4 - runs.count)).map {
            WidgetSnapshot.Run(agent: $0.agent.name, symbol: $0.agent.symbol, title: $0.title, status: $0.status)
        }
        let snapshot = WidgetSnapshot(
            todayTokens: todaySummary.total.total,
            todayCost: todaySummary.knownCost,
            weekTokens: week.total.total,
            weekCost: week.knownCost,
            lastSevenDays: days,
            runs: runs,
            budgets: budgetStatuses.prefix(3).map { WidgetSnapshot.BudgetGauge(name: budgetName($0.budget), fraction: $0.fraction) }
        )
        Task.detached(priority: .utility) {
            try? snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Demo data hook.
    func seedDemo(conversations: [Conversation], usage: [UsageRecord]) {
        self.conversations = conversations.map(ConversationModel.init)
        apiUsage = usage
        usageVersion += 1
        lastUsageScan = Date()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
