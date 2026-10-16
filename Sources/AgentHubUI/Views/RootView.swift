import AgentHubCore
import SwiftUI

/// The main window: aurora background, glass sidebar, and the selected screen.
struct RootView: View {
    @Environment(AppState.self) private var state

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        ZStack {
            AuroraBackground()
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 264)
                Rectangle().fill(Theme.stroke).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Accent colors are read when views are built, so rebuild on a palette change.
        .id(state.config.accent)
        .foregroundStyle(Theme.textPrimary)
        .onAppear { state.openMainWindow = { openWindow(id: "main") } }
        .sheet(isPresented: $state.showPalette) {
            CommandPalette()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selection {
        case let .chat(id):
            if let model = state.conversation(id: id) {
                ChatScreen(model: model).id(id)
            } else {
                BoardScreen()
            }
        case let .terminal(id):
            if let panes = state.visibleSplit {
                TerminalSplitScreen(sessions: panes)
            } else if let session = state.terminal(id: id) {
                TerminalScreen(session: session, isFocused: true).id(id)
            } else {
                BoardScreen()
            }
        case .usage:
            UsageScreen()
        case .search:
            SearchScreen()
        case let .history(id):
            if let record = state.historyRecord(id: id) {
                HistoryDetailView(record: record).id(id)
            } else {
                BoardScreen()
            }
        case .board, nil:
            BoardScreen()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 2) {
                        NavRow(title: "Mission Control", symbol: "square.grid.2x2", item: .board,
                               badge: activeCount > 0 ? "\(activeCount)" : nil)
                        NavRow(title: "Usage", symbol: "waveform.path.ecg", item: .usage,
                               badge: usageBadge)
                        NavRow(title: "Search", symbol: "magnifyingglass", item: .search)
                    }

                    section("Chats") {
                        if state.sortedConversations.filter({ !$0.conversation.entries.isEmpty }).isEmpty {
                            Text("Your chats will appear here.")
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 10)
                        }
                        ForEach(state.sortedConversations.filter { !$0.conversation.entries.isEmpty }.prefix(60)) { model in
                            ChatRow(model: model)
                        }
                    }

                    if !state.terminals.isEmpty {
                        section("Terminals") {
                            ForEach(state.terminals) { session in
                                TerminalRow(session: session)
                            }
                        }
                    }

                    if !state.closedHistory.isEmpty {
                        section("History") {
                            ForEach(state.closedHistory.prefix(20)) { record in
                                HistoryRow(record: record)
                            }
                        }
                    }

                    section("Agents") {
                        AgentGrid()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 34) // room for the window's traffic lights
        .background(Theme.void.opacity(0.6))
    }

    private var activeCount: Int {
        state.activeRuns.count + state.terminals.filter { !$0.isFinished }.count
    }

    private var usageBadge: String? {
        let total = state.todaySummary.total.total
        return total > 0 ? Formatters.tokens(total) : nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accentWide)
                    .frame(width: 28, height: 28)
                    .shadow(color: Theme.violet.opacity(0.6), radius: 8)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("AGENT HUB").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(2)
                Text("command center").font(Theme.label).tracking(1.2).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button {
                state.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.surfaceRaised))
                    .overlay(Circle().strokeBorder(Theme.stroke))
            }
            .buttonStyle(.plain)
            .help("New chat (⌘N)")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).hudLabel().padding(.horizontal, 10).padding(.bottom, 3)
            content()
        }
    }
}

/// A selectable sidebar row with a glowing selection state.
struct SidebarRowStyle: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.cyan.opacity(0.16), Theme.violet.opacity(0.10)], startPoint: .leading, endPoint: .trailing))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cyan.opacity(0.25)))
                }
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Theme.accent).frame(width: 3, height: 16).shadow(color: Theme.cyan, radius: 4).offset(x: -1)
                }
            }
            .contentShape(Rectangle())
    }
}

