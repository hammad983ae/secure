import AgentHubCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A conversation with one or more agents.
struct ChatScreen: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(model: model)
            WorktreeBar(model: model)
            if model.conversation.entries.isEmpty {
                ChatWelcome(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timeline
            }
            Composer(model: model)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .padding(.top, 8)
        }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(items) { item in
                        Group {
                            switch item {
                            case let .user(entry):
                                UserBubble(text: entry.text, date: entry.date, attachments: entry.attachments ?? [])
                            case let .run(run):
                                RunCard(run: run, model: model)
                            case let .compare(runs):
                                CompareRow(runs: runs, model: model)
                            }
                        }
                        .id(item.id)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.conversation.entries.count)
            }
            .scrollIndicators(.automatic)
            .onAppear {
                if !scrollToTarget(proxy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: state.scrollTarget) { _, _ in _ = scrollToTarget(proxy) }
            .onChange(of: model.conversation.updatedAt) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Scrolls to a search result in this chat, if one is pending.
    private func scrollToTarget(_ proxy: ScrollViewProxy) -> Bool {
        guard let target = state.scrollTarget,
              let item = items.first(where: { $0.contains(target) }) else { return false }
        state.scrollTarget = nil
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(item.id, anchor: .center) }
        }
        return true
    }

    /// Entries, with `/compare` runs grouped into one side-by-side row.
    private var items: [TimelineItem] {
        var result: [TimelineItem] = []
        var groups: [UUID: Int] = [:]
        for entry in model.conversation.entries {
            if let run = entry.run {
                if let group = run.compareGroup {
                    if let index = groups[group], case var .compare(runs) = result[index] {
                        runs.append(run)
                        result[index] = .compare(runs)
                    } else {
                        groups[group] = result.count
                        result.append(.compare([run]))
                    }
                } else {
                    result.append(.run(run))
                }
            } else {
                result.append(.user(entry))
            }
        }
        return result
    }
}

enum TimelineItem: Identifiable {
    case user(ConversationEntry)
    case run(AgentRun)
    case compare([AgentRun])

    var id: UUID {
        switch self {
        case let .user(entry): return entry.id
        case let .run(run): return run.id
        case let .compare(runs): return runs[0].id
        }
    }

    func contains(_ entryID: UUID) -> Bool {
        switch self {
        case let .compare(runs): return runs.contains { $0.id == entryID }
        default: return id == entryID
        }
    }
}

/// `/compare` results side by side, with time, cost, and a button to keep one.
struct CompareRow: View {
    @Environment(AppState.self) private var state
    let runs: [AgentRun]
    let model: ConversationModel
    @State private var picking = false

