import AgentHubCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                CommandBar()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.showPalette = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("Start a session (⌘K)")
            }
        }
        .sheet(isPresented: $state.showPalette) {
            CommandPalette()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selection {
        case .usage:
            UsageView()
        case let .history(id):
            if let record = state.historyRecord(id: id) {
                HistoryDetailView(record: record)
                    .id(id)
            } else {
                TaskBoardView()
            }
        case .session:
            if let panes = state.visibleSplit {
                SplitSessionsView(sessions: panes)
            } else if let session = state.selectedSession {
                SessionDetailView(session: session, isFocused: true)
                    .id(session.id)
            } else {
                TaskBoardView()
            }
        case .board, nil:
            TaskBoardView()
        }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selection) {
            Label("Task Board", systemImage: "rectangle.3.group")
                .tag(SidebarItem.board)
            UsageSidebarRow()
                .tag(SidebarItem.usage)

            Section("Sessions") {
                if state.sessions.isEmpty {
                    Text("No sessions yet. Press ⌘K.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(state.sessions) { session in
                    SessionRow(session: session)
                        .tag(SidebarItem.session(session.id))
                        .contextMenu {
                            Button(state.isInSplit(session) ? "Remove from Split View" : "Add to Split View") {
                                state.toggleSplit(session)
                            }
                            Divider()
                            Button("Close Session", role: .destructive) { state.close(session) }
                        }
                }
            }

            if !state.closedHistory.isEmpty {
                Section("History") {
                    ForEach(state.closedHistory.prefix(50)) { record in
                        HistoryRow(record: record)
                            .tag(SidebarItem.history(record.id))
                            .contextMenu {
                                Button(record.kind == .chat ? "Continue Chat" : "Run Again") { state.reopen(record) }
                                Button("Delete", role: .destructive) { state.deleteHistory(record) }
                            }
                    }
                }
            }

            Section("Agents") {
                ForEach(state.config.agents) { agent in
                    AgentRow(agent: agent)
                }
            }
        }
        .onChange(of: state.selection) { _, newValue in
            if case let .session(id) = newValue { state.session(id: id)?.unread = false }
        }
    }
}

struct UsageSidebarRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack {
            Label("Usage", systemImage: "chart.bar.xaxis")
            Spacer()
            let today = state.usageSummary(since: Calendar.current.startOfDay(for: Date()))
            if today.total.total > 0 {
                Text(Formatters.tokens(today.total.total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Tokens used today")
            }
        }
    }
}

struct SessionRow: View {
    @Environment(AppState.self) private var state
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.agent.symbol)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                    .fontWeight(session.unread ? .semibold : .regular)
                HStack(spacing: 6) {
                    StatusBadge(status: session.status)
                    if state.isInSplit(session) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("In split view")
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let record: SessionRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: record.agentSymbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                Text(record.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AgentRow: View {
    @Environment(AppState.self) private var state
    let agent: AgentDefinition

    var body: some View {
        HStack {
            Label(agent.name, systemImage: agent.symbol)
            Spacer()
            if state.isInstalled(agent) == false {
                Text("not found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("`\(agent.command)` isn't on your shell's PATH")
            }
            Button {
                state.startSession(agent: agent, task: nil)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Start \(agent.name)")
        }
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 7, height: 7)
            Text(status.title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .running: return .blue
        case .needsInput: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}

enum Formatters {
    /// 1234 → "1.2K", 3_400_000 → "3.4M".
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return "\(count)"
        }
    }

    static func cost(_ dollars: Double) -> String {
        dollars < 0.01 && dollars > 0 ? "<$0.01" : String(format: "$%.2f", dollars)
    }
}