struct NavRow: View {
    @Environment(AppState.self) private var state
    let title: String
    let symbol: String
    let item: SidebarItem
    var badge: String?

    var body: some View {
        Button {
            state.selection = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(selected ? Theme.cyan : Theme.textSecondary)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                if let badge {
                    Text(badge).font(Theme.label).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.surfaceRaised))
                }
            }
            .modifier(SidebarRowStyle(selected: selected))
        }
        .buttonStyle(.plain)
    }

    private var selected: Bool { state.selection == item }
}

struct ChatRow: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    var body: some View {
        let selected = state.selection == .chat(model.id)
        Button {
            model.unread = false
            state.selection = .chat(model.id)
        } label: {
            HStack(spacing: 8) {
                participants
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.conversation.title)
                        .font(.system(size: 12.5, weight: model.unread ? .semibold : .regular))
                        .lineLimit(1)
                    Text(model.conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if model.isBusy {
                    StatusBadge(status: .running, compact: true)
                } else if model.unread {
                    Circle().fill(Theme.cyan).frame(width: 6, height: 6).shadow(color: Theme.cyan, radius: 3)
                }
            }
            .modifier(SidebarRowStyle(selected: selected))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Chat", role: .destructive) { state.deleteConversation(model) }
        }
    }

    private var participants: some View {
        let ids = model.conversation.participants.map(\.agentID).prefix(3)
        return ZStack {
            if ids.isEmpty {
                Image(systemName: "bubble.left").foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(ids.enumerated()), id: \.offset) { index, id in
                let agent = state.agent(id: id)
                AgentAvatar(symbol: agent?.symbol ?? "questionmark", color: AgentColors.color(id: id), size: 18)
                    .offset(x: CGFloat(index) * 7)
            }
        }
        .frame(width: 30, alignment: .leading)
    }
}

struct TerminalRow: View {
    @Environment(AppState.self) private var state
    let session: TerminalSession

    var body: some View {
        Button {
            state.select(session)
        } label: {
            HStack(spacing: 8) {
                AgentAvatar(symbol: session.agent.symbol, color: AgentColors.color(for: session.agent), size: 20,
                            active: session.status == .running)
                Text(session.title).font(.system(size: 12.5, weight: session.unread ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if state.isInSplit(session) {
                    Image(systemName: "rectangle.split.2x1").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                StatusBadge(status: session.status, compact: true)
            }
            .modifier(SidebarRowStyle(selected: state.selection == .terminal(session.id)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(state.isInSplit(session) ? "Remove from Split View" : "Add to Split View") { state.toggleSplit(session) }
            Divider()
            Button("Close Terminal", role: .destructive) { state.close(session) }
        }
    }
}

struct HistoryRow: View {
    @Environment(AppState.self) private var state
    let record: SessionRecord

    var body: some View {
        Button {
            state.selection = .history(record.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: record.agentSymbol).frame(width: 18).foregroundStyle(Theme.textTertiary)
                Text(record.title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .modifier(SidebarRowStyle(selected: state.selection == .history(record.id)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Run Again") { state.rerun(record) }
            Button("Delete", role: .destructive) { state.deleteHistory(record) }
        }
    }
}

/// Compact grid of agents; click to mention in chat, play to open a terminal.
struct AgentGrid: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 4) {
            ForEach(state.config.agents) { agent in
                HStack(spacing: 8) {
                    AgentAvatar(symbol: agent.symbol, color: AgentColors.color(for: agent), size: 20)
                        .opacity(state.isInstalled(agent) == false ? 0.4 : 1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(agent.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("@\(agent.handle)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if state.isInstalled(agent) == false {
                        Text("missing").font(Theme.label).foregroundStyle(Theme.amber)
                            .help("`\(agent.command)` isn't on your shell's PATH")
                    } else if agent.runsInTerminal {
                        Button {
                            state.startTerminal(agent: agent, task: nil)
                        } label: {
                            Image(systemName: "terminal").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .help("Open \(agent.name) in a terminal")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
    }
}