    private var finished: Bool { !runs.contains(where: \.isActive) }
    private var hasPick: Bool { runs.contains { $0.picked == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.3x1").foregroundStyle(Theme.cyan)
                Text("Compare").hudLabel()
                Spacer()
                if !finished {
                    Text("Running…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                } else if !hasPick {
                    Text("Pick the result to keep").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 8) {
                            CompareStats(run: run, fastest: fastest, cheapest: cheapest)
                            RunCard(run: run, model: model, compact: true)
                            pickButton(run)
                        }
                        .frame(width: columnWidth)
                        .opacity(hasPick && run.picked != true ? 0.55 : 1)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var columnWidth: CGFloat { runs.count <= 2 ? 410 : 300 }

    @ViewBuilder
    private func pickButton(_ run: AgentRun) -> some View {
        if run.picked == true {
            Label("Picked", systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.emerald)
        } else if !hasPick {
            Button {
                picking = true
                Task {
                    await state.pick(runID: run.id, in: model)
                    picking = false
                }
            } label: {
                Label("Pick this", systemImage: "hand.thumbsup.fill")
            }
            .buttonStyle(NeonButtonStyle())
            .disabled(!finished || picking || run.status == .failed)
            .help(model.conversation.participant(run.agentID)?.worktreePath != nil
                  ? "Applies this agent's changes to the chat folder and discards the others'"
                  : "Keeps this result and continues the chat with this agent")
        }
    }

    private var fastest: UUID? {
        runs.filter { $0.finishedAt != nil && $0.status == .done }
            .min { duration($0) < duration($1) }?.id
    }

    private var cheapest: UUID? {
        let costs = runs.compactMap { run -> (UUID, Double)? in
            guard run.status == .done, let cost = CompareStats.cost(of: run) else { return nil }
            return (run.id, cost)
        }
        guard costs.count > 1 else { return nil }
        return costs.min { $0.1 < $1.1 }?.0
    }

    private func duration(_ run: AgentRun) -> TimeInterval {
        (run.finishedAt ?? Date()).timeIntervalSince(run.startedAt)
    }
}

struct CompareStats: View {
    let run: AgentRun
    let fastest: UUID?
    let cheapest: UUID?

    static func cost(of run: AgentRun) -> Double? {
        run.reportedCost ?? run.model.flatMap { ModelPricing.cost(model: $0, usage: run.usage) }
    }

    var body: some View {
        HStack(spacing: 10) {
            stat("clock", run.finishedAt.map { CompareStats.duration(run.startedAt, $0) } ?? "…", best: fastest == run.id)
            stat("bolt.fill", Formatters.tokens(run.usage.total), best: false)
            stat("dollarsign.circle", CompareStats.cost(of: run).map(Formatters.cost) ?? "—", best: cheapest == run.id)
            if let files = run.changes?.files.count {
                stat("doc.on.doc", "\(files) file\(files == 1 ? "" : "s")", best: false)
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
    }

    private func stat(_ symbol: String, _ value: String, best: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(value)
        }
        .foregroundStyle(best ? Theme.emerald : Theme.textSecondary)
        .help(best ? "Best of the compared runs" : "")
    }

    static func duration(_ start: Date, _ end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// Agents working in their own git worktrees, with Apply and Discard.
struct WorktreeBar: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel
    @State private var busy: UUID?

    var body: some View {
        let worktrees = state.worktrees(in: model)
        if !worktrees.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.violet)
                Text("Worktrees").hudLabel()
                ForEach(worktrees) { info in
                    HStack(spacing: 6) {
                        AgentAvatar(symbol: info.symbol, color: AgentColors.color(id: info.agentID), size: 16)
                        Text(info.agentName).font(.system(size: 11.5, weight: .medium))
                        Button("Apply") { act(info) { await state.applyWorktree(agentID: info.agentID, in: model) } }
                            .help("Copy this agent's changes into the chat folder and remove its worktree")
                        Button("Discard") { act(info) { await state.discardWorktree(agentID: info.agentID, in: model) } }
                            .help("Delete this agent's worktree and its changes")
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: info.path)])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help(info.path)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                    .disabled(busy != nil || model.isBusy)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(alignment: .bottom) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
        }
    }

    private func act(_ info: AppState.WorktreeInfo, _ action: @escaping () async -> Void) {
        busy = info.agentID
        Task {
            await action()
            busy = nil
        }
    }
}

struct ChatHeader: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.conversation.title)
                    .font(Theme.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(model.conversation.participants, id: \.agentID) { participant in
                        if let agent = state.agent(id: participant.agentID) {
                            HStack(spacing: 4) {
                                AgentAvatar(symbol: agent.symbol, color: AgentColors.color(for: agent), size: 14)
                                Text(agent.name).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    if model.conversation.participants.isEmpty {
                        Text("No agents yet").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            Spacer()
            FolderChip(model: model)
            Toggle(isOn: Binding(
                get: { model.conversation.isolateAgents == true },
                set: { state.setIsolation($0, for: model) }
            )) {
                Image(systemName: "arrow.triangle.branch")
            }
            .toggleStyle(.button)
            .help("Give each terminal agent its own git worktree in this chat. Apply the changes you want from the bar that appears.")
            ExportMenu(model: model)
            if !model.conversation.usage.isEmpty {
                UsagePill(usage: model.conversation.usage, model: nil)
            }
            if model.isBusy {
                Button {
                    state.stopAll(in: model)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }
}

/// Save or copy the chat as Markdown.
struct ExportMenu: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    var body: some View {
        Menu {
            Button("Save as Markdown…", action: save)
            Button("Copy as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.markdown(for: model), forType: .string)
                state.notice = "Copied the chat as Markdown."
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.conversation.entries.isEmpty)
        .help("Export this chat as Markdown")
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let safe = model.conversation.title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        panel.nameFieldStringValue = "\(safe).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.markdown(for: model).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state.notice = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Shows and changes the folder terminal agents work in.
struct FolderChip: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.cyan)
                Text(label).lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: 220)
        }
        .buttonStyle(GlassButtonStyle())
        .help(model.conversation.workingDirectory ?? "Choose the folder agents work in")
    }

    private var label: String {
        guard let path = model.conversation.workingDirectory, !path.isEmpty else { return "Choose folder" }
        return (path as NSString).lastPathComponent
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            state.setWorkingDirectory(url.path, for: model)
        }
    }
}

/// Empty-chat hero with suggestions.
struct ChatWelcome: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    private struct Suggestion: Hashable {
        let mention: String
        let text: String
    }

    private let suggestions = [
        Suggestion(mention: "@claude", text: "Explain how this codebase is structured"),
        Suggestion(mention: "@codex", text: "Find and fix the failing tests"),
        Suggestion(mention: "@claude @codex", text: "Each propose a refactor for the slowest module"),
        Suggestion(mention: "@shell", text: "git status && git log --oneline -5"),
    ]

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.violet.opacity(0.55), Theme.violet.opacity(0)], center: .center, startRadius: 20, endRadius: 70))
                    .frame(width: 140, height: 140)
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(Theme.accentWide))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.3)))
            }
            VStack(spacing: 8) {
                Text("What should your agents work on?")
                    .font(Theme.display(30))
                    .multilineTextAlignment(.center)
                Text("Mention an agent with @, or just describe the task and Agent Hub picks one.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        state.send("\(suggestion.mention) \(suggestion.text)", in: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(suggestion.mention).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.cyan)
                            Text(suggestion.text).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.leading)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                        .glassCard(radius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 620)
            HStack(spacing: 8) {
                ForEach(state.chatAgents.prefix(7)) { agent in
                    VStack(spacing: 5) {
                        AgentAvatar(symbol: agent.symbol, color: AgentColors.color(for: agent), size: 34)
                        Text("@\(agent.handle)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: 74)
                    .opacity(state.isInstalled(agent) == false ? 0.35 : 1)
                }
            }
            Spacer()
        }
        .padding(30)
    }
}

// MARK: - Entries

struct UserBubble: View {
    let text: String
    let date: Date
    var attachments: [String] = []

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 4) {
                MentionText(text: text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.cyan.opacity(0.28), Theme.violet.opacity(0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong))
                if !attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { path in
                            AttachmentChip(path: path)
                        }
                    }
                }
                Text(date, format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Highlights `@mentions` in a message.
struct MentionText: View {
    let text: String

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in words.enumerated() {
            var part = AttributedString(String(word))
            if word.hasPrefix("@"), word.count > 1 {
                part.swiftUI.foregroundColor = Theme.cyan
                part.swiftUI.font = .system(size: 13.5, weight: .semibold)
            }
            result += part
            if index < words.count - 1 { result += AttributedString(" ") }
        }
        return result
    }
}

/// One agent's reply: header, streamed text, tool steps, and actions.
struct RunCard: View {
    @Environment(AppState.self) private var state
    let run: AgentRun
    let model: ConversationModel
    /// Inside a compare row: narrower, without the duration (shown above it).
    var compact = false

    private var color: Color { AgentColors.color(id: run.agentID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if run.messages.isEmpty && run.isActive {
                ThinkingIndicator(color: color)
            }
            ForEach(run.messages) { message in
                RunMessageView(message: message, accent: color)
            }
            if let changes = run.changes {
                ChangesView(changes: changes, runID: run.id, model: model)
            }
            if !run.isActive {
                footer
            }
        }
        .padding(16)
        .glassCard(radius: 16, tint: color, glow: run.isActive)
        .animation(.easeOut(duration: 0.2), value: run.messages.count)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentAvatar(symbol: run.agentSymbol, color: color, size: 30, active: run.status == .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.agentName).font(.system(size: 13, weight: .semibold))
                if let model = run.model, !model.isEmpty {
                    Text(model).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                }
            }
            StatusBadge(status: run.status, compact: compact)
            if let step = run.pipelineStep {
                Text("Step \(step)")
                    .font(Theme.label)
                    .foregroundStyle(Theme.violet)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.violet.opacity(0.14)))
                    .help("Part of a pipeline")
            }
            Spacer()
            if !compact, !run.usage.isEmpty || run.reportedCost != nil {
                UsagePill(usage: run.usage, model: run.model, cost: run.reportedCost)
            }
            if run.isActive {
                IconButton(symbol: "stop.fill", help: "Stop", tint: Theme.rose) {
                    state.stop(runID: run.id, in: model)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !compact, let finished = run.finishedAt {
                Text(durationText(from: run.startedAt, to: finished))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if let agent = state.agent(id: run.agentID), agent.runsInTerminal {
                Button {
                    state.openInTerminal(run, in: model)
                } label: {
                    Label(compact ? "Terminal" : "Open in Terminal", systemImage: "terminal")
                }
                .buttonStyle(GlassButtonStyle())
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.replyText, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(run.replyText.isEmpty)
        }
    }

    private func durationText(from start: Date, to end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

struct ThinkingIndicator: View {
    let color: Color
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .opacity(0.3 + 0.7 * max(0, sin(phase + Double(index) * 0.9)))
            }
            Text("Working…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
    }
}

struct RunMessageView: View {
    let message: ChatMessage
    let accent: Color

    var body: some View {
        switch message.role {
        case .assistant:
            MarkdownView(text: message.text)
        case .output:
            ScrollView(.horizontal) {
                Text(message.text.trimmingCharacters(in: .newlines))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.codeBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        case .tool:
            ToolStepView(message: message)
        case .system:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text(message.text).textSelection(.enabled)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        case .user:
            Text(message.text)
        }
    }
}

/// A tool call: one line with status; expands to input and output.
struct ToolStepView: View {
    @Environment(AppState.self) private var state
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    stateIcon.frame(width: 14)
                    Text(displayName).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if message.toolState == .awaitingApproval {
                HStack(spacing: 8) {
                    Text("Allow this tool call?").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.amber)
                    Spacer()
                    Button("Deny") { state.resolveApproval(messageID: message.id, approved: false) }
                        .buttonStyle(GlassButtonStyle())
                    Button("Allow") { state.resolveApproval(messageID: message.id, approved: true) }
                        .buttonStyle(NeonButtonStyle())
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let args = message.toolArguments, !args.isEmpty {
                        Text(args).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    if !message.text.isEmpty {
                        Divider().overlay(Theme.stroke)
                        Text(message.text.prefix(4000)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.codeBackground))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(borderColor))
    }

    private var displayName: String {
        let name = message.toolName ?? "tool"
        // MCP tools are exposed as server__tool.
        return name.replacingOccurrences(of: "__", with: " › ")
    }

    private var detail: String {
        (message.toolArguments ?? "").replacingOccurrences(of: "\n", with: " ")
    }

    private var borderColor: Color {
        message.toolState == .awaitingApproval ? Theme.amber.opacity(0.6) : Theme.stroke
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch message.toolState {
        case .awaitingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber)
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark").foregroundStyle(Theme.emerald)
        case .failed: Image(systemName: "xmark").foregroundStyle(Theme.rose)
        case .denied: Image(systemName: "nosign").foregroundStyle(Theme.textTertiary)
        case nil: Image(systemName: "wrench.and.screwdriver")
        }
    }
}

struct UsagePill: View {
    let usage: TokenUsage
    let model: String?
    var cost: Double? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill").foregroundStyle(Theme.cyan)
            Text(Formatters.tokens(usage.total))
            if let shown = cost ?? model.flatMap({ ModelPricing.cost(model: $0, usage: usage) }) {
                Text("·").foregroundStyle(Theme.textTertiary)
                Text(Formatters.cost(shown))
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.surfaceRaised))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .help("In \(usage.input) · out \(usage.output) · cache read \(usage.cacheRead) · cache write \(usage.cacheWrite)")
    }
}

/// A file attached to a message: an image thumbnail or a file icon and name.
struct AttachmentChip: View {
    let path: String
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            if Attachments.isImage(path), let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.surfaceRaised))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .help(path)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }
}
